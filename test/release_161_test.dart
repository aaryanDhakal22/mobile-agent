// Quibase 1.6.1: self-update without the lock — downloads quietly, installs
// by itself right after Close batch (silently once Quibase is its own
// installer), asks "Update ready — install now?" only when Android wants a
// tap, at a quiet moment, with LATER; and five destinations per rail mode
// (Map, Updates, POS hub).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/alarm.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/local_log.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/dev/pos_hub_screen.dart';
import 'package:mobile_agent/features/maps/runs_map_pane.dart';
import 'package:mobile_agent/features/update/update_prompt.dart';
import 'package:mobile_agent/features/update/updater.dart';
import 'package:mobile_agent/features/update/updates_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';

/// The Android side, recorded.
class FakeUpdatePlatform extends UpdatePlatform {
  final String dir;
  bool silent;
  bool allowed;
  bool confirmable = true;
  final List<String> calls = [];
  final _results = StreamController<(InstallResult, String)>.broadcast();

  FakeUpdatePlatform(this.dir, {this.silent = true, this.allowed = true});

  void emit(InstallResult r, [String message = '']) => _results.add((r, message));

  @override
  Stream<(InstallResult, String)> get results => _results.stream;
  @override
  Future<int?> installedVersion() async => 10;
  @override
  Future<String> updatesDir() async => dir;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<void> openInstallSettings() async => calls.add('settings');
  @override
  Future<bool> canInstallSilently() async => silent;
  @override
  Future<bool> canReopen() async => false;
  @override
  Future<void> openReopenSettings() async => calls.add('reopen-settings');
  @override
  Future<void> installSession(String path) async => calls.add('session:${path.split('/').last}');
  @override
  Future<bool> confirm() async {
    calls.add('confirm');
    return confirmable;
  }

  /// Android's API level (33 = silent-capable; 30 = the store's Android 11).
  int api = 33;

  /// Screens that never show up although Android accepted the request (the
  /// Neostra's confirm screen): 'confirm' and/or 'screen'.
  final Set<String> invisible = {};

  @override
  Future<bool> installWithScreen(String path) async {
    calls.add('screen:${path.split('/').last}');
    return true;
  }

  @override
  Future<int> sdk() async => api;

  @override
  Future<bool> watchScreen(Future<bool> Function() start, Duration within) async {
    final before = calls.length;
    if (!await start()) return false;
    final route = calls.length > before ? calls.last.split(':').first : '';
    return !invisible.contains(route);
  }
}

final _apk = utf8.encode('fake apk bytes');

/// A Pi that has release [latest] (null = none) and serves [_apk].
AgentClient _pi(Map<String, Object?>? Function() latest) => AgentClient(
  baseUrl: 'http://10.0.0.5:8080',
  deviceKey: 'qagt_k',
  client: MockClient((req) async {
    if (req.url.path == '/api/app/latest') {
      final l = latest();
      return l == null
          ? http.Response(jsonEncode({'error': 'no release'}), 404)
          : http.Response(jsonEncode(l), 200, headers: {'content-type': 'application/json'});
    }
    if (req.url.path == '/api/app/apk') return http.Response.bytes(_apk, 200);
    return http.Response('{}', 404);
  }),
);

Map<String, Object?> _release({int code = 20}) => {
  'version_code': code,
  'version_name': '1.6.1',
  'sha256': sha256.convert(_apk).toString(),
};

class _Floor extends FloorController {
  final FloorState initial;
  _Floor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}

  void push(FloorState s) => state = s;
}

/// Batch [batch]; [cooking] adds an accepted order (kitchen not empty).
FloorState _floor({int batch = 7, bool cooking = false}) {
  final f = jsonDecode(floorJson) as Map<String, dynamic>;
  (f['batch'] as Map)['id'] = batch;
  final o = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  (o['status'] as Map)
    ..['state'] = 'accepted'
    ..['kitchen_number'] = 1100
    ..['batch_id'] = batch;
  return const FloorState(connection: SseStatus.connected).withSnapshot(
    floor: Floor.fromJson(f),
    current: [if (cooking) StoredOrder.fromJson(o)],
    arrived: const [],
    drivers: const [],
    at: DateTime.now(),
  );
}

/// An updater whose state the test sets (no timers, no Pi).
class _FixedUpdater extends Updater {
  final UpdateState initial;
  _FixedUpdater(this.initial);

