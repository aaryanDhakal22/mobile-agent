// Quibase 1.9.0: the updater never sticks in "installing" and backs off a
// damaged download.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/clock.dart';
import 'package:mobile_agent/core/frame_stats.dart';
import 'package:mobile_agent/core/json.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/dev/performance_card.dart';
import 'package:mobile_agent/features/diagnose/report.dart';
import 'package:mobile_agent/features/kitchen/kitchen_pane.dart';
import 'package:mobile_agent/features/update/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';

/// The Android side, recorded; [canInstallError] makes canInstall() throw.
class _Platform extends UpdatePlatform {
  final String dir;
  bool allowed = true;
  Object? canInstallError;
  final List<String> calls = [];
  final _results = StreamController<(InstallResult, String)>.broadcast();

  _Platform(this.dir);

  @override
  Stream<(InstallResult, String)> get results => _results.stream;
  @override
  Future<int?> installedVersion() async => 10;
  @override
  Future<String> updatesDir() async => dir;
  @override
  Future<bool> canInstall() async {
    final e = canInstallError;
    if (e != null) throw e;
    return allowed;
  }

  @override
  Future<void> openInstallSettings() async => calls.add('settings');
  @override
  Future<bool> canInstallSilently() async => true;
  @override
  Future<bool> canReopen() async => true;
  @override
  Future<void> installSession(String path) async => calls.add('session:${path.split('/').last}');
  @override
  Future<bool> confirm() async => true;
  @override
  Future<bool> installWithScreen(String path) async => true;
  @override
  Future<int> sdk() async => 33;
}

final _apk = utf8.encode('fake apk bytes');

class _Floor extends FloorController {
  final FloorState initial;
  _Floor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}
}

