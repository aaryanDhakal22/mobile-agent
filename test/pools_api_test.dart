import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/auto_preview.dart';
import 'package:mobile_agent/core/delivery_models.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/settings/deliveries_settings_card.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';

/// A client whose every request is answered by [respond]; [seen] records them.
(AgentClient, List<http.Request>) client(http.Response Function(http.Request) respond) {
  final seen = <http.Request>[];
  final c = AgentClient(
    baseUrl: 'pi:8080',
    deviceKey: 'k',
    client: MockClient((req) async {
      seen.add(req);
      return respond(req);
    }),
  );
  return (c, seen);
}

String orderList(List<String> ids, {String state = 'ready', String? pool}) {
  final list = [
    for (final id in ids)
      (jsonDecode(onDeliveryJson) as Map<String, dynamic>)
        ..['order'] = {...(jsonDecode(onDeliveryJson)['order'] as Map), 'id': id}
        ..['status'] = {'state': state, 'pool_driver_id': ?pool},
  ];
  return jsonEncode(list);
}

void main() {
  group('api client (2.0.9 pools / AUTO / maps)', () {
    test('poolOrders posts ids + driver (null = unassign)', () async {
      final (c, seen) = client((_) => http.Response(orderList(['a'], pool: 'd1'), 200));
      final out = await c.poolOrders(['a'], driverId: 'd1');
      expect(out.single.status.poolDriverId, 'd1');
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/api/deliveries/pool');
      expect(jsonDecode(seen.single.body), {
        'order_ids': ['a'],
        'driver_id': 'd1',
      });
      await c.poolOrders(['a']);
      expect(jsonDecode(seen.last.body), {
        'order_ids': ['a'],
        'driver_id': null,
      });
    });

    test('sendOut sends mark_ready, include_order_ids and plan_id', () async {
      final (c, seen) = client((_) => http.Response(orderList(['a', 'b'], state: 'on_delivery'), 200));
      final out = await c.sendOut('d 1', markReady: true, includeOrderIds: ['b'], planId: 'p1');
      expect(out, hasLength(2));
      expect(seen.single.url.path, '/api/drivers/d%201/send-out');
      expect(jsonDecode(seen.single.body), {
        'mark_ready': true,
        'include_order_ids': ['b'],
        'plan_id': 'p1',
      });
      await c.sendOut('d1');
      expect(jsonDecode(seen.last.body), {'mark_ready': false});
    });

    test('409 not_ready → NotReadyException with the ids', () async {
      final (c, _) = client(
        (_) => http.Response(
          jsonEncode({
            'error': 'not ready',
            'code': 'not_ready',
            'order_ids': ['a', 'b'],
          }),
          409,
        ),
      );
      await expectLater(
        c.sendOut('d1'),
        throwsA(isA<NotReadyException>().having((e) => e.orderIds, 'orderIds', ['a', 'b'])),
      );
    });

    test('other send-out conflicts keep their code', () async {
      final (c, _) = client(
        (_) => http.Response(jsonEncode({'error': 'x', 'code': 'driver_not_available'}), 409),
      );
      await expectLater(
        c.sendOut('d1'),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', 'driver_not_available')),
      );
    });

    test('autoPlan parses runs + leftovers; 409 → no_drivers', () async {
      final (c, seen) = client(
        (_) => http.Response(
          jsonEncode({
            'plan_id': 'p1',
            'created_at': '2026-10-22T17:00:00Z',
            'estimated': true,
            'fallback': false,
            'solve_ms': 12,
            'runs': [
              {
                'driver_id': 'd1',
                'order_ids': ['a', 'b'],
                'suggested_ids': ['b'],
                'depart_at': '2026-10-22T17:01:00Z',
                'return_at': '2026-10-22T17:20:00Z',
                'drive_s': 900,
                'stops': [
                  {'order_id': 'a', 'eta': '2026-10-22T17:06:00Z', 'placed_to_door_s': 2100, 'late': false},
                ],
              },
            ],
            'unassigned': [
              {'order_id': 'c', 'reason': 'no_location'},
            ],
          }),
          200,
        ),
      );
      final p = await c.autoPlan();
      expect(seen.single.url.path, '/api/deliveries/auto-plan');
      expect(p.planId, 'p1');
      expect(p.estimated, isTrue);
      expect(p.solveMs, 12);
      expect(p.runs.single.orderIds, ['a', 'b']);
      expect(p.runs.single.suggestedIds, ['b']);
      expect(p.runs.single.stops.single.placedToDoorS, 2100);
      expect(p.unassigned.single.reason, 'no_location');
      expect(p.suggestedCount, 1);

      final (c2, _) = client((_) => http.Response(jsonEncode({'error': 'no drivers', 'code': 'no_drivers'}), 409));
      await expectLater(c2.autoPlan(), throwsA(isA<AgentException>().having((e) => e.code, 'code', kNoDrivers)));
    });

    test('confirmPlan, poolTrip, pinOrder, setDeliverySettings', () async {
      final (c, seen) = client((req) {
        if (req.url.path.endsWith('/confirm')) {
          return http.Response(
            jsonEncode({
              'applied': ['a'],
              'skipped': [
                {'order_id': 'b', 'reason': 'sent'},
              ],
            }),
            200,
          );
        }
        if (req.url.path.endsWith('/pool/trip')) {
          return http.Response(
            jsonEncode({
              'order_ids': ['b', 'a'],
              'polyline': '_p~iF~ps|U',
              'distance_m': 5000,
              'duration_s': 900,
              'approximate': false,
            }),
            200,
          );
        }
        if (req.url.path.endsWith('/pin')) return http.Response('{}', 202);
        return http.Response(jsonEncode({'soon_ready_minutes': 7, 'delivery_target_minutes': 50}), 200);
      });
      final r = await c.confirmPlan('p1');
      expect(seen.last.url.path, '/api/deliveries/auto-plan/p1/confirm');
      expect(jsonDecode(seen.last.body), <String, Object?>{});
      await c.confirmPlan('p1', orderIds: ['a']);
      expect(jsonDecode(seen.last.body), {
        'order_ids': ['a'],
      });
      expect(r.applied, ['a']);
      expect(r.skipped.single.orderId, 'b');

      final t = await c.poolTrip('d1', ['a', 'b']);
      expect(seen.last.method, 'GET');
      expect(seen.last.url.queryParameters['order_ids'], 'a,b');
      expect(t.orderIds, ['b', 'a']);
      expect(t.distanceM, 5000);

      await c.pinOrder('a', 40.1, -74.2);
      expect(seen.last.url.path, '/api/orders/a/pin');
      expect(jsonDecode(seen.last.body), {'lat': 40.1, 'lng': -74.2});

      final s = await c.setDeliverySettings(const DeliverySettings(soonReadyMinutes: 7, deliveryTargetMinutes: 50));
      expect(seen.last.method, 'PUT');
      expect(seen.last.url.path, '/api/settings/deliveries');
      expect(jsonDecode(seen.last.body), {'soon_ready_minutes': 7, 'delivery_target_minutes': 50});
      expect(s.deliveryTargetMinutes, 50);
    });

    test('an older Pi without the routes → pools_unsupported; a JSON 404 is kept', () async {
      final (c, _) = client((_) => http.Response('404 page not found', 404));
      await expectLater(
        c.poolOrders(['a'], driverId: 'd1'),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', kPoolsUnsupported)),
      );
      final (c2, _) = client((_) => http.Response('', 405));
      await expectLater(c2.autoPlan(), throwsA(isA<AgentException>().having((e) => e.code, 'code', kPoolsUnsupported)));
      final (c3, _) = client((_) => http.Response(jsonEncode({'error': 'no such order', 'code': 'not_found'}), 404));
      await expectLater(
        c3.poolOrders(['a']),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', 'not_found')),
      );
    });
  });

  group('models', () {
    test('status pool fields, geo and floor additions parse', () {
      final o = delivery('a', 1, pool: 'd1', geo: locatedGeo(quality: 'approx', outside: true));
      expect(o.status.poolDriverId, 'd1');
      expect(o.status.pooledAt, isNotNull);
      expect(o.geo!.state, GeoState.located);
      expect(o.geo!.isApprox, isTrue);
      expect(o.geo!.outsideArea, isTrue);
      expect(o.geo!.distanceM, 3700);
      expect(o.geo!.route, hasLength(3));
      expect(o.geo!.point!.lat, closeTo(40.6801, 1e-9));
      expect(o.isPoolable, isTrue);
      expect(o.status.withPool(null).poolDriverId, isNull);
      expect(o.copyWith(status: o.status.withPool('d2')).geo, same(o.geo));

      final nf = OrderGeo.fromJson(const {'state': 'not_found'});
      expect(nf.hasPoint, isFalse);
      expect(nf.needsPin, isTrue);
      final un = OrderGeo.fromJson(const {'state': 'unavailable'});
      expect(un.state, GeoState.unavailable);
      expect(un.needsPin, isTrue);
      expect(OrderGeo.fromJson(const {'state': 'pending'}).needsPin, isFalse);
      expect(OrderGeo.fromJson(const {}).state, GeoState.pending);

      final f = deliveryFloor().floor!;
      expect(f.soonReadyMinutes, 5);
      expect(f.deliveryTargetMinutes, 45);
      expect(f.store!.deliveryRadiusM, 8047);
      expect(f.map!.url, '/api/map.pmtiles');
      expect(f.map!.bbox, hasLength(4));
      // An older Pi: defaults, no store, no map.
      final old = Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>);
      expect(old.deliveryTargetMinutes, 45);
      expect(old.store, isNull);
      expect(old.map, isNull);
      // copyWith keeps the new fields.
      final c = f.copyWith(deliveryTargetMinutes: 60);
      expect(c.deliveryTargetMinutes, 60);
      expect(c.map, f.map);
      expect(c.store, f.store);
    });

    test('pool_seq orders a pool (then kitchen #); same placed time → lower kitchen # first', () {
      final placed = DateTime.utc(2026, 10, 22, 17);
      StoredOrder at(StoredOrder o) => StoredOrder.fromJson({
        'order': {'id': o.id, 'placed_at': placed.toIso8601String(), 'fulfillment': {'type': 'delivery'}},
        'status': {
          'state': 'ready',
          'kitchen_number': o.status.kitchenNumber,
          'pool_driver_id': ?o.status.poolDriverId,
          'pool_seq': ?o.status.poolSeq,
        },
      });
      final s = deliveryFloor().withOrders([
        at(delivery('u2', 1302)),
        at(delivery('u1', 1301)),
        at(delivery('u3', 1303)),
        delivery('p1', 1401, pool: 'd-joe', poolSeq: 2),
        delivery('p2', 1400, pool: 'd-joe', poolSeq: 1),
        delivery('p3', 1399, pool: 'd-joe'),
      ]);
      final same = s.unassignedDeliveries.where((o) => o.id.startsWith('u')).map((o) => o.id);
      expect(same, ['u1', 'u2', 'u3']);
      // d4 (#1106) has no pool_seq: after the numbered stops, then by kitchen #.
      expect(s.poolFor('d-joe').map((o) => o.id), ['p2', 'p1', 'd4', 'p3']);
    });

    test('floor views: unassigned by placed time, pools per driver', () {
      final s = deliveryFloor();
      expect(s.unassignedDeliveries.map((o) => o.id), ['d1', 'd2', 'd5']);
      expect(s.poolFor('d-ana').map((o) => o.id), ['d3']);
      expect(s.poolFor('d-joe').map((o) => o.id), ['d4']);
      // A pool whose driver clocked out counts as unassigned.
      final joeOff = [
        for (final d in s.drivers) d.id == 'd-joe' ? Driver(id: d.id, name: d.name, status: DriverStatus.off) : d,
      ];
      expect(s.copyWith(drivers: joeOff).unassignedDeliveries.map((o) => o.id), contains('d4'));
    });
  });

  group('AUTO preview controller', () {
    Future<ProviderContainer> container() async {
      final c = await deliveryContainer(FakeDeliveryFloor(deliveryFloor()));
      addTearDown(c.dispose);
      return c;
    }

    final plan = AutoPlan.fromJson({
      'plan_id': 'p1',
      'runs': [
        {
          'driver_id': 'd-ana',
          'order_ids': ['d5', 'd3', 'd1'],
          'suggested_ids': ['d1', 'd5'],
        },
        {
          'driver_id': 'd-joe',
          'order_ids': ['d4'],
          'suggested_ids': <String>[],
        },
      ],
    });

    test('show keeps driving order; forget / takeRun / restoreRun', () async {
      final c = await container();
      final ctl = c.read(autoPreviewProvider.notifier);
      expect(ctl.show(plan), isTrue);
      expect(c.read(autoPreviewProvider)!.suggestedFor('d-ana'), ['d5', 'd1']);
      expect(c.read(autoPreviewProvider)!.suggestions.containsKey('d-joe'), isFalse);

      ctl.forget(['d5']);
      expect(c.read(autoPreviewProvider)!.suggestedFor('d-ana'), ['d1']);
      expect(c.read(autoPreviewProvider)!.edited, isTrue);

      final p = c.read(autoPreviewProvider)!;
      expect(ctl.takeRun('d-ana'), ['d1']);
      expect(c.read(autoPreviewProvider), isNull);
      ctl.restoreRun(p, 'd-ana', ['d1']);
      expect(c.read(autoPreviewProvider)!.suggestedFor('d-ana'), ['d1']);

      ctl.clear();
      expect(c.read(autoPreviewProvider), isNull);
      expect(ctl.show(AutoPlan.fromJson({'plan_id': 'p2', 'runs': <Object>[]})), isFalse);
    });

    test('drops itself when a suggested order is pooled elsewhere or its driver leaves', () async {
      final c = await container();
      c.read(autoPreviewProvider.notifier).show(plan);
      final fake = c.read(floorProvider.notifier) as FakeDeliveryFloor;
      final s = c.read(floorProvider);
      final d1 = s.orders['d1']!;
      fake.push(s.withOrder(d1.copyWith(status: d1.status.withPool('d-joe'))));
      expect(c.read(autoPreviewProvider), isNull);
      expect(c.read(autoPreviewDroppedProvider), 1);

      c.read(autoPreviewProvider.notifier).show(plan);
      final anaOut = [
        for (final d in s.drivers) d.id == 'd-ana' ? Driver(id: d.id, name: d.name, status: DriverStatus.out) : d,
      ];
      fake.push(c.read(floorProvider).copyWith(drivers: anaOut));
      expect(c.read(autoPreviewProvider), isNull);
    });
  });

  group('Settings → Deliveries', () {
    testWidgets('shows the Pi values, steps, saves', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = FakeDeliveryFloor(deliveryFloor());
      final c = await deliveryContainer(fake);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: ProviderContainer(
            parent: c,
            overrides: [agentClientProvider.overrideWithValue(AgentClient(baseUrl: 'pi', deviceKey: 'k'))],
          ),
          child: MaterialApp(
            theme: darkTheme(),
            home: const Scaffold(body: SingleChildScrollView(child: DeliveriesSettingsCard())),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('AUTO RUNS'), findsOneWidget);
      expect(find.text('45 min'), findsOneWidget);
      expect(find.text('5 min'), findsOneWidget);
      // SAVE is off until something changes.
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'SAVE')).onPressed, isNull);

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('delivery-target')), matching: find.byTooltip('More')));
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('soon-ready')), matching: find.byTooltip('Less')));
      await tester.pump();
      expect(find.text('50 min'), findsOneWidget);
      expect(find.text('4 min'), findsOneWidget);
      await tester.tap(find.text('SAVE'));
      await tester.pump();
      expect(callsOf(fake, 'settings').single.extra, {'soon_ready_minutes': 4, 'delivery_target_minutes': 50});
      expect(find.textContaining('Saved — target 50 min'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
