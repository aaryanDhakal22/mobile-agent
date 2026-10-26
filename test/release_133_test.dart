// 1.3.3 pre-production fixes: the ring service follows pairing only, the
// update lock can't hide the new-order alert or brick the counter, closing a
// batch never cancels an order nobody saw, and the setup tests don't touch a
// real order's ring.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/app.dart';
import 'package:mobile_agent/core/alarm.dart';
import 'package:mobile_agent/core/alert_player.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/ring_bridge.dart';
import 'package:mobile_agent/core/ring_platform.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/batch/batch_pane.dart';
import 'package:mobile_agent/features/setup/steps/test_print_step.dart';
import 'package:mobile_agent/features/setup/steps/test_ring_step.dart';
import 'package:mobile_agent/features/update/update_gate.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

StoredOrder _parse(String raw) => StoredOrder.fromJson(jsonDecode(raw) as Map<String, dynamic>);

StoredOrder _arrived(String id) {
  final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  (m['order'] as Map)['id'] = id;
  return StoredOrder.fromJson(m);
}

class FakeFloor extends FloorController {
  final FloorState initial;
  final List<Object> closeAnswers;
  final List<bool> closeCalls = [];
  FakeFloor(this.initial, {List<Object>? closeAnswers}) : closeAnswers = closeAnswers ?? [];

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}

  @override
  Future<CloseBatchResult> closeBatch({required bool force}) async {
    closeCalls.add(force);
    final a = closeAnswers.removeAt(0);
    if (a is Exception) throw a;
    return a as CloseBatchResult;
  }
}

class FakeRing extends RingPlatform {
  final List<String> calls = [];

  @override
  Future<bool> startService(String text) async {
    calls.add('startService');
    return true;
  }

  @override
  Future<void> updateService(String text) async => calls.add('updateService');
  @override
  Future<void> stopService() async => calls.add('stopService');
  @override
  Future<bool> showRing({required String title, required String text}) async {
    calls.add('showRing:$title');
    return true;
  }

  @override
  Future<void> cancelRing() async => calls.add('cancelRing');
}

class QuietSink implements AlarmSink {
  @override
  void Function()? onStopped;
  @override
  Future<void> configure() async {}
  @override
  Future<void> setSource(String asset) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  void haptic() {}
}

class FakeUpdatePlatform extends UpdatePlatform {
  @override
  Future<int?> installedVersion() async => 10;
  @override
  Future<String> updatesDir() async => '/nonexistent/updates';
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> install(String path) async {}
}

/// A ringing alarm the test switches on.
class FakeAlarm extends AlarmNotifier {
  @override
  AlarmState build() => AlarmState.silent;
  void ring() => state = const AlarmState(ringing: true, visible: true, known: {'o-1'});
}

const _paired = {'agent_address': 'http://10.0.0.5:8080', 'device_key': 'qagt_k', 'device_name': 'Counter'};

ThemeData _theme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

