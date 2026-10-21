import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/sse.dart';

import 'fixtures.dart';

StoredOrder order(String id, String state, {String type = 'pickup', int? kitchen, String? arrival, String? driver}) =>
    StoredOrder.fromJson({
      'order': {
        'id': id,
        'fulfillment': {'type': type},
      },
      'status': {
        'state': state,
        'batch_id': 7,
        'arrival_date': ?arrival,
        'kitchen_number': ?kitchen,
        'driver_id': ?driver,
      },
    });

void main() {
  final floor = Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>);
  final drivers = (jsonDecode(driversJson) as List).cast<Map<String, dynamic>>().map(Driver.fromJson).toList();

  test('views split the working set by state', () {
    final s = const FloorState().withSnapshot(
      floor: floor,
      current: [
        order('k2', 'accepted', kitchen: 1102),
        order('k1', 'accepted', kitchen: 1101),
        order('rd', 'ready', type: 'delivery'),
        order('rp', 'ready', type: 'pickup'),
        order('out', 'on_delivery', type: 'delivery', driver: 'd-sam'),
        order('done', 'delivered', type: 'delivery'),
      ],
      arrived: [
        order('a2', 'arrived', arrival: '2026-05-12T17:45:00Z'),
        order('a1', 'arrived', arrival: '2026-05-12T17:40:00Z'),
      ],
      drivers: drivers,
      at: DateTime(2026),
    );
    expect(s.loaded, isTrue);
    expect(s.arrived.map((o) => o.id), ['a1', 'a2'], reason: 'oldest first');
    expect(s.kitchen.map((o) => o.id), ['k1', 'k2'], reason: 'kitchen-number order');
    expect(s.readyDeliveries.map((o) => o.id), ['rd'], reason: 'pickups never need a driver');
    expect(s.outWith('d-sam').map((o) => o.id), ['out']);
    expect(s.nextDriver!.id, 'd-ana');
    expect(s.driversOut.map((d) => d.id), ['d-sam'], reason: 'off (Lee) is not out');
    expect(s.availableDrivers.map((d) => d.id), ['d-ana', 'd-joe']);
    expect(s.currentBatchOrders, hasLength(8));
  });

  test('withOrder clears an escalation once accepted', () {
    var s = const FloorState().withOrder(order('a', 'arrived'));
    s = s.copyWith(waitingSeconds: {'a': 120});
    s = s.withOrder(order('a', 'accepted', kitchen: 1100));
    expect(s.waitingSeconds, isEmpty);
    expect(s.arrived, isEmpty);
  });

  group('deliveries driver filter', () {
    Driver drv(String id, String status) => Driver.fromJson({'id': id, 'name': id, 'status': status});

    test('only clocked-in, not-out drivers, in queue order; first is the default', () {
      final s = const FloorState().copyWith(
        drivers: [drv('a', 'off'), drv('b', 'available'), drv('c', 'out'), drv('d', 'off'), drv('e', 'available')],
      );
      expect(s.availableDrivers.map((d) => d.id), ['b', 'e']);
      expect(s.nextDriver!.id, 'b');
      expect(s.anyDriverOnShift, isTrue);
    });

    test('everyone clocked out → nobody to pick', () {
      final s = const FloorState().copyWith(drivers: [drv('a', 'off'), drv('b', 'off')]);
      expect(s.availableDrivers, isEmpty);
      expect(s.nextDriver, isNull);
      expect(s.anyDriverOnShift, isFalse, reason: '"No driver clocked in" message');
    });

    test('clocked in but all out → nobody to pick, someone on shift', () {
      final s = const FloorState().copyWith(drivers: [drv('a', 'out'), drv('b', 'off')]);
      expect(s.availableDrivers, isEmpty);
      expect(s.anyDriverOnShift, isTrue);
    });
  });

  group('drivers.dispatched reducer', () {
    final base = const FloorState().withSnapshot(
      floor: floor,
      current: [order('rd', 'ready', type: 'delivery', kitchen: 1107)],
      arrived: const [],
      drivers: drivers,
      at: DateTime(2026),
    );
    Map<String, dynamic> sam(String status) => {
      ...(jsonDecode(driversJson) as List)[2] as Map<String, dynamic>,
      'status': status,
    };
    Map<String, dynamic> outOrder(String id, int kitchen) => {
      'order': {
        'id': id,
        'fulfillment': {'type': 'delivery'},
      },
      'status': {'state': 'on_delivery', 'batch_id': 7, 'kitchen_number': kitchen, 'driver_id': 'd-sam'},
    };
    SseEvent frame(Object payload) => SseEvent('drivers.dispatched', jsonEncode(payload));

    test('flashes once, upserts the run and the driver', () {
      final up = applySseEvent(
        base,
        frame({
          'driver': sam('out'),
          'orders': [outOrder('rd', 1107)],
        }),
      );
      expect(up.refetch, isFalse);
      final s = up.state;
      expect(s.dispatches, base.dispatches + 1);
      expect(s.dispatch!.driver.name, 'Sam');
      expect(s.dispatch!.numbers, ['1107']);
      expect(s.orders['rd']!.state, OrderState.onDelivery);
      expect(s.readyDeliveries, isEmpty);
      expect(s.outWith('d-sam').map((o) => o.id), ['rd']);
      expect(s.drivers.firstWhere((d) => d.id == 'd-sam').isOut, isTrue);
    });

    test('the same dispatch seen again (replay after a refetch) does not flash twice', () {
      final ev = frame({
        'driver': sam('out'),
        'orders': [outOrder('rd', 1107)],
      });
      var s = applySseEvent(base, ev).state;
      s = applySseEvent(s, ev).state;
      expect(s.dispatches, base.dispatches + 1);

      // A different run flashes again.
      s = applySseEvent(
        s,
        frame({
          'driver': sam('out'),
          'orders': [outOrder('rd2', 1108)],
        }),
      ).state;
      expect(s.dispatches, base.dispatches + 2);
      expect(s.dispatch!.numbers, ['1108']);
    });

    test("this tablet's own send-out flashes once; the SSE echo only refreshes the roster", () {
      final local = DriverDispatch(
        driver: base.drivers.firstWhere((d) => d.id == 'd-sam'),
        orders: [StoredOrder.fromJson(outOrder('rd', 1107))],
      );
      var s = base.withDispatch(local, updateRoster: false);
      expect(s.dispatches, base.dispatches + 1);
      s = applySseEvent(
        s,
        frame({
          'driver': {...sam('out'), 'deliveries': 2},
          'orders': [outOrder('rd', 1107)],
        }),
      ).state;
      expect(s.dispatches, base.dispatches + 1);
      expect(s.drivers.firstWhere((d) => d.id == 'd-sam').deliveries, 2);
    });

    test('malformed frames are ignored', () {
      for (final ev in [
        const SseEvent('drivers.dispatched', 'not json'),
        frame(const [1, 2]),
        frame({'orders': []}),
      ]) {
        final s = applySseEvent(base, ev).state;
        expect(s.dispatches, base.dispatches, reason: ev.data);
        expect(s.dispatch, isNull);
      }
    });

    test('dispatch state survives a refetch', () {
      final s = applySseEvent(
        base,
        frame({
          'driver': sam('out'),
          'orders': [outOrder('rd', 1107)],
        }),
      ).state;
      final again = s.withSnapshot(floor: floor, current: const [], arrived: const [], drivers: drivers, at: DateTime(2026));
      expect(again.dispatches, s.dispatches);
      expect(again.dispatch, same(s.dispatch));
    });
  });
}
