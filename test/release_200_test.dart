// 2.0.0 (Pi 2.4.0, owner 2026-10-31): READY hold = no callout and READY /
// ACCEPT at once; MARK DELIVERED → Unassigned; the Drivers tab (who
// delivered what, moves); History's address + search; a delivery past its
// time looks ready; CHANGED shows money; future-order switches; the receipt
// format.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/receipt_models.dart';
import 'package:mobile_agent/features/common/island.dart';
import 'package:mobile_agent/features/drivers/drivers_pane.dart';
import 'package:mobile_agent/features/history/history_pane.dart';
import 'package:mobile_agent/features/kitchen/ready_button.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _order(String json) => jsonDecode(json) as Map<String, dynamic>;

/// [onDeliveryJson] as an order of the open batch (7) in [state] with
/// [driver] (null = none), marked delivered with no driver when [unassigned].
StoredOrder _delivered(
  String id,
  int k, {
  String state = 'delivered',
  String? driver,
  bool unassigned = false,
  String street = '931 Taylor Avenue',
}) {
  final so = delivery(id, k, state: state, street: street);
  final names = {'d-ana': 'Ana', 'd-joe': 'Joe', 'd-sam': 'Sam', 'd-lee': 'Lee'};
  return so.copyWith(
    status: so.status.copyWith(
      driverId: driver,
      driverName: driver == null ? null : names[driver],
      markedDelivered: unassigned
          ? const MarkedDelivered(
              by: MarkedBy(kind: 'tablet', name: 'Counter'),
            )
          : null,
    ),
  );
}