/// An agent whose latest release is [latest] (null = withdrawn → 404) and
/// whose APK download always fails.
AgentClient _updateAgent(Map<String, Object?>? Function() latest) => AgentClient(
  baseUrl: 'http://10.0.0.5:8080',
  deviceKey: 'qagt_k',
  client: MockClient((req) async {
    if (req.url.path == '/api/app/latest') {
      final l = latest();
      return l == null
          ? http.Response(jsonEncode({'error': 'no release'}), 404)
          : http.Response(jsonEncode(l), 200, headers: {'content-type': 'application/json'});
    }
    return http.Response(jsonEncode({'error': 'apk cache broken'}), 500);
  }),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AlertPlayer.resetForTest(QuietSink()));

  group('ring bridge', () {
    test('unpaired at start: stops a service RestartReceiver started and clears a stale ring', () async {
      final ring = FakeRing();
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(await _prefs()),
          ringPlatformProvider.overrideWithValue(ring),
          floorProvider.overrideWith(() => FakeFloor(const FloorState(connection: SseStatus.disconnected))),
        ],
      );
      addTearDown(c.dispose);
      final undo = startRingBridge(c);
      addTearDown(undo);
      expect(ring.calls, containsAll(['stopService', 'cancelRing']));
      expect(ring.calls, isNot(contains('startService')));
    });

    test('paired: the service follows pairing only — a rename does not restart it', () async {
      final ring = FakeRing();
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(await _prefs(_paired)),
          ringPlatformProvider.overrideWithValue(ring),
          floorProvider.overrideWith(() => FakeFloor(const FloorState(connection: SseStatus.connecting))),
        ],
      );
      addTearDown(c.dispose);
      final undo = startRingBridge(c);
      addTearDown(undo);
      expect(ring.calls, contains('startService'));
      expect(ring.calls, isNot(contains('stopService')));

      ring.calls.clear();
      await c.read(pairingProvider.notifier).rename('Front counter');
      await Future<void>.delayed(Duration.zero);
      expect(ring.calls, isEmpty);

      await c.read(pairingProvider.notifier).unpair();
      await Future<void>.delayed(Duration.zero);
      expect(ring.calls, contains('stopService'));
    });
  });

  test('renaming the tablet keeps the agent client (no SSE / floor rebuild); a new address replaces it', () async {
    final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(await _prefs(_paired))]);
    addTearDown(c.dispose);
    final sub = c.listen(agentClientProvider, (_, _) {});
    addTearDown(sub.close);
    final before = c.read(agentClientProvider);
    expect(before, isNotNull);

    await c.read(pairingProvider.notifier).rename('Front counter');
    expect(identical(c.read(agentClientProvider), before), isTrue);
    await c.read(pairingProvider.notifier).setAddress('http://10.0.0.5:8080');
    expect(identical(c.read(agentClientProvider), before), isTrue, reason: 'same address saved again');

    await c.read(pairingProvider.notifier).setAddress('10.0.0.6');
    expect(c.read(agentClientProvider)!.baseUrl, 'http://10.0.0.6:8080');
  });

  group('update lock', () {
    Future<ProviderContainer> pumpGate(
      WidgetTester tester,
      Map<String, Object?>? Function() latest, {
      Widget? app,
    }) async {
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(await _prefs(_paired)),
          floorProvider.overrideWith(
            () => FakeFloor(
              const FloorState(connection: SseStatus.connected).withSnapshot(
                floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
                current: const [],
                arrived: app == null ? const [] : [_parse(arrivedPickupJson)],
                drivers: const [],
                at: DateTime.now(),
              ),
            ),
          ),
          agentClientProvider.overrideWithValue(_updateAgent(latest)),
          updatePlatformProvider.overrideWithValue(FakeUpdatePlatform()),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child:
              app ??
              MaterialApp(
                theme: _theme(),
                home: const UpdateGate(child: Text('floor underneath')),
              ),
        ),
      );
      await _settle(tester);
      return c;
    }

    testWidgets('LATER after two failed attempts, back after an hour; a withdrawn release unlocks', (tester) async {
      Map<String, Object?>? latest = {'version_code': 20, 'version_name': '1.3.4', 'sha256': ''};
      await pumpGate(tester, () => latest);
      expect(find.text('Update not finished'), findsOneWidget);
      expect(find.text('LATER'), findsNothing, reason: 'one failure: forced');

      await tester.tap(find.text('TRY AGAIN'));
      await _settle(tester);
      expect(find.text('LATER'), findsOneWidget);

      await tester.tap(find.text('LATER'));
      await tester.pump();
      expect(find.text('Update not finished'), findsNothing);
      expect(find.text('floor underneath'), findsOneWidget);

      await tester.pump(kUpdateSnooze);
      await _settle(tester);
      expect(find.text('Update not finished'), findsOneWidget, reason: 'the snooze ran out');

      latest = null; // withdrawn on the agent
      await tester.pump(kUpdateCheckInterval);
      await _settle(tester);
      expect(find.text('Update not finished'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a release no longer newer than the installed one unlocks', (tester) async {
      var code = 20;
      await pumpGate(tester, () => {'version_code': code, 'version_name': 'x'});
      expect(find.text('Update not finished'), findsOneWidget);
      code = 10; // same as installed (FakeUpdatePlatform)
      await tester.pump(kUpdateCheckInterval);
      await _settle(tester);
      expect(find.text('Update not finished'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the new-order alert sits above the update lock', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpGate(
        tester,
        () => {'version_code': 20, 'version_name': '1.3.4'},
        app: MaterialApp(
          theme: _theme(),
          builder: (context, child) => pairedOverlays(child!),
          home: const Scaffold(body: Text('floor underneath')),
        ),
      );
      expect(find.text('Update not finished'), findsOneWidget);
      expect(find.text('New order').hitTestable(), findsOneWidget);
      expect(find.text('ACCEPT · 15 MIN').hitTestable(), findsOneWidget);
      expect(find.text('TRY AGAIN').hitTestable(), findsNothing, reason: 'the lock is underneath');
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('old APKs are deleted when a new one is downloaded', () async {
    final dir = await Directory.systemTemp.createTemp('quibase-updates');
    addTearDown(() => dir.delete(recursive: true));
    final keep = File('${dir.path}/quibase-30.apk')..writeAsStringSync('new');
    File('${dir.path}/quibase-20.apk').writeAsStringSync('old');
    File('${dir.path}/quibase-10.apk').writeAsStringSync('older');
    await pruneOldApks(dir, keep.path);
    expect(dir.listSync().map((f) => f.path), [keep.path]);
  });

  group('close batch', () {
    BatchLeftoversException leftovers(List<String> ids) =>
        BatchLeftoversException('unfinished', leftovers: [for (final id in ids) _arrived(id)]);
    final closed = CloseBatchResult.fromJson({
      'closed': {'id': 7, 'order_count': 3},
      'auto_finished': const [],
    });

    Future<FakeFloor> pumpBatch(WidgetTester tester, List<Object> answers) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final floor = FakeFloor(
        const FloorState(connection: SseStatus.connected).withSnapshot(
          floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
          current: const [],
          arrived: const [],
          drivers: const [],
          at: DateTime.now(),
        ),
        closeAnswers: answers,
      );
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(await _prefs(_paired)),
          floorProvider.overrideWith(() => floor),
          batchesProvider.overrideWith((ref) async => const [Batch(id: 7)]),
          // Driver reports: none.
          agentClientProvider.overrideWithValue(
            AgentClient(
              baseUrl: 'http://10.0.0.5:8080',
              deviceKey: 'qagt_k',
              client: MockClient((_) async => http.Response('[]', 200, headers: {'content-type': 'application/json'})),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: _theme(),
            home: const Scaffold(body: BatchPane()),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('CLOSE BATCH').first);
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('CLOSE BATCH').last); // the confirm dialog
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      return floor;
    }

    testWidgets('a new order that came in while the list was open is shown, not cancelled', (tester) async {
      final floor = await pumpBatch(tester, [
        leftovers(['a']),
        leftovers(['a', 'b']), // "b" arrived while the dialog was open
        leftovers(['a', 'b']),
        closed,
      ]);
      expect(find.text('1 order is not finished'), findsOneWidget);
      await tester.tap(find.text('CLOSE ANYWAY'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(floor.closeCalls, [false, false], reason: 're-asked, not forced');
      expect(find.text('2 orders are not finished'), findsOneWidget);
      expect(find.text('1 new order came in — check the list again.'), findsOneWidget);

      await tester.tap(find.text('CLOSE ANYWAY'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(floor.closeCalls, [false, false, false, true]);
      expect(find.textContaining('Batch #7 closed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nothing new: CLOSE ANYWAY forces after one re-check', (tester) async {
      final floor = await pumpBatch(tester, [
        leftovers(['a', 'b']),
        leftovers(['a']), // one got finished meanwhile
        closed,
      ]);
      await tester.tap(find.text('CLOSE ANYWAY'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(floor.closeCalls, [false, false, true]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('KEEP BATCH OPEN never forces', (tester) async {
      final floor = await pumpBatch(tester, [
        leftovers(['a']),
      ]);
      await tester.tap(find.text('KEEP BATCH OPEN'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(floor.closeCalls, [false]);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('setup: test ring with the screen off', () {
    Future<(FakeRing, FakeAlarm)> run(WidgetTester tester, {required bool realOrderMeanwhile}) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ring = FakeRing();
      final alarm = FakeAlarm();
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(await _prefs(_paired)),
          ringPlatformProvider.overrideWithValue(ring),
          alarmProvider.overrideWith(() => alarm),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: _theme(),
            home: const Scaffold(body: TestRingPanel()),
          ),
        ),
      );
      await tester.tap(find.text('TEST WITH THE SCREEN OFF'));
      for (var i = 0; i < 11; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(ring.calls, contains('showRing:Test ring'));
      if (realOrderMeanwhile) alarm.ring();
      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      expect(find.text('Did the screen turn on and ring?'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      return (ring, alarm);
    }

    testWidgets('takes its own notification down afterwards', (tester) async {
      final (ring, _) = await run(tester, realOrderMeanwhile: false);
      expect(ring.calls, contains('cancelRing'));
    });

    testWidgets("a real order ringing meanwhile keeps its notification", (tester) async {
      final (ring, _) = await run(tester, realOrderMeanwhile: true);
      expect(ring.calls, isNot(contains('cancelRing')));
    });
  });

  testWidgets('test print on an agent 2.0.0 (405) says the Pi is too old, not an error', (tester) async {
    final client = AgentClient(
      baseUrl: 'http://10.0.0.5:8080',
      deviceKey: 'qagt_k',
      client: MockClient((_) async => http.Response('Method Not Allowed', 405)),
    );
    final c = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(await _prefs(_paired)),
        agentClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: _theme(),
          home: const Scaffold(body: TestPrintPanel()),
        ),
      ),
    );
    await tester.tap(find.text('PRINT TEST SLIPS'));
    await _settle(tester);
    expect(find.textContaining("This Pi can't do test prints"), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('missing route: 404 / 405 yes, 404 not_configured no', () {
    expect(const AgentException('x', statusCode: 404).isMissingRoute, isTrue);
    expect(const AgentException('x', statusCode: 405).isMissingRoute, isTrue);
    expect(const AgentException('x', statusCode: 404, code: 'not_configured').isMissingRoute, isFalse);
    expect(const AgentException('x', statusCode: 409).isMissingRoute, isFalse);
  });
}
