// Quibase 1.7.1 (with agent 2.2.1): NOT DELIVERED (TRY AGAIN → "Came back",
// CANCEL ORDER → History, cancelled), the came-back section with its
// hold-to-release, the "hold the far one" check before SEND OUT, AUTO's
// "held for" tag, the out drivers' addresses in stop order, and the Map
// pane kept built (with its refresh button).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/delivery_models.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/core/time.dart';
import 'package:mobile_agent/features/deliveries/came_back.dart';
import 'package:mobile_agent/features/deliveries/deliveries_pane.dart';
import 'package:mobile_agent/features/dev/dev_gate.dart';
import 'package:mobile_agent/features/history/history_pane.dart';
import 'package:mobile_agent/features/home/home_nav.dart';
import 'package:mobile_agent/features/home/home_screen.dart';
import 'package:mobile_agent/features/home/idle_kitchen.dart';
import 'package:mobile_agent/features/kitchen/kitchen_pane.dart';
import 'package:mobile_agent/features/maps/runs_map_pane.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:mobile_agent/features/settings/auto_assign_card.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';

/// Sam's order out on delivery (the fixture): kitchen #1104, batch 7.
const _samOrder = '01963a40-7c1e-7a51-9d2b-5d1f0c2a0002';

/// A Pi answering [handler]; records each request as "METHOD path body".
(AgentClient, List<String>, List<bool>) _pi(http.Response Function(http.Request req) handler) {
  final calls = <String>[];
  final revoked = <bool>[];
  final client = AgentClient(
    baseUrl: 'http://10.0.0.5:8080',
    deviceKey: 'qagt_k',
    client: MockClient((req) async {
      calls.add('${req.method} ${req.url.path}${req.url.hasQuery ? '?${req.url.query}' : ''} ${req.body}');
      return handler(req);
    }),
    onDeviceRevoked: () => revoked.add(true),
  );
  return (client, calls, revoked);
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// The on-delivery fixture as JSON with [status] fields changed.
Map<String, dynamic> _orderJson({String id = _samOrder, int k = 1104, Map<String, Object?> status = const {}}) {
  final m = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
  (m['order'] as Map)
    ..['id'] = id
    ..['kitchen_order_number'] = k;
  (m['status'] as Map<String, dynamic>)
    ..['kitchen_number'] = k
    ..addAll(status);
  (m['status'] as Map).removeWhere((_, v) => v == null);
  return m;
}

/// What TRY AGAIN leaves on the Pi: ready, no driver, came back.
Map<String, dynamic> _cameBackJson({String id = 'cb1', int k = 1110, int backMin = 3}) => _orderJson(
  id: id,
  k: k,
  status: {
    'state': 'ready',
    'out_at': null,
    'driver_id': null,
    'driver_name': null,
    'came_back': true,
    'not_delivered': {
      'action': 'retry',
      'at': timeNow().toUtc().subtract(Duration(minutes: backMin)).toIso8601String(),
      'driver_id': 'd-sam',
    },
  },
);

StoredOrder _cameBack({String id = 'cb1', int k = 1110}) => StoredOrder.fromJson(_cameBackJson(id: id, k: k));

/// The delivery floor plus one came-back delivery.
FloorState _floorWithCameBack() => deliveryFloor().withOrder(_cameBack());

Future<ProviderContainer> _pumpPane(WidgetTester tester, FakeDeliveryFloor f, {List<Override> extra = const [], Map<String, Object> prefs = const {}}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = await deliveryContainer(f, extra: extra, prefs: prefs);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: DeliveriesPane())),
    ),
  );
  await tester.pump();
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

double _progress(WidgetTester tester, String id) =>
    tester.widget<FractionallySizedBox>(find.byKey(ValueKey('came-back-progress-$id'))).widthFactor!;