void main() {
  group('api (Pi 2.4.0)', () {
    (AgentClient, List<http.Request>) pi(http.Response Function(http.Request) answer) {
      final seen = <http.Request>[];
      return (
        AgentClient(
          baseUrl: 'http://10.0.0.5:8080',
          deviceKey: 'qagt_k',
          client: MockClient((r) async {
            seen.add(r);
            return answer(r);
          }),
        ),
        seen,
      );
    }

    test('READY with callout false sends it; a tap sends no body', () async {
      final (c, seen) = pi((_) => _json(_order(onDeliveryJson)));
      await c.ready('o1', callout: false);
      expect(jsonDecode(seen.single.body), {'callout': false});
      await c.ready('o1');
      expect(seen.last.body, isEmpty);
    });

    test('MARK DELIVERED, back, reassign, pool order: paths and bodies; an older Pi → unsupported', () async {
      final (c, seen) = pi(
        (r) => r.url.path.endsWith('/reassign') || r.url.path.endsWith('/pool/order')
            ? _json(const [])
            : _json(_order(onDeliveryJson)),
      );
      await c.markDelivered('o1');
      await c.undeliver('o1');
      await c.reassign(['o1', 'o2'], driverId: 'd-joe');
      await c.reassign(['o1']);
      await c.setPoolOrder('d-joe', ['o2', 'o1']);
      expect(
        [for (final r in seen) '${r.method} ${r.url.path}'],
        [
          'POST /api/orders/o1/delivered',
          'POST /api/orders/o1/undeliver',
          'POST /api/deliveries/reassign',
          'POST /api/deliveries/reassign',
          'POST /api/drivers/d-joe/pool/order',
        ],
      );
      expect(jsonDecode(seen[2].body), {
        'order_ids': ['o1', 'o2'],
        'driver_id': 'd-joe',
      });
      expect(jsonDecode(seen[3].body)['driver_id'], '', reason: 'Unassigned');
      expect(jsonDecode(seen[4].body), {
        'order_ids': ['o2', 'o1'],
      });

      final (old, _) = pi((_) => http.Response('', 405));
      await expectLater(
        old.markDelivered('o1'),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', kUnassignedUnsupported)),
      );
      final (gone, _) = pi((_) => _json({'error': 'order not found', 'code': 'not_found'}, 404));
      await expectLater(
        gone.undeliver('o1'),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', 'not_found')),
      );
    });

    test('TEST PRINT of a future ticket sends its kind', () async {
      final (c, seen) = pi((_) => _json({'results': []}));
      await c.printSample(kind: 'future_kitchen');
      expect(jsonDecode(seen.single.body), {'kind': 'future_kitchen'});
    });
  });

  group('models', () {
    test('marked_delivered, early tickets, money change, future switches, receipt format', () {
      final m = _order(onDeliveryJson);
      (m['status'] as Map)
        ..['state'] = 'delivered'
        ..remove('driver_id')
        ..['marked_delivered'] = {
          'at': '2026-10-31T22:41:00Z',
          'by': {'kind': 'tablet', 'name': 'Counter'},
          'prev_state': 'ready',
          'from_driver': 'Abdul',
          'available': ['Mike'],
        }
        ..['early_kitchen'] = true;
      final so = StoredOrder.fromJson(m);
      expect(so.isUnassigned, isTrue);
      final md = so.status.markedDelivered!;
      expect(md.by.label, 'Counter');
      expect(md.prevState, OrderState.ready);
      expect(md.fromDriver, 'Abdul');
      expect(md.available, ['Mike']);
      expect(so.status.earlyKitchen, isTrue);
      expect(so.status.earlyReceipt, isFalse);
      expect(const MarkedBy(kind: 'web').label, 'Pi web page');
      expect(const MarkedBy(kind: 'pos').label, 'the POS');

      final c = PosChange.fromJson({
        'id': 'c1',
        'added': [
          {'name': 'Chips', 'quantity': 1, 'kitchen': false, 'price_cents': 199},
        ],
        'money': {
          'from_total_cents': 3840,
          'to_total_cents': 4039,
          'from_paid': false,
          'to_paid': true,
          'from_cash_cents': 3840,
        },
      })!;
      expect(c.added.single.priceCents, 199);
      expect(c.money!.paymentChanged, isTrue);

      const t = TicketToggles(futureKitchen: true);
      expect(TicketToggles.fromJson(t.toJson()).futureKitchen, isTrue);
      expect(TicketToggles.fromJson(const {}).futureReceipt, isFalse);
      final p = ReceiptPrefs.fromJson({'format': 'condensed'});
      expect(p.format, ReceiptFormat.condensed);
      expect(p.toJson()['format'], 'condensed');
      expect(ReceiptPrefs.fromJson(const {}).format, ReceiptFormat.expanded);
    });

    test('a cooking delivery past its estimated time is "time up"', () {
      final now = DateTime.now();
      expect(delivery('a', 1, state: 'accepted', readyInMinutes: -1).timeUp(now), isTrue);
      expect(delivery('b', 2, state: 'accepted', readyInMinutes: 5).timeUp(now), isFalse);
      expect(delivery('c', 3).timeUp(now), isFalse, reason: 'ready already');
    });
  });

  group('READY / ACCEPT at once (the real floor controller)', () {
    late StreamController<List<int>> sse;
    late http.Response Function(http.Request) answer;
    late List<String> calls;

    Future<ProviderContainer> live() async {
      SharedPreferences.setMockInitialValues({'agent_address': 'http://h:1', 'device_key': 'qagt_k'});
      final prefs = await SharedPreferences.getInstance();
      sse = StreamController<List<int>>();
      calls = [];
      final cooking = _order(arrivedPickupJson);
      (cooking['order'] as Map)['id'] = 'cook-1';
      cooking['status'] = {'state': 'accepted', 'batch_id': 7, 'kitchen_number': 1101};
      final rest = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        return switch (req.url.path) {
          '/api/floor' => http.Response(floorJson, 200),
          '/api/orders' => _json([cooking]),
          '/api/orders/arrived' => _json([_order(arrivedPickupJson)]),
          '/api/drivers' => _json(const []),
          _ => answer(req),
        };
      });
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          agentClientProvider.overrideWith((ref) => AgentClient(baseUrl: 'h:1', deviceKey: 'qagt_k', client: rest)),
          sseClientFactoryProvider.overrideWithValue(
            () => MockClient.streaming((_, _) async => http.StreamedResponse(sse.stream, 200)),
          ),
          optimisticBackoffProvider.overrideWithValue((_) => const Duration(milliseconds: 1)),
        ],
      );
      addTearDown(c.dispose);
      addTearDown(sse.close);
      c.listen<FloorState>(floorProvider, (_, _) {}, fireImmediately: true);
      for (var i = 0; i < 50 && c.read(floorProvider).orders.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(c.read(floorProvider).orders, hasLength(2));
      return c;
    }

    test('READY: the ticket leaves Kitchen before the Pi answers; then the answer stays', () async {
      final done = Completer<http.Response>();
      final ready = _order(arrivedPickupJson);
      (ready['order'] as Map)['id'] = 'cook-1';
      ready['status'] = {'state': 'ready', 'batch_id': 7, 'kitchen_number': 1101};
      answer = (_) => _json(ready);
      final c = await live();
      final floor = c.read(floorProvider.notifier);
      final f = floor.ready('cook-1', callout: false);
      expect(c.read(floorProvider).orders['cook-1']!.state, OrderState.ready, reason: 'at once');
      expect(c.read(floorProvider).kitchenByUrgency, isEmpty);
      await f;
      expect(calls, contains('POST /api/orders/cook-1/ready'));
      expect(c.read(floorProvider).orders['cook-1']!.state, OrderState.ready);
      if (!done.isCompleted) done.complete(_json(null));
    });

    test('READY refused: the ticket comes back and the error is thrown', () async {
      answer = (_) => _json({'error': 'boom', 'code': 'internal'}, 500);
      final c = await live();
      final floor = c.read(floorProvider.notifier);
      final f = floor.ready('cook-1');
      expect(c.read(floorProvider).orders['cook-1']!.state, OrderState.ready);
      await expectLater(f, throwsA(isA<AgentException>()));
      expect(c.read(floorProvider).orders['cook-1']!.state, OrderState.accepted, reason: 'back on Kitchen');
    });

    test('READY: a network blip is retried quietly', () async {
      var n = 0;
      final ready = _order(arrivedPickupJson);
      (ready['order'] as Map)['id'] = 'cook-1';
      ready['status'] = {'state': 'ready', 'batch_id': 7, 'kitchen_number': 1101};
      answer = (r) {
        if (r.url.path.endsWith('/ready') && n++ == 0) throw const SocketException('down');
        return _json(ready);
      };
      final c = await live();
      await c.read(floorProvider.notifier).ready('cook-1');
      expect(calls.where((x) => x.endsWith('/ready')), hasLength(2));
      expect(c.read(floorProvider).orders['cook-1']!.state, OrderState.ready);
    });

    test('ACCEPT: off the ring at once with a guessed kitchen #; nothing printed → it rings again with why', () async {
      answer = (_) => _json({'error': 'nothing printed', 'code': 'print_failed'}, 502);
      final c = await live();
      const id = '01963a40-7c1e-7a51-9d2b-5d1f0c2a0001';
      final f = c.read(floorProvider.notifier).accept(id, 20);
      final now = c.read(floorProvider);
      expect(now.arrived, isEmpty, reason: 'the ring stops at once');
      expect(now.orders[id]!.status.kitchenNumber, 1105, reason: "the Pi's counter");
      await expectLater(f, throwsA(isA<AgentException>()));
      expect(c.read(floorProvider).arrived.single.id, id, reason: 'rings again');
      expect(c.read(acceptErrorsProvider)[id], contains('NOT accepted'));
    });
  });

  group('READY button', () {
    Future<List<bool>> pump(WidgetTester tester) async {
      final got = <bool>[];
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            theme: darkTheme(),
            home: Scaffold(
              body: Center(
                child: SizedBox(width: 240, child: ReadyButton(onReady: got.add)),
              ),
            ),
          ),
        ),
      );
      return got;
    }

    testWidgets('a tap = READY with the callout (on lift)', (tester) async {
      final got = await pump(tester);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('ready-button'))));
      await tester.pump(const Duration(milliseconds: 200));
      expect(got, isEmpty, reason: 'nothing while held');
      await g.up();
      await tester.pump();
      expect(got, [true]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('held 1 s = READY with no callout: the fill sweeps, NO CALLOUT, fires without lifting', (tester) async {
      final got = await pump(tester);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('ready-button'))));
      await tester.pump(const Duration(milliseconds: 150)); // the press registers (100 ms)
      await tester.pump(const Duration(milliseconds: 500));
      final fill = tester.widget<FractionallySizedBox>(find.byKey(const ValueKey('ready-hold-fill')));
      expect(fill.widthFactor, closeTo(0.5, 0.05));
      expect(find.text('READY'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(got, [false]);
      expect(find.text('NO CALLOUT'), findsOneWidget);
      await g.up();
      await tester.pump();
      expect(got, [false], reason: 'lifting after does nothing');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('History', () {
    test('address line and search', () {
      final a = _delivered('h1', 1201, street: '4108 Old Court Rd');
      final b = StoredOrder.fromJson(_order(arrivedPickupJson));
      expect(historyAddress(b), isNull, reason: 'a pickup');
      final addr = historyAddress(a)!;
      expect(addr, startsWith('4108 Old Court Rd'));
      expect(searchHistory([a, b], 'old court'), [a]);
      expect(searchHistory([a, b], 'erik'), [b]);
      expect(searchHistory([a, b], '443-207'), [b], reason: 'phone digits');
      expect(searchHistory([a, b], '1201'), [a], reason: 'ticket #');
      expect(searchHistory([a, b], '   '), [a, b]);
    });

    testWidgets('a delivery row shows its street + apt under the name', (tester) async {
      final so = _delivered('h1', 1201, street: '4108 Old Court Rd');
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(body: HistoryRow(order: so)),
        ),
      );
      expect(find.byKey(const ValueKey('history-address-h1')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Drivers tab', () {
    Future<(ProviderContainer, FakeDeliveryFloor)> pumpTab(WidgetTester tester, List<StoredOrder> extra) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final base = deliveryFloor();
      final f = FakeDeliveryFloor(base.withOrders(extra));
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: const IslandHost(child: Scaffold(body: DriversPane())),
          ),
        ),
      );
      await tester.pump();
      return (c, f);
    }

    testWidgets('opens on Unassigned (amber with a count); a driver button shows theirs', (tester) async {
      await pumpTab(tester, [_delivered('u1', 1201, unassigned: true), _delivered('a1', 1202, driver: 'd-ana')]);
      expect(find.byKey(const ValueKey('dd-u1')), findsOneWidget);
      expect(find.byKey(const ValueKey('dd-a1')), findsNothing);
      expect(
        find.descendant(of: find.byKey(const ValueKey('unassigned-button')), matching: find.text('1')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('driver-button-d-ana')));
      await tester.pump();
      expect(find.byKey(const ValueKey('dd-a1')), findsOneWidget);
      expect(find.byKey(const ValueKey('dd-u1')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tap selects, a driver button takes them (with UNDO); hold opens one', (tester) async {
      final (_, f) = await pumpTab(tester, [
        _delivered('u1', 1201, unassigned: true),
        _delivered('u2', 1202, unassigned: true),
      ]);
      await tester.tap(find.byKey(const ValueKey('dd-u1')));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('driver-select-all')));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('driver-button-d-joe')));
      await tester.pump();
      final mv = callsOf(f, 'reassign').single;
      expect(mv.ids.toSet(), {'u1', 'u2'});
      expect(mv.driver, 'd-joe');
      expect(find.text('2 moved to Joe'), findsOneWidget);
      expect(find.byKey(const ValueKey('dd-u1')), findsNothing, reason: "Joe's now");

      await tester.pump(const Duration(milliseconds: 600)); // the pill slides in
      await tester.tap(find.text('UNDO'));
      await tester.pump();
      expect(callsOf(f, 'reassign').last.driver, isNull, reason: 'back to Unassigned');

      await tester.longPress(find.byKey(const ValueKey('dd-u1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500)); // its map spins
      expect(find.byType(OrderDetailScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nothing moves to a clocked-out driver; an out one asks first; Unassigned takes delivered only', (
      tester,
    ) async {
      final (_, f) = await pumpTab(tester, [
        _delivered('a1', 1202, driver: 'd-ana'),
        _delivered('a2', 1203, state: 'on_delivery', driver: 'd-ana'),
      ]);
      await tester.tap(find.byKey(const ValueKey('driver-button-d-ana')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dd-a1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('off-button-d-lee')));
      await tester.pump();
      expect(find.textContaining('Clock Lee in first'), findsOneWidget);
      expect(callsOf(f, 'reassign'), isEmpty);
      await tester.pump(const Duration(seconds: 5));

      await tester.tap(find.byKey(const ValueKey('dd-a2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('unassigned-button')));
      await tester.pump();
      expect(find.textContaining('only delivered ones go to Unassigned'), findsOneWidget);
      expect(callsOf(f, 'reassign'), isEmpty);
      await tester.pump(const Duration(seconds: 5));

      await tester.tap(find.byKey(const ValueKey('driver-button-d-joe')));
      await tester.pump();
      expect(find.textContaining('is out with Ana — move it to Joe anyway?'), findsOneWidget);
      await tester.tap(find.text('MOVE'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(callsOf(f, 'reassign').single.ids.toSet(), {'a1', 'a2'});
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('order details', () {
    Future<FakeDeliveryFloor> pumpDetail(WidgetTester tester, StoredOrder so) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = FakeDeliveryFloor(deliveryFloor().withOrders([so]));
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: IslandHost(
              child: OrderDetailScreen(orderId: so.id, initial: so),
            ),
          ),
        ),
      );
      await tester.pump();
      return f;
    }

    testWidgets('MARK DELIVERED on an open delivery: no dialog, Unassigned with UNDO', (tester) async {
      final f = await pumpDetail(tester, delivery('m1', 1301, state: 'accepted', readyInMinutes: 10));
      await tester.ensureVisible(find.byKey(const ValueKey('mark-delivered')));
      await tester.tap(find.byKey(const ValueKey('mark-delivered')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(callsOf(f, 'delivered').single.ids, ['m1']);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('#1301 delivered · Unassigned'), findsOneWidget);
      expect(find.byKey(const ValueKey('unassigned-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('back-to-deliveries')), findsOneWidget);
      expect(find.byKey(const ValueKey('mark-delivered')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no MARK DELIVERED on a pickup or one already out', (tester) async {
      await pumpDetail(tester, StoredOrder.fromJson(_order(arrivedPickupJson)));
      expect(find.byKey(const ValueKey('mark-delivered')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await pumpDetail(tester, StoredOrder.fromJson(_order(onDeliveryJson)));
      expect(find.byKey(const ValueKey('mark-delivered')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