/// An empty, fresh batch: the updater installs a ready release at once.
FloorState _quietFloor() {
  final f = jsonDecode(floorJson) as Map<String, dynamic>;
  (f['batch'] as Map)['id'] = 8;
  return const FloorState(connection: SseStatus.connected).withSnapshot(
    floor: Floor.fromJson(f),
    current: const [],
    arrived: const [],
    drivers: const [],
    at: DateTime.now(),
  );
}

Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('quibase-190'));
  tearDown(() => dir.delete(recursive: true));

  group('WP3 updater', () {
    /// [sha] is what the Pi says the APK hashes to; [code] its versionCode.
    Future<(ProviderContainer, _Platform, List<String>)> start({
      required String Function() sha,
      int Function()? code,
      void Function(_Platform)? setup,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final platform = _Platform(dir.path);
      setup?.call(platform);
      final requests = <String>[];
      final pi = AgentClient(
        baseUrl: 'http://10.0.0.5:8080',
        deviceKey: 'qagt_k',
        client: MockClient((req) async {
          requests.add(req.url.path);
          if (req.url.path == '/api/app/latest') {
            return http.Response(
              jsonEncode({'version_code': code?.call() ?? 20, 'version_name': '1.9.0', 'sha256': sha()}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (req.url.path == '/api/app/apk') return http.Response.bytes(_apk, 200);
          return http.Response('{}', 404);
        }),
      );
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          floorProvider.overrideWith(() => _Floor(_quietFloor())),
          agentClientProvider.overrideWithValue(pi),
          updatePlatformProvider.overrideWithValue(platform),
        ],
      );
      addTearDown(c.dispose);
      c.listen(updaterProvider, (_, _) {});
      await _drain();
      return (c, platform, requests);
    }

    final goodSha = sha256.convert(_apk).toString();

    test('canInstall() throwing fails the install instead of sticking in installing', () async {
      final (c, platform, _) = await start(
        sha: () => goodSha,
        setup: (p) => p.canInstallError = PlatformException(code: 'boom', message: 'channel died'),
      );
      final u = c.read(updaterProvider);
      expect(u.phase, UpdatePhase.failed, reason: 'the automatic install hit the throw');
      expect(u.error!.details, contains('channel died'));
      expect(platform.calls, isEmpty);

      // The next INSTALL NOW is not swallowed by a stale "installing".
      platform.canInstallError = null;
      await c.read(updaterProvider.notifier).tapInstall();
      expect(platform.calls, ['session:quibase-20.apk']);
      expect(c.read(updaterProvider).phase, UpdatePhase.installing);
    });

    test('canInstall() false: needPermission, never installing', () async {
      final (c, platform, _) = await start(sha: () => goodSha, setup: (p) => p.allowed = false);
      expect(c.read(updaterProvider).phase, UpdatePhase.needPermission);
      await c.read(updaterProvider.notifier).installNow();
      expect(c.read(updaterProvider).phase, UpdatePhase.needPermission);
      expect(platform.calls, isEmpty);
    });

    test('damaged-download delay: 10 min × 2ⁿ, capped at 4 h', () {
      expect(damagedRetryDelay(0), Duration.zero);
      expect(damagedRetryDelay(1), const Duration(minutes: 10));
      expect(damagedRetryDelay(2), const Duration(minutes: 20));
      expect(damagedRetryDelay(3), const Duration(minutes: 40));
      expect(damagedRetryDelay(4), const Duration(minutes: 80));
      expect(damagedRetryDelay(5), const Duration(minutes: 160));
      expect(damagedRetryDelay(6), const Duration(hours: 4));
      expect(damagedRetryDelay(60), const Duration(hours: 4));
    });

    test('a damaged download backs off; a manual retry and a new version start over', () async {
      var now = DateTime(2026, 10, 27, 9);
      await withClock(Clock(() => now), () async {
        var code = 20;
        final (c, _, requests) = await start(sha: () => 'deadbeef', code: () => code);
        final updater = c.read(updaterProvider.notifier);
        int downloads() => requests.where((p) => p == '/api/app/apk').length;

        expect(c.read(updaterProvider).phase, UpdatePhase.failed);
        expect(c.read(updaterProvider).error!.title, 'The download was damaged');
        expect(downloads(), 1);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 10)));

        now = now.add(const Duration(minutes: 9));
        await updater.check();
        expect(downloads(), 1, reason: 'still backing off');

        now = now.add(const Duration(minutes: 2));
        await updater.check();
        expect(downloads(), 2);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 20)));

        now = now.add(const Duration(minutes: 15));
        await updater.check();
        expect(downloads(), 2);
        now = now.add(const Duration(minutes: 6));
        await updater.check();
        expect(downloads(), 3);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 40)));

        // TRY AGAIN: downloads at once and the back-off starts over.
        await updater.tapInstall();
        expect(downloads(), 4);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 10)));

        // A new version on the Pi downloads at once too.
        code = 21;
        await updater.check();
        expect(downloads(), 5);
        expect(c.read(updaterProvider).target!.versionCode, 21);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 10)));
      });
    });
  });

  group('WP4 ticket heading', () {
    Future<FakeDeliveryFloor> pumpKitchen(WidgetTester tester, List<StoredOrder> orders) async {
      tester.view.physicalSize = const Size(1280 - 104, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final base = deliveryFloor();
      final f = FakeDeliveryFloor(
        base.withSnapshot(floor: base.floor!, current: orders, arrived: const [], drivers: base.drivers, at: DateTime.now()),
      );
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: KitchenPane())),
        ),
      );
      await tester.pump();
      return f;
    }

    String heading(WidgetTester tester, String id) => tester
        .widget<Text>(
          find.descendant(of: find.byKey(ValueKey('ticket-open-$id')), matching: find.byKey(const ValueKey('ticket-heading'))),
        )
        .data!;

    testWidgets('a delivery shows its street, a pickup its name, no house number falls back to the name', (tester) async {
      final pickup = StoredOrder.fromJson(
        (jsonDecode(arrivedPickupJson) as Map<String, dynamic>)
          ..['status'] = {
            ...((jsonDecode(arrivedPickupJson) as Map<String, dynamic>)['status'] as Map),
            'state': 'accepted',
            'kitchen_number': 1110,
          },
      );
      await pumpKitchen(tester, [
        delivery('k1', 1101, state: 'accepted', street: '4108 Old Court Rd, Apt 2'),
        delivery('k2', 1102, state: 'accepted', street: '931 TAYLOR AVENUE'),
        delivery('k3', 1103, state: 'accepted', street: 'Towson University'),
        pickup,
      ]);
      expect(heading(tester, 'k1'), '4108 Old Court');
      expect(heading(tester, 'k2'), '931 Taylor Ave');
      expect(heading(tester, 'k3'), delivery('x', 1, street: 'Towson University').order.customerName);
      expect(heading(tester, pickup.id), pickup.order.customerName);
      expect(ticketHeading(pickup), pickup.order.customerName);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('WP5 speed', () {
    Map<String, dynamic> accepted(int n, {String name = 'José Núñez — 4 €'}) => {
      'order': {
        'id': 'o-$n',
        'customer': {'display_name': name},
        'fulfillment': {'type': 'pickup'},
        'notes': 'x' * 400,
      },
      'status': {'state': 'accepted', 'batch_id': 7, 'kitchen_number': 1100 + n},
    };

    test('the full refresh runs every 3 min while live, every 20 s while the link is down', () async {
      SharedPreferences.setMockInitialValues({'agent_address': 'http://h:1', 'device_key': 'qagt_k'});
      final prefs = await SharedPreferences.getInstance();
      final first = StreamController<List<int>>();
      var connections = 0;
      final sse = MockClient.streaming((req, _) async {
        connections++;
        if (connections == 1) return http.StreamedResponse(first.stream, 200);
        return Completer<http.StreamedResponse>().future; // reconnecting, never answers
      });
      final rest = MockClient((req) async => switch (req.url.path) {
        '/api/floor' => http.Response(floorJson, 200),
        '/api/drivers' => http.Response('[]', 200),
        _ => http.Response('[]', 200),
      });
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          agentClientProvider.overrideWith((ref) => AgentClient(baseUrl: 'h:1', deviceKey: 'qagt_k', client: rest)),
          sseClientFactoryProvider.overrideWithValue(() => sse),
          sseBackoffProvider.overrideWithValue((_) => const Duration(milliseconds: 5)),
        ],
      );
      addTearDown(c.dispose);
      c.listen<FloorState>(floorProvider, (_, _) {}, fireImmediately: true);
      final floor = c.read(floorProvider.notifier);

      Future<void> until(bool Function() ok) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!ok()) {
          if (DateTime.now().isAfter(deadline)) fail('timed out (poll ${floor.pollEvery})');
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      await until(() => c.read(floorProvider).connection == SseStatus.connected);
      expect(floor.pollEvery, kLivePollInterval);
      expect(kLivePollInterval, const Duration(minutes: 3));
      await first.close(); // the Pi dropped the stream
      await until(() => c.read(floorProvider).connection != SseStatus.connected);
      expect(floor.pollEvery, kPollInterval);
      expect(kPollInterval, const Duration(seconds: 20));
    });

    test('one UTF-8 decode of the bytes; Latin-1 bytes still read; empty / not JSON = null', () {
      expect(decodeJsonBytes(Uint8List.fromList(utf8.encode('{"n":"José — 4 €"}'))), {'n': 'José — 4 €'});
      expect(decodeJsonBytes(Uint8List.fromList(latin1.encode('{"n":"José"}'))), {'n': 'José'});
      expect(decodeJsonBytes(Uint8List(0)), isNull);
      expect(decodeJsonBytes(Uint8List.fromList(utf8.encode('  '))), isNull);
      expect(decodeJsonBytes(Uint8List.fromList(utf8.encode('<html>'))), isNull);
    });

    test('a big order list is parsed on a background isolate, the same as on the UI thread', () async {
      final body = jsonEncode([for (var i = 0; i < 300; i++) accepted(i)]);
      expect(utf8.encode(body).length, greaterThan(kIsolateParseBytes));
      final client = AgentClient(
        baseUrl: 'h:1',
        deviceKey: 'k',
        client: MockClient(
          (req) async =>
              http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json'}),
        ),
      );
      final inline = await client.listOrders(limit: 500);
      parseOffUiThread = true;
      addTearDown(() => parseOffUiThread = false);
      final isolate = await client.listOrders(limit: 500);
      expect(isolate, hasLength(300));
      expect(isolate.map((o) => (o.id, o.order.customerName, o.sig)), inline.map((o) => (o.id, o.order.customerName, o.sig)));
      expect(isolate.first.order.customerName, 'José Núñez — 4 €');
    });

    test('a refresh keeps the instances of unchanged orders (same JSON sig); a changed one is new', () {
      StoredOrder parse(Map<String, dynamic> m) => StoredOrder.fromJson(jsonDecode(jsonEncode(m)) as Map<String, dynamic>);
      final a = parse(accepted(1)), b = parse(accepted(2));
      final base = deliveryFloor();
      final s1 = base.withSnapshot(floor: base.floor!, current: [a, b], arrived: const [], drivers: const [], at: DateTime.now());

      final b2 = accepted(2)..['status'] = {...accepted(2)['status'] as Map, 'state': 'ready'};
      final local = s1.orders['o-1']!.copyWith(status: s1.orders['o-1']!.status);
      final s2 = s1
          .withOrder(local)
          .withSnapshot(
            floor: base.floor!,
            current: [parse(accepted(1)), parse(b2)],
            arrived: const [],
            drivers: const [],
            at: DateTime.now(),
          );
      expect(local.sig, isNull, reason: 'changed here: never reused');
      expect(identical(s2.orders['o-1'], local), isFalse);
      final s3 = s2.withSnapshot(
        floor: base.floor!,
        current: [parse(accepted(1)), parse(b2)],
        arrived: const [],
        drivers: const [],
        at: DateTime.now(),
      );
      expect(identical(s3.orders['o-1'], s2.orders['o-1']), isTrue, reason: 'same JSON: same instance');
      expect(identical(s3.orders['o-2'], s2.orders['o-2']), isTrue);
      expect(identical(s2.orders['o-2'], s1.orders['o-2']), isFalse, reason: 'it went ready');
      expect(s2.orders['o-2']!.state, OrderState.ready);
      expect(SameOrders(s3.kitchen), SameOrders(s2.kitchen));
      expect(SameOrders(s2.kitchen) == SameOrders(s1.kitchen), isFalse);
    });

    test('jsonSig: equal JSON → equal sig, any change → a different one', () {
      final m = accepted(1);
      expect(jsonSig(m), jsonSig(jsonDecode(jsonEncode(m))));
      expect(jsonSig({'a': 1}), isNot(jsonSig({'a': 2})));
      expect(jsonSig({'a': '1'}), isNot(jsonSig({'a': 1})));
      expect(jsonSig(['a', 'b']), isNot(jsonSig(['ab'])));
      expect(jsonSig({'a': null}), isNot(jsonSig({'a': false})));
    });

    testWidgets('the shared clock: one timer, rebuilds only when what is shown changes', (tester) async {
      var now = DateTime(2026, 10, 27, 12);
      await withClock(Clock(() => now), () async {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        var minuteBuilds = 0, secondBuilds = 0;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                children: [
                  ClockBuilder<int>(
                    select: (n) => n.minute,
                    builder: (_, m, _) {
                      minuteBuilds++;
                      return Text('m$m');
                    },
                  ),
                  ClockBuilder<int>(
                    select: (n) => n.second,
                    builder: (_, s, _) {
                      secondBuilds++;
                      return Text('s$s');
                    },
                  ),
                  ClockText((n) => 'at ${n.minute}:${n.second}', textKey: const ValueKey('t')),
                ],
              ),
            ),
          ),
        );
        expect(c.read(clockProvider).running, isTrue);
        for (var i = 0; i < 30; i++) {
          now = now.add(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
        }
        expect(secondBuilds, 31);
        expect(minuteBuilds, 1, reason: 'the minute did not change');
        expect(find.text('at 0:30'), findsOneWidget);
        now = now.add(const Duration(seconds: 30));
        await tester.pump(const Duration(seconds: 1));
        expect(minuteBuilds, 2);
        expect(find.text('m1'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        expect(c.read(clockProvider).running, isFalse, reason: 'nobody listens: no timer');
      });
    });

    test('frame stats: count, jank %, p50 / p90 / max over the last 5 min', () {
      final t0 = DateTime(2026, 10, 27, 12);
      final s = FrameStats();
      expect(s.summary(t0)['frames'], 0);
      // An old frame that drops out of the window.
      s.add((at: t0.subtract(const Duration(minutes: 6)), buildUs: 90000, rasterUs: 90000));
      for (var i = 1; i <= 10; i++) {
        s.add((at: t0, buildUs: i * 1000, rasterUs: i == 10 ? 30000 : 2000));
      }
      final m = s.summary(t0);
      expect(m['frames'], 10);
      expect(m['jank_frames'], 1);
      expect(m['jank_pct'], 10.0);
      expect(m['build_ms'], {'p50': 6.0, 'p90': 9.0, 'max': 10.0});
      expect(m['raster_ms'], {'p50': 2.0, 'p90': 2.0, 'max': 30.0});
      expect(s.line(t0), contains('10 frames · 10.0 % jank'));
      expect(s.summary(t0.add(const Duration(minutes: 6)))['frames'], 0);
    });

    test('diagnostics carry tablet.frames', () {
      final r = composeReport(
        kind: 'manual',
        outcome: 'info',
        ctx: const ReportContext(frames: {'frames': 12, 'jank_pct': 0.0}),
      );
      expect((r.json['tablet'] as Map)['frames'], {'frames': 12, 'jank_pct': 0.0});
      final none = composeReport(kind: 'manual', outcome: 'info', ctx: const ReportContext());
      expect((none.json['tablet'] as Map).containsKey('frames'), isFalse);
    });

    testWidgets('developer Config: the performance overlay switch', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: PerformanceCard()))),
        ),
      );
      expect(c.read(perfOverlayProvider), isFalse);
      expect(find.byKey(const ValueKey('frame-stats')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('perf-overlay')));
      await tester.pump();
      expect(c.read(perfOverlayProvider), isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