void main() {
  group('models', () {
    test('came_back + not_delivered parse; absent = false / null', () {
      final o = _cameBack();
      expect(o.status.cameBack, isTrue);
      expect(o.status.notDelivered!.action, NotDeliveredAction.retry);
      expect(o.status.notDelivered!.driverId, 'd-sam');
      expect(o.status.notDelivered!.at, isNotNull);
      expect(o.isCameBack, isTrue);
      expect(o.isPoolable, isFalse, reason: 'never in a pool');
      // The optimistic pool copy keeps them.
      expect(o.status.withPool(null).cameBack, isTrue);
      expect(o.status.withPool(null).notDelivered, isNotNull);

      final plain = StoredOrder.fromJson(jsonDecode(onDeliveryJson) as Map<String, dynamic>);
      expect(plain.status.cameBack, isFalse);
      expect(plain.status.notDelivered, isNull);
      // A cancelled one is not "came back", whatever the flag says.
      final cancelled = StoredOrder.fromJson(_orderJson(status: {'state': 'cancelled', 'came_back': true}));
      expect(cancelled.isCameBack, isFalse);
    });

    test('came-back deliveries stay out of unassigned, pools, out runs; SSE moves them in and out', () {
      var s = _floorWithCameBack();
      expect(s.cameBackDeliveries.map((o) => o.id), ['cb1']);
      expect(s.unassignedDeliveries.map((o) => o.id), isNot(contains('cb1')));
      for (final d in s.drivers) {
        expect(s.poolFor(d.id).map((o) => o.id), isNot(contains('cb1')));
      }
      // Even still pooled / on_delivery on the wire, it is in no other list.
      s = s.withOrder(StoredOrder.fromJson(_orderJson(status: {'state': 'on_delivery', 'came_back': true, 'pool_driver_id': 'd-ana'})));
      expect(s.onDelivery.map((o) => o.id), isNot(contains(_samOrder)));
      expect(s.outWith('d-sam'), isEmpty);
      expect(s.poolFor('d-ana').map((o) => o.id), isNot(contains(_samOrder)));

      // Released on the Pi (another tablet): back in Unassigned.
      final released = _cameBackJson()..['status'] = {...(_cameBackJson()['status'] as Map), 'came_back': false};
      s = applySseEvent(s, SseEvent('order.updated', jsonEncode(released))).state;
      expect(s.cameBackDeliveries.map((o) => o.id), isNot(contains('cb1')));
      expect(s.unassignedDeliveries.map((o) => o.id), contains('cb1'));
    });

    test('run_order_ids put an out run in stop order (unknown field = the run as it was)', () {
      final d = Driver.fromJson({
        'id': 'd-sam',
        'name': 'Sam',
        'status': 'out',
        kDriverRunOrderField: ['b', 'x', 'a'],
      });
      expect(d.runOrderIds, ['b', 'x', 'a']);
      final a = StoredOrder.fromJson(_orderJson(id: 'a'));
      final b = StoredOrder.fromJson(_orderJson(id: 'b'));
      final c = StoredOrder.fromJson(_orderJson(id: 'c'));
      expect(inStopOrder([a, b, c], d).map((o) => o.id), ['b', 'a', 'c']);
      expect(inStopOrder([a, b], Driver.fromJson({'id': 'd-sam', 'name': 'Sam'})).map((o) => o.id), ['a', 'b']);
    });

    test('AUTO leftovers held for a driver on his way back', () {
      final plan = AutoPlan.fromJson({
        'plan_id': 'p',
        'unassigned': [
          {
            'order_id': 'd5',
            'reason': 'held_for_returning_driver',
            'held_for': {'driver_id': 'd-abdul', 'name': 'Abdul', 'return_at': '2026-05-12T18:06:00Z'},
          },
          {'order_id': 'd2', 'reason': 'not_ready_soon'},
        ],
      });
      final h = plan.unassigned.first.heldFor!;
      expect(h.name, 'Abdul');
      expect(h.backIn(DateTime.utc(2026, 5, 12, 18)), '~6 min');
      expect(h.backIn(DateTime.utc(2026, 5, 12, 18, 7)), 'any minute');
      expect(plan.unassigned.last.heldFor, isNull);
    });
  });

  group('Pi client', () {
    test('not-delivered: POST {action}; the 2.2.1 errors read as codes; an older Pi is "needs update", never unpairs', () async {
      final (client, calls, revoked) = _pi((req) => _json(_cameBackJson(id: _samOrder)));
      final o = await client.notDelivered(_samOrder, NotDeliveredAction.retry);
      expect(calls.single, 'POST /api/orders/$_samOrder/not-delivered {"action":"retry"}');
      expect(o.status.cameBack, isTrue);

      Future<AgentException> refuse(http.Response r) async {
        final (cl, _, rv) = _pi((_) => r);
        try {
          await cl.notDelivered('x', NotDeliveredAction.cancel);
        } on AgentException catch (e) {
          revoked.addAll(rv);
          return e;
        }
        throw StateError('no error');
      }

      expect((await refuse(_json({'error': 'not_out_or_delivered'}, 409))).code, 'not_out_or_delivered');
      expect((await refuse(_json({'error': 'bad_action'}, 400))).code, 'bad_action');
      expect((await refuse(http.Response('404 page not found', 404))).code, kNotDeliveredUnsupported);
      expect((await refuse(http.Response('Method Not Allowed', 405))).code, kNotDeliveredUnsupported);
      expect((await refuse(_json({'error': 'nope', 'code': 'not_found'}, 404))).code, 'not_found');
      final e401 = await refuse(_json({'code': 'device_required', 'error': 'log in'}, 401));
      expect(e401.statusCode, 401);
      expect(revoked, isEmpty, reason: 'NOT DELIVERED must never unpair the tablet');
    });

    test('release: POST; 409 not_came_back', () async {
      final (client, calls, _) = _pi((req) => _json({'error': 'not_came_back'}, 409));
      await expectLater(
        client.releaseCameBack('cb1'),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', 'not_came_back')),
      );
      expect(calls.single, 'POST /api/orders/cb1/release ');
    });

    test('pool / send-out refuse a came-back delivery with kCameBack; send-out carries exclude_order_ids', () async {
      final (client, calls, _) = _pi((req) => req.url.path.endsWith('/pool') ? _json({'error': 'came_back'}, 409) : _json([]));
      await expectLater(
        client.poolOrders(['cb1'], driverId: 'd-ana'),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', kCameBack)),
      );
      await client.sendOut('d-ana', excludeOrderIds: ['d3']);
      expect(calls.last, contains('"exclude_order_ids":["d3"]'));
    });

    test('send-check: holds parse; an older Pi (404) is null and never unpairs', () async {
      final (client, calls, _) = _pi(
        (req) => _json({
          'hold': [
            {
              'order_id': 'd3',
              'address': '1634 Gleneagle Rd',
              'held_for': {'driver_id': 'd-abdul', 'name': 'Abdul', 'return_at': '2026-05-12T18:06:00Z'},
            },
          ],
        }),
      );
      final h = (await client.sendCheck('d-ana', ['d3', 'd1']))!;
      expect(calls.single, startsWith('GET /api/drivers/d-ana/send-check?order_ids=d3%2Cd1'));
      expect(h.single.address, '1634 Gleneagle Rd');
      expect(h.single.heldFor!.name, 'Abdul');

      final (old, _, revoked) = _pi((_) => http.Response('404 page not found', 404));
      expect(await old.sendCheck('d-ana', ['d3']), isNull);
      final (web, _, revoked2) = _pi((_) => _json({'code': 'device_required'}, 401));
      await expectLater(web.sendCheck('d-ana', ['d3']), throwsA(isA<AgentException>()));
      expect([...revoked, ...revoked2], isEmpty);
    });
  });

  group('Came back section', () {
    testWidgets('below Unassigned under a rule, not draggable or selectable; absent when empty', (tester) async {
      final f = FakeDeliveryFloor(_floorWithCameBack());
      await _pumpPane(tester, f);
      expect(find.text('Came back · 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('came-back-hr')), findsOneWidget);
      expect(find.textContaining('1 came back'), findsOneWidget);
      // The regular list is untouched and sits above the rule.
      expect(find.text('Unassigned · 3'), findsOneWidget);
      final row = find.byKey(const ValueKey('came-back-cb1'));
      expect(tester.getTopLeft(row).dy, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('row-d1'))).dy));
      expect(tester.getTopLeft(row).dy, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('came-back-hr'))).dy));
      expect(find.byKey(const ValueKey('row-cb1')), findsNothing);

      // A long drag onto Ana's box pools nothing.
      final g = await tester.startGesture(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 1500));
      await g.moveTo(tester.getCenter(find.byKey(const ValueKey('driver-d-ana'))));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(callsOf(f, 'pool'), isEmpty);

      // Select mode: tapping it selects nothing (just the hint).
      await tester.tap(find.byKey(const ValueKey('select')));
      await tester.pump();
      await tester.tap(row);
      await tester.pump();
      expect(find.text('0 selected'), findsOneWidget);

      f.push(deliveryFloor());
      await tester.pump();
      expect(find.byKey(const ValueKey('came-back-section')), findsNothing);
      expect(find.byKey(const ValueKey('came-back-hr')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a tap says how; letting go early empties the bar; a full hold sends it to Unassigned', (tester) async {
      final (client, calls, _) = _pi(
        (req) => _json(_cameBackJson()..['status'] = {...(_cameBackJson()['status'] as Map), 'came_back': false}),
      );
      final f = FakeDeliveryFloor(_floorWithCameBack());
      final c = await _pumpPane(tester, f, extra: [agentClientProvider.overrideWithValue(client)]);
      final row = find.byKey(const ValueKey('came-back-cb1'));

      await tester.tap(row);
      await tester.pump();
      expect(find.text(kCameBackTapHint), findsOneWidget);
      expect(calls, isEmpty);

      // Half a hold, then let go.
      var g = await tester.startGesture(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 100)); // tap-down
      await tester.pump(const Duration(milliseconds: 400));
      expect(_progress(tester, 'cb1'), closeTo(0.4, 0.15), reason: 'fills left to right');
      await g.up();
      await tester.pump();
      expect(_progress(tester, 'cb1'), 0);
      expect(calls, isEmpty);

      // The whole hold.
      g = await tester.startGesture(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await g.up();
      await tester.pump();
      await tester.pump();
      expect(calls.single, 'POST /api/orders/cb1/release ');
      expect(c.read(floorProvider).unassignedDeliveries.map((o) => o.id), contains('cb1'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('came-back-section')), findsNothing);
      expect(find.byKey(const ValueKey('row-cb1')), findsOneWidget);
      expect(find.text('#1110 is back in Unassigned'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the hold follows the animation speed (2× slower = 2 s)', (tester) async {
      final (client, calls, _) = _pi((req) => _json({'error': 'not_came_back'}, 409));
      final f = FakeDeliveryFloor(_floorWithCameBack());
      await _pumpPane(tester, f, extra: [agentClientProvider.overrideWithValue(client)], prefs: {'motion_speed': 2.0});
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('came-back-cb1'))));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1200));
      expect(calls, isEmpty, reason: 'not yet at 1.2 s');
      expect(_progress(tester, 'cb1'), closeTo(0.6, 0.1));
      await tester.pump(const Duration(milliseconds: 900));
      await g.up();
      await tester.pump();
      await tester.pump();
      expect(calls, hasLength(1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('#1110 is already back in Unassigned.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('NOT DELIVERED', () {
    Future<(ProviderContainer, List<String>, List<bool>)> openDetail(
      WidgetTester tester,
      http.Response Function(http.Request) handler, {
      FloorState? floor,
      String id = _samOrder,
    }) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (client, calls, revoked) = _pi(handler);
      final f = FakeDeliveryFloor(floor ?? deliveryFloor());
      final c = await deliveryContainer(f, extra: [agentClientProvider.overrideWithValue(client)]);
      addTearDown(c.dispose);
      final o = c.read(floorProvider).orders[id]!;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: OrderDetailScreen(orderId: id, initial: o)),
        ),
      );
      await tester.pump();
      return (c, calls, revoked);
    }

    final button = find.byKey(const ValueKey('not-delivered'));

    testWidgets('TRY AGAIN: no reason asked; the order goes to Came back', (tester) async {
      final (c, calls, _) = await openDetail(tester, (_) => _json(_cameBackJson(id: _samOrder, k: 1104)));
      expect(button, findsOneWidget);
      await tester.tap(button);
      await _settle(tester);
      expect(find.text('#1104 came back'), findsOneWidget);
      expect(find.text('TRY AGAIN'), findsOneWidget);
      expect(find.text('CANCEL ORDER'), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'no reason is asked');
      await tester.tap(find.byKey(const ValueKey('not-delivered-retry')));
      await _settle(tester);
      expect(calls.single, 'POST /api/orders/$_samOrder/not-delivered {"action":"retry"}');
      final s = c.read(floorProvider);
      expect(s.cameBackDeliveries.map((o) => o.id), [_samOrder]);
      expect(find.byKey(const ValueKey('came-back-note')), findsOneWidget);
      expect(button, findsNothing, reason: 'already came back');
      expect(find.text('#1104 is back on Deliveries, under Came back'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('CANCEL ORDER asks first, then History shows it cancelled with no driver', (tester) async {
      final cancelled = _orderJson(
        status: {'state': 'cancelled', 'cancelled_at': '2026-05-12T17:55:00Z', 'not_delivered': {'action': 'cancel', 'at': '2026-05-12T17:55:00Z', 'driver_id': 'd-sam'}},
      );
      final (c, calls, _) = await openDetail(tester, (_) => _json(cancelled));
      await tester.tap(button);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('not-delivered-cancel')));
      await _settle(tester);
      expect(find.text('Cancel #1104?'), findsOneWidget);
      expect(find.text('It moves to History as cancelled.'), findsOneWidget);
      // Back out once: nothing sent.
      await tester.tap(find.text('Back'));
      await _settle(tester);
      expect(calls, isEmpty);

      await tester.tap(button);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('not-delivered-cancel')));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'CANCEL ORDER'));
      await _settle(tester);
      expect(calls.single, 'POST /api/orders/$_samOrder/not-delivered {"action":"cancel"}');
      final o = c.read(floorProvider).orders[_samOrder]!;
      expect(o.state, OrderState.cancelled);

      // History: CANCELLED, and no driver even though the snapshot names Sam.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: Scaffold(body: HistoryRow(order: o))),
        ),
      );
      expect(find.text('CANCELLED'), findsOneWidget);
      expect(find.textContaining('driver Sam'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an older Pi (404): "This Pi needs an update", the action hides, the tablet stays paired', (tester) async {
      final (c, calls, revoked) = await openDetail(tester, (_) => http.Response('404 page not found', 404));
      await tester.tap(button);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('not-delivered-retry')));
      await _settle(tester);
      expect(calls, hasLength(1));
      expect(find.text('This Pi needs an update'), findsOneWidget);
      expect(button, findsNothing);
      expect(c.read(notDeliveredUnsupportedProvider), isTrue);
      expect(revoked, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('409 (not out any more) says so in plain words', (tester) async {
      await openDetail(tester, (_) => _json({'error': 'not_out_or_delivered'}, 409));
      await tester.tap(button);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('not-delivered-retry')));
      await _settle(tester);
      expect(find.text("#1104 isn't out or delivered any more — refreshed."), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('only for a delivery of the open batch that is out or delivered', (tester) async {
      Future<void> check(Map<String, Object?> status, Matcher m, {bool pickup = false}) async {
        final j = _orderJson(status: status);
        if (pickup) ((j['order'] as Map)['fulfillment'] as Map)['type'] = 'pickup';
        await openDetail(tester, (_) => _json({}), floor: deliveryFloor().withOrder(StoredOrder.fromJson(j)));
        expect(button, m, reason: '$status pickup=$pickup');
        await tester.pumpWidget(const SizedBox());
      }

      await check({'state': 'delivered', 'delivered_at': '2026-05-12T17:50:00Z'}, findsOneWidget);
      await check({'state': 'ready'}, findsNothing);
      await check({'state': 'on_delivery', 'batch_id': 6}, findsNothing);
      await check({'state': 'delivered'}, findsNothing, pickup: true);
    });
  });

  group('hold the far one (send-check)', () {
    /// Ana (NEXT) with d3 (ready) and d2 (cooking) in her box.
    FakeDeliveryFloor anaWithTwo() {
      final base = deliveryFloor();
      return FakeDeliveryFloor(
        base.withOrders([base.orders['d2']!.copyWith(status: base.orders['d2']!.status.withPool('d-ana'))]),
      );
    }

    HeldStop held(String id) => HeldStop.fromJson({
      'order_id': id,
      'address': '1634 Gleneagle Rd',
      'held_for': {
        'driver_id': 'd-abdul',
        'name': 'Abdul',
        'return_at': timeNow().toUtc().add(const Duration(minutes: 6)).toIso8601String(),
      },
    });

    final sendBar = find.byKey(const ValueKey('send-next'));

    testWidgets('HOLD sends without it (exclude_order_ids), then the cooking confirm', (tester) async {
      final f = anaWithTwo()..holds = [held('d3')];
      await _pumpPane(tester, f);
      await tester.tap(sendBar);
      await _settle(tester);
      expect(callsOf(f, 'sendCheck').single.ids.toSet(), {'d3', 'd2'});
      expect(find.text('1634 Gleneagle Rd is the other way — hold it for Abdul (back ~6 min)?'), findsOneWidget);
      expect(find.text('SEND BOTH'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hold')));
      await _settle(tester);
      // d2 is still cooking: the usual question comes next.
      expect(find.textContaining('send anyway?'), findsOneWidget);
      await tester.tap(find.text('SEND ANYWAY'));
      await _settle(tester);
      final s = callsOf(f, 'sendOut').single;
      expect(s.extra['exclude'], ['d3']);
      expect(s.extra['markReady'], isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('SEND BOTH sends as today; dismissing sends nothing', (tester) async {
      // Ana's box: d3 — plus d1 so there are two.
      final base = deliveryFloor();
      final f = FakeDeliveryFloor(base.withOrder(base.orders['d1']!.copyWith(status: base.orders['d1']!.status.withPool('d-ana'))))
        ..holds = [held('d3')];
      await _pumpPane(tester, f);
      await tester.tap(sendBar);
      await _settle(tester);
      await tester.tapAt(const Offset(5, 5)); // outside the dialog
      await _settle(tester);
      expect(callsOf(f, 'sendOut'), isEmpty);

      await tester.tap(sendBar);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('send-all')));
      await _settle(tester);
      final s = callsOf(f, 'sendOut').single;
      expect(s.extra['exclude'], isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an older Pi (no send-check) or nothing to hold: straight out', (tester) async {
      for (final holds in [null, const <HeldStop>[]]) {
        final f = FakeDeliveryFloor(deliveryFloor())..holds = holds;
        await _pumpPane(tester, f);
        await tester.tap(sendBar);
        await _settle(tester);
        expect(find.byKey(const ValueKey('hold')), findsNothing);
        expect(callsOf(f, 'sendOut'), hasLength(1));
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('AUTO: a delivery held for a returning driver is tagged on the left', (tester) async {
      final f = FakeDeliveryFloor(deliveryFloor())
        ..plan = AutoPlan.fromJson({
          'plan_id': 'plan-h',
          'runs': [
            {
              'driver_id': 'd-ana',
              'order_ids': ['d3', 'd1'],
              'suggested_ids': ['d1'],
            },
          ],
          'unassigned': [
            {
              'order_id': 'd5',
              'reason': 'held_for_returning_driver',
              'held_for': {
                'driver_id': 'd-sam',
                'name': 'Abdul',
                'return_at': timeNow().toUtc().add(const Duration(minutes: 6)).toIso8601String(),
              },
            },
          ],
        });
      await _pumpPane(tester, f);
      expect(find.textContaining('Held for'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('auto')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(of: find.byKey(const ValueKey('row-d5')), matching: find.text('Held for Abdul · ~6 min')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('drivers out: addresses in stop order', () {
    /// Sam out with two stops; the Pi says the second goes first.
    FloorState twoStops() {
      final base = deliveryFloor();
      final second = StoredOrder.fromJson(
        _orderJson(id: 'o2', k: 1112, status: {'out_at': '2026-05-12T17:33:00Z'})
          ..['order'] = {
            ...(_orderJson(id: 'o2', k: 1112)['order'] as Map),
            'fulfillment': {
              'type': 'delivery',
              'address': {'line1': '531 Stevenson Ln', 'city': 'Towson'},
            },
          },
      );
      final drivers = [
        for (final d in base.drivers)
          d.id == 'd-sam'
              ? Driver.fromJson({
                  'id': 'd-sam',
                  'name': 'Sam',
                  'position': 3,
                  'status': 'out',
                  kDriverRunOrderField: ['o2', _samOrder],
                })
              : d,
      ];
      return base.withOrder(second).copyWith(drivers: drivers);
    }

    testWidgets('Deliveries → Out: a pin in his colour + the street, stop order, tap opens', (tester) async {
      final f = FakeDeliveryFloor(twoStops());
      await _pumpPane(tester, f);
      final first = find.byKey(const ValueKey('out-stop-o2'));
      final second = find.byKey(const ValueKey('out-stop-$_samOrder'));
      expect(find.descendant(of: first, matching: find.text('531 Stevenson Ln')), findsOneWidget);
      expect(find.descendant(of: second, matching: find.text('931 Taylor Avenue')), findsOneWidget);
      expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
      final pin = tester.widget<Icon>(find.descendant(of: first, matching: find.byIcon(Icons.location_on)));
      expect(pin.color, driverColor(f.initial.drivers, 'd-sam'));
      await tester.tap(first);
      await _settle(tester);
      expect(find.byType(OrderDetailScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Map legend lists the same addresses in stop order', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await deliveryContainer(FakeDeliveryFloor(twoStops()));
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: RunsMapPane())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final a = find.byKey(const ValueKey('legend-stop-o2'));
      final b = find.byKey(const ValueKey('legend-stop-$_samOrder'));
      expect(a, findsOneWidget);
      expect(tester.getTopLeft(a).dy, lessThan(tester.getTopLeft(b).dy));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Map kept built', () {
    Future<(ProviderContainer, FakeDeliveryFloor)> pumpHome(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = FakeDeliveryFloor(deliveryFloor());
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const HomeScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      return (c, f);
    }

    final kept = find.byType(RunsMapPane, skipOffstage: false);

    Future<void> go(WidgetTester tester, ProviderContainer c, HomeDestination d) async {
      c.read(homeNavProvider.notifier).go(d);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('built at start (offstage, tickers off); the tab shows the same map, which stays when you leave', (tester) async {
      final (c, f) = await pumpHome(tester);
      // On Kitchen: the map is already there, hidden and quiet.
      expect(kept, findsOneWidget);
      expect(find.byType(RunsMapPane), findsNothing, reason: 'offstage');
      expect(tester.widget<RunsMapPane>(kept).active, isFalse);
      expect(TickerMode.valuesOf(tester.element(find.byType(FlutterMap, skipOffstage: false))).enabled, isFalse);
      expect(callsOf(f, 'trip'), isNotEmpty, reason: "Sam's route is fetched before anyone looks");
      final state = tester.state(kept);

      await go(tester, c, HomeDestination.map);
      expect(find.byType(RunsMapPane), findsOneWidget);
      expect(tester.state(kept), same(state), reason: 'not built again');
      expect(tester.widget<RunsMapPane>(kept).active, isTrue);
      expect(TickerMode.valuesOf(tester.element(find.byType(FlutterMap))).enabled, isTrue);
      expect(find.byIcon(Icons.local_shipping_outlined), findsOneWidget, reason: 'the driver button still floats over it');

      await go(tester, c, HomeDestination.deliveries);
      expect(find.byType(RunsMapPane), findsNothing);
      expect(tester.state(kept), same(state));
      expect(find.text('Unassigned · 3'), findsOneWidget);

      await go(tester, c, HomeDestination.map);
      expect(tester.state(kept), same(state));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('refresh reloads the base layer and asks for the routes again', (tester) async {
      final (c, f) = await pumpHome(tester);
      await go(tester, c, HomeDestination.map);
      expect(find.byKey(const ValueKey('base-0')), findsOneWidget);
      final trips = callsOf(f, 'trip').length;
      await tester.tap(find.byKey(const ValueKey('map-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('base-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('base-0')), findsNothing);
      expect(find.byKey(stubTilesKey), findsOneWidget);
      expect(callsOf(f, 'trip').length, greaterThan(trips));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no map file: nothing kept until the tab is opened; no refresh button', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await deliveryContainer(FakeDeliveryFloor(deliveryFloor()), map: null);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: MaterialApp(theme: darkTheme(), home: const HomeScreen())),
      );
      await tester.pump();
      expect(kept, findsNothing);
      await go(tester, c, HomeDestination.map);
      expect(find.text('Map not downloaded to the Pi yet.'), findsOneWidget);
      expect(find.byKey(const ValueKey('map-refresh')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('auto-assign (the fob pops on NEXT)', () {
    SseEvent assigned() => SseEvent(
      'deliveries.auto_assigned',
      jsonEncode({
        'driver_id': 'd-ana',
        'driver_name': 'Ana',
        'order_ids': ['d1', 'd5'],
      }),
    );
    final open = find.byKey(const ValueKey('fab-open'));

    test('models: auto_assign on the floor and in the settings; the returned answer, old and new', () {
      final f = deliveryFloor(floorExtra: {'auto_assign': true}).floor!;
      expect(f.autoAssign, isTrue);
      expect(deliveryFloor().floor!.autoAssign, isNull, reason: 'an older Pi');
      expect(const DeliverySettings(soonReadyMinutes: 5, deliveryTargetMinutes: 45).toJson().containsKey('auto_assign'), isFalse);
      expect(const DeliverySettings(soonReadyMinutes: 5, deliveryTargetMinutes: 45, autoAssign: false).toJson()['auto_assign'], isFalse);

      final old = ReturnedResult.fromJson([jsonDecode(onDeliveryJson)]);
      expect(old.orders, hasLength(1));
      expect(old.autoAssigned, isNull);
      final now = ReturnedResult.fromJson({
        'orders': [jsonDecode(onDeliveryJson)],
        'auto_assigned_order_ids': ['d1'],
        'auto_assigned_driver_id': 'd-ana',
      });
      expect(now.orders, hasLength(1));
      expect(now.autoAssigned!.orderIds, ['d1']);
      expect(AutoAssignment.fromJson({'driver_id': 'd-ana', 'order_ids': <String>[]}), isNull);
    });

    test("I'm back with auto_assigned_order_ids queues the pop (and the 2.2.0 list answer doesn't)", () async {
      for (final (body, pops) in [
        (
          {
            'orders': [jsonDecode(onDeliveryJson)],
            'auto_assigned_order_ids': ['d1', 'd5'],
            'auto_assigned_driver_id': 'd-ana',
          },
          true,
        ),
        ([jsonDecode(onDeliveryJson)], false),
      ]) {
        final (client, calls, _) = _pi((_) => _json(body));
        final c = await deliveryContainer(
          FakeDeliveryFloor(deliveryFloor()),
          extra: [floorProvider.overrideWith(_RealReturnFloor.new), agentClientProvider.overrideWithValue(client)],
        );
        c.read(floorProvider);
        await c.read(floorProvider.notifier).driverReturned('d-sam');
        expect(calls.first, startsWith('POST /api/drivers/d-sam/returned'));
        expect(c.read(fobPopProvider)?.orderIds, pops ? ['d1', 'd5'] : isNull);
        c.dispose();
      }
    });

    testWidgets('SSE deliveries.auto_assigned opens the fob on NEXT with the chime; closes after 30 s untouched', (tester) async {
      final (c, f) = await _home(tester);
      expect(open, findsNothing);
      final chimes = c.read(floorProvider).chimes;
      f.handleEvent(assigned());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(open, findsOneWidget);
      expect(find.byKey(const ValueKey('next-card')), findsOneWidget);
      expect(find.descendant(of: open, matching: find.textContaining('Ana')), findsWidgets);
      expect(c.read(floorProvider).chimes, chimes + 1);
      expect(c.read(fobPopProvider), isNull, reason: 'taken');
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(milliseconds: 600));
      expect(open, findsNothing, reason: 'nobody acted: it folds away (the pool stays)');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('waits behind a dialog and the full-screen ring', (tester) async {
      final (c, f) = await _home(tester);
      final ctx = tester.element(find.byType(HomeScreen));
      unawaited(showDialog<void>(context: ctx, builder: (_) => const AlertDialog(title: Text('Something else'))));
      await tester.pump(const Duration(milliseconds: 300));
      f.handleEvent(assigned());
      await tester.pump(const Duration(seconds: 2));
      expect(open, findsNothing);
      Navigator.of(ctx).pop();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 600));
      expect(open, findsOneWidget, reason: 'popped once the dialog closed');
      await tester.pumpWidget(const SizedBox());

      // The ring: a new order waiting.
      final (c2, f2) = await _home(tester);
      final arrived = StoredOrder.fromJson(jsonDecode(arrivedPickupJson) as Map<String, dynamic>);
      f2.push(f2.state.withOrder(arrived));
      await tester.pump();
      expect(c2.read(alarmProvider).visible, isTrue);
      f2.handleEvent(assigned());
      await tester.pump(const Duration(seconds: 2));
      expect(open, findsNothing);
      // Accepted elsewhere: the ring stops, the fob pops.
      f2.push(f2.state.withOrder(arrived.copyWith(status: const OrderStatus(state: OrderState.accepted, batchId: 7))));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 600));
      expect(open, findsOneWidget);
      expect(c.read(fobPopProvider), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Settings: the switch saves auto_assign; an older Pi shows it coming', (tester) async {
      Future<FakeDeliveryFloor> card(FloorState floor) async {
        final f = FakeDeliveryFloor(floor);
        final c = await deliveryContainer(f);
        addTearDown(c.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: SingleChildScrollView(child: AutoAssignCard()))),
          ),
        );
        await tester.pump();
        return f;
      }

      final f = await card(deliveryFloor(floorExtra: {'auto_assign': true}));
      expect(find.text('Auto-assign deliveries'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auto-assign-switch')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(callsOf(f, 'settings').single.extra['auto_assign'], isFalse);
      expect(f.state.floor!.autoAssign, isFalse);
      expect(kAutoAssignInfo.body, contains('They tap SEND OUT themselves.'));
      await tester.pumpWidget(const SizedBox());

      await card(deliveryFloor());
      expect(find.byKey(const ValueKey('coming-auto-assign')), findsOneWidget);
      expect(find.byKey(const ValueKey('auto-assign-switch')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('customer waiting (paid, not ready)', () {
    /// A cash pickup cooking for [ago] min; [paid] = settled at the store
    /// (the customer is waiting), else not paid yet.
    StoredOrder pickup(String id, int k, {int ago = 8, bool paid = true, int readyIn = 10}) {
      final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
      final now = timeNow().toUtc();
      (m['order'] as Map)['id'] = id;
      (m['order'] as Map)['payments'] = [
        {'method': 'cash', 'amount_cents': 2755},
      ];
      if (paid) (m['status'] as Map)['paid'] = true;
      (m['status'] as Map)
        ..['state'] = 'accepted'
        ..['kitchen_number'] = k
        ..['accepted_at'] = now.subtract(Duration(minutes: ago)).toIso8601String()
        ..['estimated_ready_at'] = now.add(Duration(minutes: readyIn)).toIso8601String();
      return StoredOrder.fromJson(m);
    }

    Future<ProviderContainer> board(WidgetTester tester, List<StoredOrder> orders, {bool motion = true, bool wave = true}) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final base = deliveryFloor();
      var fs = base.withSnapshot(floor: base.floor!, current: orders, arrived: const [], drivers: base.drivers, at: timeNow());
      if (!wave) {
        fs = fs.copyWith(floor: fs.floor!.copyWith(settings: FloorSettings.fromJson({'features': {'paid_wave': false}})));
      }
      final c = await deliveryContainer(FakeDeliveryFloor(fs));
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            builder: (context, child) =>
                MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: !motion), child: child!),
            home: const Scaffold(body: KitchenPane()),
          ),
        ),
      );
      await tester.pump();
      return c;
    }

    Finder inCard(String id, Finder f) => find.descendant(of: find.byKey(ValueKey(id)), matching: f);
    Color barOf(WidgetTester tester, String id) =>
        tester.widget<Container>(inCard(id, find.byKey(const ValueKey('card-bar')))).color!;

    testWidgets('red lava bar from the first frame, halo, "CUSTOMER WAITING · N min"; hotter after 5 min; first in line', (tester) async {
      // Cash first by urgency (ready sooner), the paid ones after it.
      await board(tester, [pickup('cash', 1101, paid: false, readyIn: 1), pickup('fresh', 1102, ago: 2), pickup('long', 1103, ago: 8)]);
      expect(inCard('fresh', find.text('CUSTOMER WAITING · 2 min')), findsOneWidget);
      expect(inCard('long', find.text('CUSTOMER WAITING · 8 min')), findsOneWidget);
      expect(inCard('cash', find.byKey(const ValueKey('customer-waiting'))), findsNothing);
      expect(inCard('fresh', find.byKey(const ValueKey('waiting-lava'))), findsOneWidget);
      expect(inCard('fresh', find.byKey(const ValueKey('paid-wave'))), findsOneWidget, reason: 'the halo');
      expect(barOf(tester, 'fresh'), kWaitingRed);
      expect(barOf(tester, 'long'), kWaitingRedHot, reason: 'escalated past 5 min');
      // Visible at once: the lava loop already runs, not ramping in.
      expect(tester.binding.hasScheduledFrame, isTrue);
      // Waiting tickets lead the board.
      final x = {for (final id in ['cash', 'fresh', 'long']) id: tester.getTopLeft(find.byKey(ValueKey(id))).dx};
      expect(x['fresh']! < x['cash']! && x['long']! < x['cash']!, isTrue, reason: '$x');
      // Counts up.
      await tester.pump(const Duration(minutes: 1));
      expect(inCard('fresh', find.text('CUSTOMER WAITING · 3 min')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Motion off: solid red bar and a thick red outline, nothing moving', (tester) async {
      await board(tester, [pickup('p', 1102)], motion: false);
      expect(find.byKey(const ValueKey('waiting-lava')), findsNothing);
      expect(find.text('CUSTOMER WAITING · 8 min'), findsOneWidget);
      expect(barOf(tester, 'p'), kWaitingRedHot);
      final outline = tester
          .widgetList<Container>(inCard('p', find.byType(Container)))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.color == Colors.white);
      expect((outline.border! as Border).top.width, 4);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('1.8.3: a POS counter check is a plain COUNTER ticket — no lava, no waiting line', (tester) async {
      final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
      final now = timeNow().toUtc();
      (m['order'] as Map)['id'] = 'ctr';
      ((m['order'] as Map)['fulfillment'] as Map)['type'] = 'dine_in';
      (m['status'] as Map)
        ..['state'] = 'accepted'
        ..['paid'] = true
        ..['ext_source'] = 'softtouch'
        ..['display_number'] = 298
        ..['accepted_at'] = now.subtract(const Duration(minutes: 3)).toIso8601String()
        ..['estimated_ready_at'] = now.add(const Duration(minutes: 10)).toIso8601String();
      await board(tester, [pickup('paid', 1102), StoredOrder.fromJson(m)]);
      expect(inCard('ctr', find.text('COUNTER')), findsOneWidget);
      expect(inCard('ctr', find.text('DINE-IN')), findsNothing);
      expect(inCard('ctr', find.byKey(const ValueKey('customer-waiting'))), findsNothing);
      expect(inCard('ctr', find.byKey(const ValueKey('waiting-lava'))), findsNothing);
      expect(inCard('ctr', find.byKey(const ValueKey('paid-wave'))), findsNothing);
      // A pickup paid at the store still glows.
      expect(inCard('paid', find.byKey(const ValueKey('customer-waiting'))), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('switched off: the plain ticket; offstage: no frames', (tester) async {
      await board(tester, [pickup('p', 1102)], wave: false);
      expect(find.byKey(const ValueKey('customer-waiting')), findsNothing);
      expect(find.byKey(const ValueKey('paid-wave')), findsNothing);
      await tester.pumpWidget(const SizedBox());

      final c = await board(tester, [pickup('p', 1102)]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: const Scaffold(body: TickerMode(enabled: false, child: KitchenPane())),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'its one ticker is muted');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('back to Kitchen after 1 min', () {
    Future<void> idle(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 61));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('from Deliveries, Store settings and developer mode (which locks)', (tester) async {
      final (c, _) = await _home(tester);
      for (final d in [HomeDestination.deliveries, HomeDestination.settings]) {
        await _go(tester, c, d);
        expect(c.read(homeNavProvider), d);
        await idle(tester);
        expect(c.read(homeNavProvider), HomeDestination.kitchen, reason: '$d');
      }
      c.read(devGateProvider.notifier).unlock();
      await _go(tester, c, HomeDestination.connections);
      expect(c.read(homeNavProvider), HomeDestination.connections);
      await idle(tester);
      expect(c.read(homeNavProvider), HomeDestination.kitchen);
      expect(c.read(devGateProvider), isFalse, reason: 'developer mode locks again');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('closes dialogs and screens on top; a touch restarts the minute', (tester) async {
      final (c, _) = await _home(tester);
      await _go(tester, c, HomeDestination.history);
      final ctx = tester.element(find.byType(HomeScreen));
      unawaited(showDialog<void>(context: ctx, builder: (_) => const AlertDialog(title: Text('Left open'))));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 40));
      await tester.tapAt(const Offset(640, 760)); // a touch (outside: closes the dialog too)
      await tester.pump(const Duration(milliseconds: 300));
      unawaited(showDialog<void>(context: ctx, builder: (_) => const AlertDialog(title: Text('Left open'))));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 40));
      expect(c.read(homeNavProvider), HomeDestination.history, reason: 'the touch restarted it');
      expect(find.text('Left open'), findsOneWidget);
      await idle(tester);
      expect(find.text('Left open'), findsNothing);
      expect(c.read(homeNavProvider), HomeDestination.kitchen);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('waits while someone types, while a new order rings, and when switched off', (tester) async {
      final (c, f) = await _home(tester);
      await _go(tester, c, HomeDestination.drivers);
      final ctx = tester.element(find.byType(HomeScreen));
      unawaited(
        showDialog<void>(
          context: ctx,
          builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await idle(tester);
      expect(c.read(homeNavProvider), HomeDestination.drivers, reason: 'typing');
      Navigator.of(ctx).pop();
      await tester.pump(const Duration(milliseconds: 300));
      FocusManager.instance.primaryFocus?.unfocus();

      // Ringing.
      f.push(f.state.withOrder(StoredOrder.fromJson(jsonDecode(arrivedPickupJson) as Map<String, dynamic>)));
      await tester.pump();
      await idle(tester);
      expect(c.read(homeNavProvider), HomeDestination.drivers, reason: 'ringing');
      f.push(f.state.withSnapshot(floor: f.state.floor!, current: f.initial.orders.values.toList(), arrived: const [], drivers: f.state.drivers, at: timeNow()));
      await tester.pump();

      // Off.
      c.read(idleKitchenProvider.notifier).set(false);
      await idle(tester);
      await idle(tester);
      expect(c.read(homeNavProvider), HomeDestination.drivers, reason: 'switched off');
      c.read(idleKitchenProvider.notifier).set(true);
      await idle(tester);
      expect(c.read(homeNavProvider), HomeDestination.kitchen);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// The real "I'm back" call (FakeDeliveryFloor stubs it) over a fixed floor.
class _RealReturnFloor extends FloorController {
  @override
  FloorState build() => deliveryFloor();

  @override
  Future<void> refresh() async {}
}

/// The home screen over the delivery floor (a map file, the stub tiles).
Future<(ProviderContainer, FakeDeliveryFloor)> _home(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final f = FakeDeliveryFloor(deliveryFloor());
  final c = await deliveryContainer(f);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: darkTheme(),
        // The app's shell listener (above every route), as in app.dart.
        builder: (context, child) => DevActivityListener(child: child!),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return (c, f);
}

Future<void> _go(WidgetTester tester, ProviderContainer c, HomeDestination d) async {
  c.read(homeNavProvider.notifier).go(d);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}
