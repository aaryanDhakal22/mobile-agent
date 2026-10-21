import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/printer_models.dart';

import 'fixtures.dart';

StoredOrder parse(String raw) => StoredOrder.fromJson(jsonDecode(raw) as Map<String, dynamic>);

void main() {
  group('StoredOrder — arrived pickup', () {
    final so = parse(arrivedPickupJson);

    test('status', () {
      expect(so.state, OrderState.arrived);
      expect(so.status.arrivalDate, DateTime.utc(2026, 5, 12, 17, 42));
      expect(so.status.batchId, 7);
      expect(so.status.kitchenNumber, isNull);
      expect(so.status.printedDate, isNull);
      expect(so.status.driverId, isNull);
      expect(so.isFinished, isFalse);
      expect(so.isDelivery, isFalse);
      // No kitchen number yet → vendor id.
      expect(so.displayNumber, '#61124111');
    });

    test('snapshot', () {
      final o = so.order;
      expect(o.id, '01963a40-7c1e-7a51-9d2b-5d1f0c2a0001');
      expect(o.customerName, 'Erik Davis');
      expect(o.customer.phone, '4432077156');
      expect(o.fulfillment.type, FulfillmentType.pickup);
      expect(o.fulfillment.address, isNull);
      expect(o.money.totalCents, 2755);
      expect(o.money.discounts.single.code, 'SUMMER10');
      expect(o.money.fees, isEmpty);
      expect(o.isPrepaid, isTrue);
      expect(o.payments.single.last4, '0303');
      expect(o.storeName, "Lombardi's Pizza");
      expect(o.itemCount, 3);
    });

    test('items with size, modifiers, notes, routing', () {
      final pizza = so.order.items[0];
      expect(pizza.name, 'Regular Tomato Cheese Pizza');
      expect(pizza.size, '12 Medium');
      expect(pizza.notes, 'well done');
      expect(pizza.routing, 'matched');
      expect(pizza.printerId, '0196a-printer-1');
      expect(pizza.children.single.name, 'Add Pineapple');
      expect(pizza.children.single.lineTotalCents, 150);
      final knots = so.order.items[1];
      expect(knots.quantity, 2);
      expect(knots.size, '');
      expect(knots.children, isEmpty);
    });
  });

  group('StoredOrder — on_delivery with driver', () {
    final so = parse(onDeliveryJson);

    test('floor fields', () {
      final st = so.status;
      expect(so.state, OrderState.onDelivery);
      expect(st.kitchenNumber, 1104);
      expect(st.prepMinutes, 20);
      expect(st.estimatedReadyAt, DateTime.utc(2026, 5, 12, 17, 31, 1));
      expect(st.acceptedAt, isNotNull);
      expect(st.readyAt, DateTime.utc(2026, 5, 12, 17, 29));
      expect(st.outAt, DateTime.utc(2026, 5, 12, 17, 33));
      expect(st.deliveredAt, isNull);
      expect(st.driverId, 'd-sam');
      expect(st.driverName, 'Sam');
      expect(so.displayNumber, '1104');
      expect(so.isDelivery, isTrue);
      expect(so.isFinished, isFalse);
    });

    test('address + fees', () {
      final a = so.order.fulfillment.address!;
      expect(a.lines, ['931 Taylor Avenue, Apt 4', 'Towson, MD 21286']);
      expect(a.notes, 'Ring twice');
      expect(so.order.money.fees.single.amountCents, 400);
      expect(so.order.kitchenOrderNumber, 1104);
      expect(so.order.items.single.size, 'Large');
    });
  });

  group('StoredOrder — legacy order missing floor fields', () {
    final so = parse(legacyJson);

    test('parses with neutral defaults', () {
      expect(so.state, OrderState.accepted);
      expect(so.status.batchId, 0);
      expect(so.status.kitchenNumber, isNull);
      expect(so.status.prepMinutes, isNull);
      expect(so.status.estimatedReadyAt, isNull);
      expect(so.order.customerName, 'Guest');
      expect(so.order.fulfillment.type, FulfillmentType.unknown);
      expect(so.order.money.subtotalCents, 0);
      expect(so.order.payments, isEmpty);
      expect(so.order.items.single.size, '');
      expect(so.order.items.single.routing, '');
      expect(so.displayNumber, '#61124001');
    });

    test("Go's zero time is treated as absent", () {
      expect(so.order.placedAt, isNull);
      expect(so.order.receivedAt, DateTime.utc(2026, 4, 1, 12));
    });
  });

  test('garbage / nulls never throw', () {
    final so = StoredOrder.fromJson({
      'order': null,
      'status': {'state': 'bogus', 'kitchen_number': 'x'},
    });
    expect(so.id, '');
    expect(so.state, OrderState.unknown);
    expect(so.status.kitchenNumber, isNull);
    expect(so.order.items, isEmpty);

    final weird = StoredOrder.fromJson({
      'order': {
        'items': [
          null,
          5,
          {'name': 'X', 'quantity': 2.0, 'children': 'nope'},
        ],
        'money': {'total_cents': 1234.0},
        'fulfillment': {'type': 'dine_in', 'address': null, 'table_id': 'T4'},
      },
      'status': {'state': 'ready', 'arrival_date': 'not a date'},
    });
    expect(weird.order.items.single.quantity, 2);
    expect(weird.order.items.single.children, isEmpty);
    expect(weird.order.money.totalCents, 1234);
    expect(weird.order.fulfillment.type, FulfillmentType.dineIn);
    expect(weird.order.fulfillment.tableId, 'T4');
    expect(weird.status.arrivalDate, isNull);
    // Ready dine-in is finished.
    expect(weird.isFinished, isTrue);
  });

  test('order.arrived / order.escalated payloads parse as StoredOrder', () {
    final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
    m['_traceparent'] = '00-abc-def-01';
    m['waiting_seconds'] = 240;
    final so = StoredOrder.fromJson(m);
    expect(so.state, OrderState.arrived);
    expect(so.order.customerName, 'Erik Davis');
  });

  test('Floor', () {
    final f = Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>);
    expect(f.batch.id, 7);
    expect(f.batch.isOpen, isTrue);
    expect(f.batch.orderCount, 12);
    expect(f.kitchenNext, 1105);
    expect(f.lastPrepMinutes, 20);
    expect(f.prepChoices, [10, 15, 20, 30, 45, 60]);
    expect(f.unsyncedEvents, 3);
    expect(f.defaultPrep, 20);
    expect(f.driverResetTime, '10:00');
    expect(f.copyWith(batch: const Batch(id: 8)).driverResetTime, '10:00');

    final bare = Floor.fromJson({
      'batch': {'id': 1},
      'last_prep_minutes': 25,
    });
    expect(bare.prepChoices, kDefaultPrepChoices);
    expect(bare.driverResetTime, isNull, reason: 'older agents send no reset time');
    expect(Floor.fromJson({'driver_reset_time': '  '}).driverResetTime, isNull);
    expect(Floor.fromJson({'driver_reset_time': 7}).driverResetTime, '7');
    // 25 isn't a pick → nearest pick preselected.
    expect([20, 30], contains(bare.defaultPrep));
  });

  test('Drivers in queue order, with clock-in', () {
    final ds = (jsonDecode(driversJson) as List).cast<Map<String, dynamic>>().map(Driver.fromJson).toList();
    expect(ds.map((d) => d.name), ['Ana', 'Lee', 'Sam', 'Joe']);
    expect(ds[0].isAvailable, isTrue);
    expect(ds[0].isOnShift, isTrue);
    expect(ds[0].clockedInAt, DateTime.utc(2026, 5, 12, 15, 58));
    expect(ds[0].lastReturnedAt, DateTime.utc(2026, 5, 12, 17, 20));
    expect(ds[0].deliveries, 2);
    expect(ds[1].status, DriverStatus.off);
    expect(ds[1].isOff, isTrue);
    expect(ds[1].isAvailable, isFalse);
    expect(ds[1].isOnShift, isFalse);
    expect(ds[1].clockedInAt, isNull);
    expect(ds[2].status, DriverStatus.out);
    expect(ds[2].isOut, isTrue);
    expect(ds[2].clockedInAt, DateTime.utc(2026, 5, 12, 16, 5));
    expect(ds[2].lastReturnedAt, isNull);
  });

  test('Drivers from an older agent (no clock-in) stay available / out', () {
    final ds = (jsonDecode(legacyDriversJson) as List).cast<Map<String, dynamic>>().map(Driver.fromJson).toList();
    expect(ds.map((d) => d.status), [DriverStatus.available, DriverStatus.out, DriverStatus.available]);
    expect(ds.every((d) => d.clockedInAt == null), isTrue);
    expect(ds[2].deliveries, 0);
    // Unknown status strings and junk timestamps don't throw.
    final odd = Driver.fromJson({'id': 'x', 'status': 'on_break', 'clocked_in_at': 'yesterday'});
    expect(odd.status, DriverStatus.available);
    expect(odd.clockedInAt, isNull);
    expect(Driver.fromJson({'status': 'off', 'clocked_in_at': '0001-01-01T00:00:00Z'}).clockedInAt, isNull);
  });

  test('Shift records', () {
    final ss = (jsonDecode(shiftsJson) as List).cast<Map<String, dynamic>>().map(Shift.fromJson).toList();
    expect(ss.map((s) => s.id), ['s-3', 's-2', 's-1']);
    final open = ss[0];
    expect(open.driverName, 'Joe');
    expect(open.driverId, 'd-joe');
    expect(open.batchId, 7);
    expect(open.clockIn, DateTime.utc(2026, 5, 12, 16, 30));
    expect(open.isOpen, isTrue);
    expect(open.length(DateTime.utc(2026, 5, 12, 18, 0)), const Duration(minutes: 90));
    expect(ss[1].isOpen, isFalse);
    expect(ss[1].autoOut, isFalse);
    expect(ss[1].length(DateTime.now()), const Duration(hours: 4, minutes: 30));
    expect(ss[2].autoOut, isTrue, reason: 'closed by the daily reset');

    final bare = Shift.fromJson({'auto_out': 'nope', 'clock_in': null});
    expect(bare.clockIn, isNull);
    expect(bare.length(DateTime.now()), isNull);
    expect(bare.autoOut, isFalse);
  });

  test('drivers.dispatched payload', () {
    final d = DriverDispatch.fromJson({
      'driver': (jsonDecode(driversJson) as List)[2],
      'orders': [jsonDecode(onDeliveryJson)],
    });
    expect(d.driver.name, 'Sam');
    expect(d.driver.isOut, isTrue);
    expect(d.orders.single.state, OrderState.onDelivery);
    expect(d.numbers, ['1104']);
    expect(d.key, 'd-sam|${d.orders.single.id}');
    // Missing pieces parse to an empty dispatch rather than throwing.
    final empty = DriverDispatch.fromJson({'orders': 'nope'});
    expect(empty.driver.id, '');
    expect(empty.orders, isEmpty);
  });

  test('Batch + close result', () {
    final r = CloseBatchResult.fromJson({
      'closed': {'id': 7, 'opened_at': '2026-05-12T10:00:00Z', 'closed_at': '2026-05-12T23:00:00Z', 'order_count': 40},
      'auto_finished': [jsonDecode(onDeliveryJson)],
    });
    expect(r.closed.id, 7);
    expect(r.closed.isOpen, isFalse);
    expect(r.autoFinished.single.status.driverName, 'Sam');
  });

  test('PrinterStatus', () {
    final p = PrinterStatus.fromJson({
      'name': 'Kitchen',
      'ip': '192.168.1.100',
      'up': false,
      'last_checked': '2026-05-12T17:00:00Z',
      'last_error': 'dial tcp: i/o timeout',
      'down_since': '2026-05-12T16:59:00Z',
    });
    expect(p.up, isFalse);
    expect(p.hasIP, isTrue);
    expect(p.upSince, isNull);
    expect(p.downSince, isNotNull);
  });

  test('cancelled orders (closed out with the batch) parse and count as finished', () {
    final so = StoredOrder.fromJson({
      'order': {'id': 'c1', 'fulfillment': {'type': 'pickup'}, 'items': []},
      'status': {'state': 'cancelled', 'cancelled_at': '2026-10-15T22:54:37.554Z'},
    });
    expect(so.state, OrderState.cancelled);
    expect(so.isFinished, isTrue);
    expect(so.status.cancelledAt, isNotNull);
  });

  group('cash due / prepaid (same rule as the agent receipt)', () {
    OrderSnapshot order(List<Map<String, dynamic>>? payments) => OrderSnapshot.fromJson({
      'id': 'p1',
      'money': {'total_cents': 3000},
      'payments': ?payments,
    });

    test('no payments at all (older order) → cash for the whole total', () {
      final o = order(null);
      expect(o.cashDueCents, 3000);
      expect(o.isPrepaid, isFalse);
      expect(order(const []).cashDueCents, 3000);
    });

    test('explicit cash payment → that amount, case-insensitive', () {
      final o = order([
        {'method': 'CASH', 'amount_cents': 3000},
      ]);
      expect(o.cashDueCents, 3000);
      expect(o.isPrepaid, isFalse);
    });

    test('card only → prepaid', () {
      final o = order([
        {'method': 'card', 'amount_cents': 3000, 'last4': '1111'},
      ]);
      expect(o.cashDueCents, 0);
      expect(o.isPrepaid, isTrue);
    });

    test('card + cash part-paid → cash is the cash part', () {
      final o = order([
        {'method': 'card', 'amount_cents': 1000},
        {'method': 'cash', 'amount_cents': 2000},
      ]);
      expect(o.cashDueCents, 2000);
      expect(o.isPrepaid, isFalse);
    });

    test('"other" only (third party / invoice) → prepaid, not cash', () {
      final o = order([
        {'method': 'other', 'amount_cents': 3000},
      ]);
      expect(o.cashDueCents, 0);
      expect(o.isPrepaid, isTrue);
    });
  });
}
