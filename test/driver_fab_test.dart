import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/auto_preview.dart';
import 'package:mobile_agent/core/delivery_models.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/features/drivers/driver_fab.dart';
import 'package:mobile_agent/features/drivers/next_rules.dart';
import 'package:mobile_agent/features/home/home_nav.dart';

import 'delivery_fixtures.dart';

/// [s] with [ids] moved into [driver]'s pool.
FloorState pooled(FloorState s, String driver, List<String> ids) => s.withOrders([
  for (final id in ids) s.orders[id]!.copyWith(status: s.orders[id]!.status.withPool(driver)),
]);

/// Ana is NEXT with #1103 (ready) in her box; only d1 waits unassigned (d2
/// and d5 sit in Joe's box) — NEXT sends her out.
FloorState sendable() => pooled(deliveryFloor(), 'd-joe', ['d2', 'd5']);

final card = find.byKey(const ValueKey('next-card'));
final action = find.byKey(const ValueKey('next-action'));

Future<(ProviderContainer, FakeDeliveryFloor)> pumpFab(WidgetTester tester, FloorState s) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final f = FakeDeliveryFloor(s);
  final c = await deliveryContainer(f);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(body: Stack(children: [Positioned.fill(child: DriverFab())])),
      ),
    ),
  );
  return (c, f);
}

/// The NEXT card's driver line ("Ana  2 orders").
String nextLine(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('next-driver'))).textSpan!.toPlainText();

Future<void> open(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.local_shipping_outlined));
  await tester.pumpAndSettle();
}