  @override
  UpdateState build() => initial;
}

Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('quibase-161'));
  tearDown(() => dir.delete(recursive: true));

  Future<(ProviderContainer, FakeUpdatePlatform, _Floor)> start({
    FloorState? floor,
    Map<String, Object?>? Function()? latest,
    bool silent = true,
    bool allowed = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final platform = FakeUpdatePlatform(dir.path, silent: silent, allowed: allowed);
    final f = _Floor(floor ?? _floor(cooking: true));
    final c = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        floorProvider.overrideWith(() => f),
        agentClientProvider.overrideWithValue(_pi(latest ?? () => _release())),
        updatePlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(c.dispose);
    c.listen(updaterProvider, (_, _) {});
    await _drain();
    return (c, platform, f);
  }

  group('updater', () {
    test('downloads quietly during service and installs silently right after Close batch', () async {
      final (c, platform, floor) = await start();
      final u = c.read(updaterProvider);
      expect(u.phase, UpdatePhase.ready);
      expect(u.target!.versionName, '1.6.1');
      expect(File(u.apkPath!).readAsBytesSync(), _apk);
      expect(platform.calls, isEmpty, reason: 'cooking: no install during service');
      expect(updateStatusLine(u), '1.6.1 downloaded — installs by itself after Close batch');

      floor.push(_floor(batch: 8)); // the night's batch closed; the new one is empty
      await _drain();
      expect(platform.calls, ['session:quibase-20.apk']);
      expect(c.read(updaterProvider).phase, UpdatePhase.installing);
    });

    test('a release that arrives after close installs straight away (fresh batch, quiet floor)', () async {
      final (c, platform, _) = await start(floor: _floor(batch: 8));
      expect(platform.calls, ['session:quibase-20.apk']);
    });

    test('one install even when the floor and the alarm both change at once', () async {
      final (c, platform, floor) = await start();
      floor.push(_floor(batch: 8));
      floor.push(_floor(batch: 8).copyWith(lastSyncAt: DateTime.now()));
      await c.read(updaterProvider.notifier).installNow();
      await _drain();
      expect(platform.calls, ['session:quibase-20.apk'], reason: 'two commits made Android ask twice');
    });

    test('not while an order rings, even after close', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final platform = FakeUpdatePlatform(dir.path);
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          floorProvider.overrideWith(() => _Floor(_floor(batch: 8))),
          agentClientProvider.overrideWithValue(_pi(() => _release())),
          updatePlatformProvider.overrideWithValue(platform),
          alarmProvider.overrideWith(_Ringing.new),
        ],
      );
      addTearDown(c.dispose);
      c.listen(updaterProvider, (_, _) {});
      await _drain();
      expect(c.read(updaterProvider).phase, UpdatePhase.ready);
      expect(platform.calls, isEmpty);
    });

    test('Android wants a tap (first self-install): needsTap, and INSTALL NOW opens its screen', () async {
      final (c, platform, _) = await start(floor: _floor(batch: 8), silent: false);
      platform.emit(InstallResult.pendingUserAction);
      await _drain();
      final u = c.read(updaterProvider);
      expect(u.phase, UpdatePhase.needsTap);
      expect(u.wantsTap, isTrue);
      expect(u.silent, isFalse);
      await c.read(updaterProvider.notifier).tapInstall();
      expect(platform.calls.last, 'confirm');
      expect(c.read(updaterProvider).phase, UpdatePhase.installing);
    });

    group('1.8.4: INSTALL NOW makes sure Android\'s screen opens', () {
      Future<(ProviderContainer, FakeUpdatePlatform)> tapNeeded(int api) async {
        final (c, platform, _) = await start(floor: _floor(batch: 8), silent: false);
        platform.api = api;
        platform.emit(InstallResult.pendingUserAction);
        await _drain();
        expect(c.read(updaterProvider).phase, UpdatePhase.needsTap);
        platform.calls.clear();
        return (c, platform);
      }

      test('Android 11 (the store): the APK screen, the route a manual install takes', () async {
        final (c, platform) = await tapNeeded(30);
        await c.read(updaterProvider.notifier).tapInstall();
        expect(platform.calls, ['screen:quibase-20.apk']);
        expect(c.read(updaterProvider).phase, UpdatePhase.installing);
      });

      test('Android 11, the APK screen never shows: falls back to the confirm screen', () async {
        final (c, platform) = await tapNeeded(30);
        platform.invisible.add('screen');
        await c.read(updaterProvider.notifier).tapInstall();
        expect(platform.calls, ['screen:quibase-20.apk', 'confirm']);
        expect(c.read(updaterProvider).phase, UpdatePhase.installing);
      });

      test('Android 12+, the confirm screen never shows (what the Neostra did): the APK screen', () async {
        final (c, platform) = await tapNeeded(33);
        platform.invisible.add('confirm');
        await c.read(updaterProvider.notifier).tapInstall();
        expect(platform.calls, ['confirm', 'screen:quibase-20.apk']);
        expect(c.read(updaterProvider).phase, UpdatePhase.installing);
      });

      test('neither screen shows: says so (no silent dead button), and logs each try', () async {
        final (c, platform) = await tapNeeded(30);
        platform.invisible.addAll({'screen', 'confirm'});
        await c.read(updaterProvider.notifier).tapInstall();
        final u = c.read(updaterProvider);
        expect(u.phase, UpdatePhase.failed);
        expect(u.error!.title, "Android didn't open its install screen");
        expect(u.error!.details, contains('API 30'));
        final log = c.read(localLogProvider).lines.join('\n');
        expect(log, contains('INSTALL NOW tapped (needsTap)'));
        expect(log, contains("Android's install screen did not open (APK)"));
        expect(log, contains("Android's confirm screen did not open"));
      });
    });

    test('a failed install asks again; after two, INSTALL NOW uses Android\'s own screen', () async {
      final (c, platform, _) = await start(floor: _floor(batch: 8));
      platform.emit(InstallResult.failed, 'INSTALL_FAILED_INTERNAL_ERROR');
      await _drain();
      expect(c.read(updaterProvider).phase, UpdatePhase.failed);
      expect(c.read(updaterProvider).error!.details, contains('INTERNAL_ERROR'));

      await c.read(updaterProvider.notifier).tapInstall();
      platform.emit(InstallResult.failed);
      await _drain();
      await c.read(updaterProvider.notifier).tapInstall();
      expect(platform.calls, ['session:quibase-20.apk', 'session:quibase-20.apk', 'screen:quibase-20.apk']);
      expect(c.read(updaterProvider).phase, UpdatePhase.needsTap);
    });

    test('no permission to install apps: ALLOW INSTALLS opens the switch', () async {
      final (c, platform, _) = await start(floor: _floor(batch: 8), allowed: false);
      expect(c.read(updaterProvider).phase, UpdatePhase.needPermission);
      await c.read(updaterProvider.notifier).tapInstall();
      expect(platform.calls, ['settings']);
    });

    test('a release withdrawn on the Pi is dropped', () async {
      Map<String, Object?>? latest = _release();
      final (c, _, _) = await start(latest: () => latest);
      expect(c.read(updaterProvider).available, isTrue);
      latest = null;
      await c.read(updaterProvider.notifier).check();
      expect(c.read(updaterProvider).available, isFalse);
      expect(c.read(updaterProvider).phase, UpdatePhase.none);
    });

    test('a damaged download is not installed', () async {
      final (c, platform, _) = await start(
        floor: _floor(batch: 8),
        latest: () => {..._release(), 'sha256': 'deadbeef'},
      );
      expect(c.read(updaterProvider).phase, UpdatePhase.failed);
      expect(c.read(updaterProvider).error!.title, 'The download was damaged');
      expect(platform.calls, isEmpty);
    });
  });

  group('prompt', () {
    const rel = AppRelease(versionCode: 20, versionName: '1.6.1');

    Future<(ProviderContainer, FakeUpdatePlatform)> pumpPrompt(
      WidgetTester tester,
      UpdateState state, {
      bool cooking = false,
    }) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final platform = FakeUpdatePlatform('/nonexistent');
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          floorProvider.overrideWith(() => _Floor(_floor(cooking: cooking))),
          updatePlatformProvider.overrideWithValue(platform),
          updaterProvider.overrideWith(() => _FixedUpdater(state)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: const Scaffold(body: Text('floor underneath')),
            builder: (context, child) => UpdatePrompt(child: child!),
          ),
        ),
      );
      await tester.pump();
      return (c, platform);
    }

    final prompt = find.byKey(const ValueKey('update-prompt'));

    testWidgets('asks when Android wants a tap and the floor is quiet; LATER hides it for 2 h', (tester) async {
      final (c, platform) = await pumpPrompt(
        tester,
        const UpdateState(target: rel, phase: UpdatePhase.needsTap, apkPath: '/x/quibase-20.apk'),
      );
      expect(prompt, findsOneWidget);
      expect(find.text('Quibase 1.6.1 is ready'), findsOneWidget);
      expect(find.text('floor underneath'), findsOneWidget, reason: 'no lock: the app is still there');
      expect(find.textContaining('Install without scanning'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-allow-reopen')), findsOneWidget, reason: '1.8.4: reopen is off');

      await tester.tap(find.byKey(const ValueKey('update-later')));
      await tester.pump();
      expect(prompt, findsNothing);
      await tester.pump(const Duration(hours: 1));
      expect(prompt, findsNothing);
      await tester.pump(const Duration(hours: 1, minutes: 2));
      expect(prompt, findsOneWidget, reason: 'the snooze ran out');

      await tester.tap(find.byKey(const ValueKey('update-install')));
      await tester.pump();
      expect(platform.calls, ['confirm']);
      // 1.8.4: Android never finished → the prompt asks again (TRY AGAIN).
      await tester.pump(kInstallTimeout + const Duration(seconds: 1));
      expect(c.read(updaterProvider).phase, UpdatePhase.failed);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('never while something is cooking', (tester) async {
      await pumpPrompt(tester, const UpdateState(target: rel, phase: UpdatePhase.needsTap), cooking: true);
      expect(prompt, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a downloaded update waiting for Close batch asks nothing', (tester) async {
      await pumpPrompt(tester, const UpdateState(target: rel, phase: UpdatePhase.ready));
      expect(prompt, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Updates screen: status, INSTALL NOW installs at once', (tester) async {
      final (c, platform) = await pumpPrompt(
        tester,
        const UpdateState(target: rel, phase: UpdatePhase.ready, apkPath: '/x/quibase-20.apk', silent: true),
        cooking: true,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: UpdatesScreen())),
        ),
      );
      await tester.pump();
      expect(find.text('1.6.1 downloaded — installs by itself after Close batch'), findsOneWidget);
      expect(find.text('No Android tap needed (Play Protect may still ask)'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-reopen')), findsOneWidget, reason: 'reopen is off');
      await tester.tap(find.byKey(const ValueKey('update-install-now')));
      await tester.pump();
      expect(platform.calls, ['session:quibase-20.apk']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(kInstallTimeout); // the "Android never answered" timer
    });
  });

  group('map', () {
    test('out runs: one per driver out, roster colours stay put', () {
      final s = deliveryFloor(); // Sam is out with the onDelivery fixture
      final runs = outRuns(s.drivers, s.onDelivery);
      expect(runs.single.driver.name, 'Sam');
      expect(runs.single.stops, isNotEmpty);
      expect(runs.single.color, kDriverColors[2], reason: 'Sam is third in the roster');
      expect(driverColor(s.drivers, 'd-sam'), runs.single.color);
    });

    testWidgets('legend lists each driver out; nobody out says so', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = FakeDeliveryFloor(deliveryFloor());
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: RunsMapPane())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      final out = c.read(floorProvider).onDelivery;
      for (final r in outRuns(c.read(floorProvider).drivers, out)) {
        expect(find.byKey(ValueKey('legend-${r.driver.id}')), findsOneWidget);
      }
      expect(out, isNotEmpty);
      expect(find.byKey(stubTilesKey), findsOneWidget);
      expect(f.calls.where((x) => x.op == 'trip'), isNotEmpty, reason: 'asks the Pi for each run\'s road route');
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('POS hub renders the link and only the POS switches', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await deliveryContainer(
      FakeDeliveryFloor(deliveryFloor()),
      prefs: const {'agent_address': 'http://10.0.0.5:8080', 'device_key': 'qagt_k', 'device_name': 'Counter'},
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: PosHubScreen())),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('POS orders pull-in'), findsOneWidget);
    expect(find.text('Driver write-back'), findsOneWidget);
    expect(find.text('Paid wave'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

class _Ringing extends AlarmNotifier {
  @override
  AlarmState build() => const AlarmState(ringing: true, visible: true, known: {'o-1'});
}
