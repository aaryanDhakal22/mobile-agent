// 1.8.0 (Pi 2.3.0, hub 0.2.0): terminal changes (the blue CHANGED alert,
// the CHANGED ticket), finishing orders, the order callout settings.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/alert_player.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/motion.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/ring_bridge.dart';
import 'package:mobile_agent/core/ring_platform.dart';
import 'package:mobile_agent/core/soft_chime.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/alert/new_order_alert.dart';
import 'package:mobile_agent/features/kitchen/kitchen_pane.dart';
import 'package:mobile_agent/features/settings/callout_cards.dart';
import 'package:mobile_agent/theme/quicc_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'pos_fixtures.dart';

const _paired = {
  'agent_address': 'http://192.168.1.219:8080',
  'device_key': 'qagt_test',
  'device_name': 'Counter tablet',
  'device_id': 'dev-1',
};

/// A POS takeout cooking, #158, with a change: +1 Garlic Knots (ADDED), −1
/// Coke (REMOVED). [acked] = OK'd that long ago.
Map<String, dynamic> changedJson({String id = 'pos-158', String changeId = 'c1', Duration? acked, String kind = 'cooking'}) {
  final m = jsonDecode(posDeliveryJson) as Map<String, dynamic>;
  final now = DateTime.now().toUtc();
  final order = m['order'] as Map<String, dynamic>;
  order
    ..['id'] = id
    ..['fulfillment'] = {'type': 'pickup'}
    ..['items'] = [
      {'id': 'l1', 'name': 'Cheese Steak', 'quantity': 1, 'pos_ref': '1', 'kitchen': true},
      {'id': 'l3', 'name': 'Garlic Knots', 'quantity': 1, 'pos_ref': '3', 'kitchen': true, 'added': true},
    ]
    ..['removed_items'] = [
      {'id': 'l2', 'name': 'Coke', 'quantity': 1, 'pos_ref': '2'},
    ];
  m.remove('geo');
  (m['status'] as Map<String, dynamic>)
    ..['display_number'] = 158
    ..['accepted_at'] = now.subtract(const Duration(minutes: 3)).toIso8601String()
    ..['sent_at'] = now.subtract(const Duration(minutes: 3)).toIso8601String()
    ..['estimated_ready_at'] = now.add(const Duration(minutes: 12)).toIso8601String()
    ..remove('flag')
    ..remove('pos_driver_note')
    ..['pos_change'] = {
      'id': changeId,
      'at': now.subtract(const Duration(seconds: 5)).toIso8601String(),
      'kind': kind,
      'text': '#158 changed: +1 Garlic Knots, −1 Coke',
      'added': [
        {'name': 'Garlic Knots', 'quantity': 1, 'kitchen': true},
      ],
      'removed': [
        {'name': 'Coke', 'quantity': 1, 'kitchen': false},
      ],
      'driver_name': kind == 'out' ? 'Abdul' : '',
      if (acked != null) 'acked_at': now.subtract(acked).toIso8601String(),
    };
  return m;
}

StoredOrder changed({Duration? acked, String kind = 'cooking'}) => StoredOrder.fromJson(changedJson(acked: acked, kind: kind));

Floor _floor() => Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>);

FloorState floorOf(List<StoredOrder> current, {List<StoredOrder> arrived = const []}) =>
    const FloorState(
      connection: SseStatus.connected,
    ).withSnapshot(floor: _floor(), current: current, arrived: arrived, drivers: const [], at: DateTime.now());

class FakeFloor extends FloorController {
  final FloorState initial;
  FakeFloor(this.initial);
  @override
  FloorState build() => initial;
  @override
  Future<void> refresh() async {}
  void push(FloorState s) => state = s;
}

class FakeChime implements SoftChime {
  int plays = 0;
  @override
  Future<void> play() async => plays++;
}

class FakeRing extends RingPlatform {
  @override
  Future<bool> startService(String text) async => true;
  @override
  Future<void> updateService(String text) async {}
  @override
  Future<void> stopService() async {}
  @override
  Future<bool> showRing({required String title, required String text}) async => true;
  @override
  Future<void> cancelRing() async {}
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

Future<ProviderContainer> container(
  FloorState floor, {
  Future<http.Response> Function(http.Request req)? handler,
  Map<String, Object> prefs = _paired,
  SoftChime? chime,
}) async {
  AlertPlayer.resetForTest(QuietSink());
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(sp),
      floorProvider.overrideWith(() => FakeFloor(floor)),
      ringPlatformProvider.overrideWithValue(FakeRing()),
      softChimeProvider.overrideWithValue(chime ?? FakeChime()),
      agentClientProvider.overrideWith(
        (ref) => AgentClient(
          baseUrl: 'http://192.168.1.219:8080',
          deviceKey: 'qagt_test',
          client: MockClient(handler ?? (_) async => http.Response('{"error":"nope"}', 500)),
        ),
      ),
    ],
  );
}