void main() {
  group('planNext', () {
    test('sends out when the pool has stops and at most one delivery waits', () {
      final p = planNext(sendable(), null);
      expect(p.go, NextGo.sendOut);
      expect(p.driver!.id, 'd-ana');
      expect(p.stops.map((s) => s.order.id), ['d3']);
      expect(p.unassigned, 1);
      expect(p.reason, isNull);
    });

    test('more than one unassigned → Deliveries', () {
      final p = planNext(deliveryFloor(), null);
      expect(p.go, NextGo.deliveries);
      expect(p.unassigned, 3);
      expect(p.reason, contains('3 deliveries are waiting'));
    });

    test('empty pool → Deliveries', () {
      final s = pooled(sendable(), 'd-joe', ['d3']); // Ana's box now empty
      final p = planNext(s, null);
      expect(p.go, NextGo.deliveries);
      expect(p.stops, isEmpty);
      expect(p.reason, contains("Ana's box is empty"));
    });

    test('no available driver → Drivers', () {
      final s = deliveryFloor();
      final off = [for (final d in s.drivers) Driver(id: d.id, name: d.name, status: DriverStatus.off)];
      final p = planNext(s.copyWith(drivers: off), null);
      expect(p.go, NextGo.drivers);
      expect(p.driver, isNull);
      expect(p.reason, 'No driver is clocked in. Clock one in first.');
    });

    test("AUTO's yellow stops for the next driver ride along and don't count as waiting", () {
      final s = pooled(deliveryFloor(), 'd-joe', ['d5']); // waiting: d1, d2
      final preview = AutoPreview.fromPlan(
        AutoPlan.fromJson({
          'plan_id': 'p',
          'runs': [
            {
              'driver_id': 'd-ana',
              'order_ids': ['d1', 'd3'],
              'suggested_ids': ['d1'],
            },
          ],
        }),
      );
      final p = planNext(s, preview);
      expect(p.go, NextGo.sendOut, reason: 'only d2 stays behind');
      expect([for (final x in p.stops) (x.order.id, x.suggested)], [('d3', false), ('d1', true)]);
    });

    test('nearbyCheck is a no-redirect hook until the Pi has next-check (1.7.0)', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final r = await nearbyCheck(c, const Driver(id: 'd-ana', name: 'Ana'), const []);
      expect(r.redirect, isFalse);
    });
  });

  testWidgets('badge = drivers out; the card shows NEXT, his tickets and SEND OUT', (tester) async {
    await pumpFab(tester, sendable());
    expect(find.text('1 out'), findsOneWidget, reason: 'Sam is out');
    expect(card, findsNothing);

    await open(tester);
    expect(find.descendant(of: card, matching: find.text('Next driver')), findsOneWidget);
    expect(find.byKey(const ValueKey('next-driver')), findsOneWidget);
    expect(nextLine(tester), 'Ana  1 order');
    expect(find.text('#1103'), findsOneWidget);
    expect(find.text('7 Kennedy Blvd'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.descendant(of: action, matching: find.text('SEND OUT')), findsOneWidget);
    expect(find.byKey(const ValueKey('next-reason')), findsNothing);
    // Below the card: the pill of the driver who is out.
    expect(find.text('Sam'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Sam')).dy, greaterThan(tester.getBottomLeft(card).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('SEND OUT with everything ready goes straight out and collapses', (tester) async {
    final (c, f) = await pumpFab(tester, sendable());
    await open(tester);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final s = callsOf(f, 'sendOut').single;
    expect(s.driver, 'd-ana');
    expect(s.extra['markReady'], isFalse);
    expect(card, findsNothing, reason: 'collapsed after the send');
    expect(c.read(homeNavProvider), HomeDestination.kitchen, reason: 'no redirect');
    expect(find.textContaining('out with Ana'), findsOneWidget);
  });

  testWidgets('SEND OUT with a cooking ticket asks "send anyway?" first', (tester) async {
    final (_, f) = await pumpFab(tester, pooled(sendable(), 'd-ana', ['d4']));
    await open(tester);
    expect(find.text('Cooking'), findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text("#1106 isn't marked ready — send anyway?"), findsOneWidget);
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(callsOf(f, 'sendOut'), isEmpty);
    expect(card, findsOneWidget, reason: 'still open after cancel');

    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEND ANYWAY'));
    await tester.pumpAndSettle();
    expect(callsOf(f, 'sendOut').single.extra['markReady'], isTrue);
    expect(card, findsNothing);
  });

  testWidgets('more than one unassigned: the button opens Deliveries', (tester) async {
    final (c, f) = await pumpFab(tester, deliveryFloor());
    await open(tester);
    expect(find.byKey(const ValueKey('next-reason')), findsOneWidget);
    expect(find.textContaining('3 deliveries are waiting'), findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(c.read(homeNavProvider), HomeDestination.deliveries);
    expect(callsOf(f, 'sendOut'), isEmpty);
    expect(card, findsNothing, reason: 'collapsed after the redirect');
  });

  testWidgets("empty pool: the button opens Deliveries", (tester) async {
    final (c, f) = await pumpFab(tester, pooled(sendable(), 'd-joe', ['d3']));
    await open(tester);
    expect(find.textContaining("Ana's box is empty"), findsOneWidget);
    expect(find.text('OPEN DELIVERIES'), findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(c.read(homeNavProvider), HomeDestination.deliveries);
    expect(callsOf(f, 'sendOut'), isEmpty);
  });

  testWidgets('no available driver: the button opens Drivers', (tester) async {
    final s = deliveryFloor();
    final drivers = [
      for (final d in s.drivers)
        d.isOut ? d : Driver(id: d.id, name: d.name, status: DriverStatus.off),
    ];
    final (c, _) = await pumpFab(tester, s.copyWith(drivers: drivers));
    await open(tester);
    expect(find.text('Nobody free'), findsOneWidget);
    expect(find.textContaining('Every driver is out'), findsOneWidget);
    await tester.tap(find.text('OPEN DRIVERS'));
    await tester.pumpAndSettle();
    expect(c.read(homeNavProvider), HomeDestination.drivers);
    expect(card, findsNothing);
  });

  testWidgets('a full box (five tickets) fits at 960×600', (tester) async {
    final s = pooled(deliveryFloor(), 'd-ana', ['d1', 'd2', 'd4', 'd5']);
    final (_, _) = await pumpFab(tester, s);
    tester.view.physicalSize = const Size(960, 600);
    await tester.pump();
    await open(tester);
    expect(tester.takeException(), isNull);
    expect(nextLine(tester), 'Ana  5 orders');
    expect(find.byKey(const ValueKey('next-action')).hitTestable(), findsOneWidget);
  });
}