Future<void> pumpApp(WidgetTester tester, ProviderContainer c, {Widget? home, bool dark = true}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: dark ? QuiccTheme.dark() : QuiccTheme.light(),
        home: home ?? const Scaffold(body: Center(child: Text('home'))),
        builder: (context, child) => AlarmHost(child: child!),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('models', () {
    test('a terminal change, line marks, removed lines, finishing, callout', () {
      final so = changed();
      final c = so.status.posChange!;
      expect(c.id, 'c1');
      expect(c.pending, isTrue);
      expect(c.added.single.name, 'Garlic Knots');
      expect(c.removed.single.kitchen, isFalse);
      expect(so.changePending, isTrue);
      expect(so.order.items[1].added, isTrue);
      expect(so.order.items[1].posRef, '3');
      expect(so.order.items[1].kitchen, isTrue);
      expect(so.order.removedItems.single.name, 'Coke');
      // OK'd: no longer rings; the tag stays 10 min while it cooks.
      final acked = changed(acked: const Duration(minutes: 4));
      expect(acked.changePending, isFalse);
      expect(acked.changedTag(DateTime.now()), isTrue);
      expect(changed(acked: const Duration(minutes: 11)).changedTag(DateTime.now()), isFalse);

      final fin = StoredOrder.fromJson({
        'order': {'id': 'p'},
        'status': {'state': 'ready', 'finished_at': '2026-10-26T20:00:00Z', 'finished_by': 'pos', 'pos_closed': true},
      });
      expect(fin.isPickedUp, isTrue);
      expect(fin.status.finishedBy, 'pos');
      expect(fin.status.posClosed, isTrue);

      final s = FloorSettings.fromJson({
        'finishing': {'online_pickup_minutes': 45},
        'callout': {'enabled': false, 'voice': 'kokoro:bf_emma', 'volume': 60, 'music_dip': 40, 'restore_seconds': 3, 'chime': false},
      });
      expect(s.finishing.onlinePickupMinutes, 45);
      expect(s.callout, const CalloutSettings(enabled: false, voice: 'kokoro:bf_emma', volume: 60, musicDip: 40, restoreSeconds: 3, chime: false));
      // An older Pi: defaults.
      expect(FloorSettings.fromJson(const {}).callout, const CalloutSettings());
      expect(FloorSettings.fromJson(const {}).finishing.onlinePickupMinutes, 30);

      final st = IntegrationStatus.fromJson({
        'connected': true,
        'callout': {
          'voice': 'kokoro:af_heart',
          'default_voice': 'kokoro:af_heart',
          'installed': true,
          'voices': [
            {'id': 'kokoro:af_heart', 'name': 'Heart', 'about': 'Warm', 'ready': 999, 'total': 999},
          ],
          'rendering': {'voice': 'kokoro:af_heart', 'done': 12, 'total': 999},
          'last': {'number': 102, 'kind': 'ready', 'ok': true},
        },
      })!;
      expect(st.callout!.voices.single.label, 'Heart');
      expect(st.callout!.rendering, isTrue);
      expect(st.callout!.last!.number, 102);
    });
  });

  group('floor state', () {
    test('order.changed stores the order; pendingChanges lists it until OK', () {
      final s = floorOf(const []);
      final next = applySseEvent(
        s,
        SseEvent('order.changed', jsonEncode({'order': changedJson(), 'change': changedJson()['status']['pos_change']})),
      ).state;
      expect(next.pendingChanges.map((o) => o.id), ['pos-158']);
      final acked = applySseEvent(next, SseEvent('order.updated', jsonEncode(changedJson(acked: Duration.zero)))).state;
      expect(acked.pendingChanges, isEmpty);
    });

    test('a hidden check shown later chimes as new', () {
      final hidden = changedJson()..['status']['board_hidden'] = true;
      (hidden['status'] as Map).remove('pos_change');
      var s = applySseEvent(floorOf(const []), SseEvent('order.added', jsonEncode({'order': hidden, 'chime': false}))).state;
      expect(s.chimes, 0);
      final shown = changedJson()..['status']['board_hidden'] = false;
      (shown['status'] as Map).remove('pos_change');
      s = applySseEvent(s, SseEvent('order.added', jsonEncode({'order': shown, 'chime': true}))).state;
      expect(s.chimes, 1);
      s = applySseEvent(s, SseEvent('order.added', jsonEncode({'order': shown, 'chime': true}))).state;
      expect(s.chimes, 1, reason: 'a replayed frame does not chime again');
    });
  });

  group('CHANGED alert', () {
    testWidgets('shows over any screen, says what changed, OK clears it on the Pi', (tester) async {
      http.Request? sent;
      final c = await container(
        floorOf([changed()]),
        handler: (req) async {
          sent = req;
          return http.Response.bytes(utf8.encode(jsonEncode(changedJson(acked: Duration.zero))), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        },
      );
      addTearDown(c.dispose);
      await pumpApp(tester, c);
      // Over a pushed route too.
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('order details')))));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('change-alert')), findsOneWidget);
      expect(find.text('#158 CHANGED'), findsOneWidget);
      expect(find.text('+1 Garlic Knots'), findsOneWidget);
      expect(find.text('−1 Coke'), findsOneWidget);
      expect(find.text('REMOVED'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('change-ok')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(sent?.url.path, '/api/orders/pos-158/change/ack');
      expect(jsonDecode(sent!.body), {'change_id': 'c1'});
      expect(find.byKey(const ValueKey('change-alert')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('waits behind a ringing new order, then shows', (tester) async {
      final ringing = floorOf([changed()], arrived: [StoredOrder.fromJson(jsonDecode(arrivedPickupJson) as Map<String, dynamic>)]);
      final c = await container(ringing);
      addTearDown(c.dispose);
      await pumpApp(tester, c);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(NewOrderAlert), findsOneWidget);
      expect(find.byKey(const ValueKey('change-alert')), findsNothing);
      // The new order is accepted: the change comes up.
      (c.read(floorProvider.notifier) as FakeFloor).push(floorOf([changed()]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(NewOrderAlert), findsNothing);
      expect(find.byKey(const ValueKey('change-alert')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('chimes on show and every 30 s until OK, not while a new order rings', (tester) async {
      final chime = FakeChime();
      final c = await container(floorOf(const []), chime: chime);
      addTearDown(c.dispose);
      final undo = startRingBridge(c);
      addTearDown(undo);
      final floor = c.read(floorProvider.notifier) as FakeFloor;
      floor.push(floorOf([changed()]));
      await tester.pump();
      expect(chime.plays, 1);
      await tester.pump(kChangeRechime + const Duration(seconds: 1));
      expect(chime.plays, 2);
      await tester.pump(kChangeRechime);
      expect(chime.plays, 3);
      // OK'd: quiet.
      floor.push(floorOf([changed(acked: Duration.zero)]));
      await tester.pump(kChangeRechime * 3);
      expect(chime.plays, 3);
      // A new change while a new order rings: the ring first, the chime after.
      final arrived = StoredOrder.fromJson(jsonDecode(arrivedPickupJson) as Map<String, dynamic>);
      floor.push(floorOf([StoredOrder.fromJson(changedJson(changeId: 'c2'))], arrived: [arrived]));
      await tester.pump(kChangeRechime * 2);
      expect(chime.plays, 3);
      floor.push(floorOf([StoredOrder.fromJson(changedJson(changeId: 'c2'))]));
      await tester.pump();
      expect(chime.plays, 4);
      floor.push(floorOf(const [])); // OK'd everywhere: the re-chime timer stops
      await tester.pump();
    });
  });

  group('kitchen ticket', () {
    for (final motion in [true, false]) {
      testWidgets('CHANGED tag, blue outline, ADDED + REMOVED lines (motion ${motion ? 'on' : 'off'})', (tester) async {
        final c = await container(floorOf([changed(acked: const Duration(minutes: 1))]));
        addTearDown(c.dispose);
        c.read(motionProvider.notifier).setEnabled(motion);
        await pumpApp(tester, c, home: const Scaffold(body: KitchenPane()));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('changed-tag')), findsOneWidget);
        expect(find.textContaining('CHANGED · +1 Garlic Knots'), findsOneWidget);
        expect(find.byKey(const ValueKey('changed-glow')), findsOneWidget);
        expect(find.byKey(const ValueKey('added-l3')), findsOneWidget);
        expect(find.byKey(const ValueKey('removed-l2')), findsOneWidget);
        // OK'd, the alert is not up.
        expect(find.byKey(const ValueKey('change-alert')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('no tag 10 min after OK', (tester) async {
      final c = await container(floorOf([changed(acked: const Duration(minutes: 11))]));
      addTearDown(c.dispose);
      await pumpApp(tester, c, home: const Scaffold(body: KitchenPane()));
      expect(find.byKey(const ValueKey('changed-tag')), findsNothing);
      expect(find.byKey(const ValueKey('removed-l2')), findsOneWidget, reason: 'the struck line stays');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('settings', () {
    final calloutJson = {
      'settings': {'enabled': true, 'voice': '', 'volume': 90, 'music_dip': 70, 'restore_seconds': 1.5, 'chime': true},
      'hub_connected': true,
      'hub': {
        'voice': 'kokoro:af_heart',
        'default_voice': 'kokoro:af_heart',
        'installed': true,
        'voices': [
          {'id': 'kokoro:af_heart', 'name': 'Heart', 'about': 'Warm US English', 'ready': 999, 'total': 999},
          {'id': 'kokoro:bf_emma', 'name': 'Emma', 'about': 'British English', 'ready': 3, 'total': 999},
        ],
        'rendering': null,
        'last': {'number': 102, 'kind': 'ready', 'ok': true, 'at': '2026-10-26T20:00:00Z'},
      },
    };

    testWidgets('order callout card: switch, TEST CALLOUT, PREVIEW on the store speaker', (tester) async {
      final reqs = <http.Request>[];
      final c = await container(
        floorOf(const []),
        handler: (req) async {
          reqs.add(req);
          switch (req.url.path) {
            case '/api/callout':
              return http.Response(jsonEncode(calloutJson), 200);
            case '/api/settings/callout':
              return http.Response(req.body, 200);
            case '/api/callout/test':
              return http.Response(jsonEncode({'id': 't1', 'hub_connected': true}), 202);
          }
          return http.Response('{}', 404);
        },
      );
      addTearDown(c.dispose);
      await pumpApp(tester, c, home: const Scaffold(body: SingleChildScrollView(child: OrderCalloutCard())));
      await tester.pumpAndSettle();
      expect(find.text('Store speaker ready'), findsOneWidget);
      expect(find.textContaining('Last called: #102'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('callout-switch')));
      await tester.pumpAndSettle();
      final put = reqs.lastWhere((r) => r.url.path == '/api/settings/callout');
      expect(put.method, 'PUT');
      expect((jsonDecode(put.body) as Map)['enabled'], false);

      await tester.enterText(find.byKey(const ValueKey('callout-number')), '213');
      await tester.tap(find.byKey(const ValueKey('callout-test')));
      await tester.pumpAndSettle();
      final t = reqs.lastWhere((r) => r.url.path == '/api/callout/test');
      expect(jsonDecode(t.body), {'number': 213, 'voice': '', 'kind': 'test'});

      await tester.tap(find.byKey(const ValueKey('callout-preview')));
      await tester.pumpAndSettle();
      final p = reqs.lastWhere((r) => r.url.path == '/api/callout/test');
      expect(jsonDecode(p.body), {'number': 213, 'voice': 'kokoro:af_heart', 'kind': 'preview'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('finishing card: online minutes saved, terminal rule shown', (tester) async {
      http.Request? put;
      final c = await container(
        floorOf(const []),
        handler: (req) async {
          if (req.method == 'PUT') {
            put = req;
            return http.Response(req.body, 200);
          }
          return http.Response(jsonEncode({'online_pickup_minutes': 30}), 200);
        },
      );
      addTearDown(c.dispose);
      await pumpApp(tester, c, home: const Scaffold(body: SingleChildScrollView(child: FinishingOrdersCard())));
      await tester.pumpAndSettle();
      expect(find.text('30 min'), findsOneWidget);
      expect(find.text('When SoftTouch closes the check'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('finishing-plus')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('finishing-save')));
      await tester.pumpAndSettle();
      expect(put?.url.path, '/api/settings/finishing');
      expect(jsonDecode(put!.body), {'online_pickup_minutes': 35});
      expect(c.read(floorProvider).settings.finishing.onlinePickupMinutes, 35);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an older Pi: coming with the next update', (tester) async {
      final c = await container(floorOf(const []), handler: (_) async => http.Response('404 page not found', 404));
      addTearDown(c.dispose);
      await pumpApp(
        tester,
        c,
        home: const Scaffold(body: SingleChildScrollView(child: Column(children: [OrderCalloutCard(), FinishingOrdersCard()]))),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('coming-callout')), findsOneWidget);
      expect(find.byKey(const ValueKey('coming-finishing')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
