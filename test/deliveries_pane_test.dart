import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/auto_preview.dart';
import 'package:mobile_agent/core/delivery_models.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/deliveries/deliveries_pane.dart';
import 'package:mobile_agent/features/home/home_screen.dart';
import 'package:mobile_agent/features/maps/pool_map_screen.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';

import 'delivery_fixtures.dart';

Future<(ProviderContainer, FakeDeliveryFloor)> pumpPane(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  FakeDeliveryFloor? fake,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final f = fake ?? FakeDeliveryFloor(deliveryFloor());
  final c = await deliveryContainer(f);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: DeliveriesPane())),
    ),
  );
  await tester.pump();
  return (c, f);
}

/// Long-press [from], drag it onto [to], drop.
Future<void> longDrag(WidgetTester tester, Finder from, Finder to) async {
  final g = await tester.startGesture(tester.getCenter(from));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  final target = tester.getCenter(to);
  await g.moveTo(target - const Offset(0, 20));
  await tester.pump();
  await g.moveTo(target);
  await tester.pump();
  await g.up();
  await tester.pump();
}

/// Lets dialogs / routes animate without waiting for spinners to stop.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Finder box(String driverId) => find.byKey(ValueKey('driver-$driverId'));
final leftColumn = find.byKey(const ValueKey('unassigned-column'));

AutoPlan samplePlan({bool estimated = true}) => AutoPlan.fromJson({
  'plan_id': 'plan-1',
  'estimated': estimated,
  'runs': [
    {
      'driver_id': 'd-ana',
      'order_ids': ['d3', 'd1'],
      'suggested_ids': ['d1'],
    },
    {
      'driver_id': 'd-joe',
      'order_ids': ['d4', 'd5'],
      'suggested_ids': ['d5'],
    },
  ],
  'unassigned': [
    {'order_id': 'd2', 'reason': 'not_ready_soon'},
  ],
});

void main() {
  for (final size in const [Size(1280, 800), Size(960, 600)]) {
    testWidgets('two columns render without overflow at $size (in the home screen)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await deliveryContainer(FakeDeliveryFloor(deliveryFloor()));
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const HomeScreen()),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Deliveries').last);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 2)); // tickers
      expect(tester.takeException(), isNull);

      expect(find.text('Unassigned · 3'), findsOneWidget);
      expect(find.text('NEXT'), findsOneWidget);
      expect(box('d-ana'), findsOneWidget);
      expect(box('d-joe'), findsOneWidget);
      expect(box('d-lee'), findsNothing, reason: 'clocked out');
      expect(box('d-sam'), findsNothing, reason: 'out on a run');
      expect(find.text('OUT · 1'), findsOneWidget);
      expect(find.text('I HAVE RETURNED'), findsOneWidget);
      // Row details: mi · min, tags, hints, cooking.
      expect(find.text('2.3 mi · 7 min'), findsWidgets);
      expect(find.text('approx'), findsOneWidget);
      expect(find.text('outside area'), findsOneWidget);
      expect(find.text('no location'), findsWidgets);
      expect(find.textContaining('ready in ~'), findsOneWidget);
      expect(find.text('SEND OUT'), findsNWidgets(2));


      // AUTO preview at this size too.
      (c.read(floorProvider.notifier) as FakeDeliveryFloor).plan = samplePlan();
      await tester.tap(find.byKey(const ValueKey('auto')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text('CONFIRM'), findsOneWidget);

      // Scrolled to the end, the last Out card's I HAVE RETURNED sits clear
      // of the driver button (104 px + ring, 24 px from the bottom-right).
      final right = find.ancestor(of: box('d-ana'), matching: find.byType(Scrollable)).first;
      await tester.drag(right, const Offset(0, -3000));
      await tester.pump(const Duration(seconds: 1));
      final returned = tester.getRect(find.widgetWithText(FilledButton, 'I HAVE RETURNED'));
      expect(returned.bottom, lessThanOrEqualTo(size.height - 146), reason: 'clear of the driver button');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a single tap on a row, a pooled chip and an out chip opens the order', (tester) async {
    await pumpPane(tester);
    await tester.tap(find.byKey(const ValueKey('row-d1')));
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen), findsOneWidget);
    expect(find.text('1101'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chip-d3')));
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ActionChip, '1104'));
    await settle(tester); // its map says Locating… (a spinner never settles)
    expect(find.byType(OrderDetailScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('select mode: tap rows, tap a driver box → moved; tap the left column → back', (tester) async {
    final (_, f) = await pumpPane(tester);
    await tester.tap(find.byKey(const ValueKey('select')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('row-d1')));
    await tester.tap(find.byKey(const ValueKey('row-d5')));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byType(OrderDetailScreen), findsNothing, reason: 'select mode: a tap selects');

    await tester.tap(find.byKey(const ValueKey('driver-header-d-joe')));
    await tester.pump();
    final pool = callsOf(f, 'pool').single;
    expect(pool.ids.toSet(), {'d1', 'd5'});
    expect(pool.driver, 'd-joe');
    expect(find.byKey(const ValueKey('chip-d1')), findsOneWidget);
    expect(find.text('Unassigned · 1'), findsOneWidget);

    // Select a pooled chip and tap the left column: unassigned.
    await tester.tap(find.byKey(const ValueKey('select')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chip-d1')));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Unassigned · 1'));
    await tester.pump();
    final back = callsOf(f, 'pool').last;
    expect(back.ids, ['d1']);
    expect(back.driver, isNull);
    expect(find.byKey(const ValueKey('row-d1')), findsOneWidget);

    // Cancel leaves select mode.
    await tester.tap(find.byKey(const ValueKey('select')));
    await tester.pump();
    await tester.tap(find.text('CANCEL'));
    await tester.pump();
    expect(find.byKey(const ValueKey('select-bar')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('drag: left → driver, driver → driver, driver → left', (tester) async {
    final (_, f) = await pumpPane(tester);

    await longDrag(tester, find.byKey(const ValueKey('row-d1')), box('d-joe'));
    expect(callsOf(f, 'pool').last.ids, ['d1']);
    expect(callsOf(f, 'pool').last.driver, 'd-joe');
    expect(find.byKey(const ValueKey('chip-d1')), findsOneWidget);

    await longDrag(tester, find.byKey(const ValueKey('chip-d3')), box('d-joe'));
    expect(callsOf(f, 'pool').last.ids, ['d3']);
    expect(callsOf(f, 'pool').last.driver, 'd-joe');

    await longDrag(tester, find.byKey(const ValueKey('chip-d3')), leftColumn);
    expect(callsOf(f, 'pool').last.ids, ['d3']);
    expect(callsOf(f, 'pool').last.driver, isNull);
    expect(find.byKey(const ValueKey('row-d3')), findsOneWidget);

    // Dropping on the box it came from does nothing.
    final n = f.calls.length;
    await longDrag(tester, find.byKey(const ValueKey('chip-d1')), box('d-joe'));
    expect(f.calls.length, n);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('✕ on a pooled chip puts it back on the left', (tester) async {
    final (_, f) = await pumpPane(tester);
    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('chip-d3')), matching: find.byTooltip('Back to unassigned')),
    );
    await tester.pump();
    expect(callsOf(f, 'pool').single.ids, ['d3']);
    expect(callsOf(f, 'pool').single.driver, isNull);
    expect(find.byKey(const ValueKey('row-d3')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Send Out with a cooking order asks first, then sends with markReady', (tester) async {
    final (_, f) = await pumpPane(tester);
    await tester.tap(find.byKey(const ValueKey('send-d-joe')));
    await tester.pumpAndSettle();
    expect(find.text("#1106 isn't marked ready — send anyway?"), findsOneWidget);

    // CANCEL sends nothing.
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(callsOf(f, 'sendOut'), isEmpty);

    await tester.tap(find.byKey(const ValueKey('send-d-joe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEND ANYWAY'));
    await tester.pumpAndSettle();
    final s = callsOf(f, 'sendOut').single;
    expect(s.driver, 'd-joe');
    expect(s.extra['markReady'], isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Send Out with everything ready goes straight out (no dialog)', (tester) async {
    final (_, f) = await pumpPane(tester);
    await tester.tap(find.byKey(const ValueKey('send-d-ana')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(callsOf(f, 'sendOut').single.extra['markReady'], isFalse);
    expect(find.textContaining('out with Ana'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('409 not_ready from the Pi: asks, then retries with markReady', (tester) async {
    final fake = FakeDeliveryFloor(deliveryFloor())
      ..sendOutError = NotReadyException('not ready', orderIds: const ['d3']);
    final (_, f) = await pumpPane(tester, fake: fake);
    await tester.tap(find.byKey(const ValueKey('send-d-ana')));
    await settle(tester); // the SEND OUT spinner runs under the dialog
    expect(find.text("#1103 isn't marked ready — send anyway?"), findsOneWidget);
    await tester.tap(find.text('SEND ANYWAY'));
    await settle(tester);
    final sends = callsOf(f, 'sendOut');
    expect(sends, hasLength(2));
    expect(sends[0].extra['markReady'], isFalse);
    expect(sends[1].extra['markReady'], isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Send Out errors in plain words (driver gone)', (tester) async {
    final fake = FakeDeliveryFloor(deliveryFloor())
      ..sendOutError = const AgentException('x', statusCode: 409, code: 'driver_not_available');
    await pumpPane(tester, fake: fake);
    await tester.tap(find.byKey(const ValueKey('send-d-ana')));
    await tester.pumpAndSettle();
    expect(find.textContaining("Ana isn't available"), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Out section: I HAVE RETURNED', (tester) async {
    final (_, f) = await pumpPane(tester);
    await tester.tap(find.text('I HAVE RETURNED'));
    await tester.pump();
    expect(callsOf(f, 'returned').single.driver, 'd-sam');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no driver clocked in → hint to clock in on the Drivers tab', (tester) async {
    final s = deliveryFloor();
    final off = s.drivers.map((d) => Driver(id: d.id, name: d.name, status: DriverStatus.off)).toList();
    await pumpPane(tester, fake: FakeDeliveryFloor(s.copyWith(drivers: off)));
    expect(find.text('No driver clocked in — clock one in on the Drivers tab.'), findsOneWidget);
    expect(find.text('SEND OUT'), findsNothing);
    expect(find.text('Unassigned · 5'), findsOneWidget, reason: 'pools of unavailable drivers show as unassigned');
    await tester.pumpWidget(const SizedBox());
  });

  group('AUTO preview', () {
    Future<(ProviderContainer, FakeDeliveryFloor)> withPreview(WidgetTester tester) async {
      final fake = FakeDeliveryFloor(deliveryFloor())..plan = samplePlan();
      final r = await pumpPane(tester, fake: fake);
      await tester.tap(find.byKey(const ValueKey('auto')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // slide-in
      return r;
    }

    testWidgets('suggestions slide into the boxes with a yellow glow; the bar says estimated', (tester) async {
      await withPreview(tester);
      expect(find.byKey(const ValueKey('auto-preview-bar')), findsOneWidget);
      expect(find.text('estimated (offline)'), findsOneWidget);
      expect(find.text('1 stay unassigned'), findsOneWidget);
      // d1 left the left column for Ana's box, d5 for Joe's.
      expect(find.byKey(const ValueKey('row-d1')), findsNothing);
      expect(find.byKey(const ValueKey('row-d5')), findsNothing);
      expect(find.descendant(of: box('d-ana'), matching: find.byKey(const ValueKey('yellow-d1'))), findsOneWidget);
      expect(find.descendant(of: box('d-joe'), matching: find.byKey(const ValueKey('yellow-d5'))), findsOneWidget);
      // The glow: amber 2 px border + shadow.
      final deco = tester
          .widgetList<Container>(
            find.descendant(of: find.byKey(const ValueKey('yellow-d1')), matching: find.byType(Container)),
          )
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.boxShadow != null);
      expect((deco.border as Border).top.color, QuiccColors.statusFiring);
      expect((deco.border as Border).top.width, 2);
      expect(deco.boxShadow!.single.color.toARGB32() & 0x00FFFFFF, QuiccColors.statusFiring.toARGB32() & 0x00FFFFFF);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("a box lists pooled + yellow stops in the plan's driving order", (tester) async {
      final fake = FakeDeliveryFloor(deliveryFloor())
        ..plan = AutoPlan.fromJson({
          'plan_id': 'plan-2',
          'runs': [
            {
              'driver_id': 'd-ana',
              'order_ids': ['d1', 'd3'],
              'suggested_ids': ['d1'],
            },
          ],
        });
      await pumpPane(tester, fake: fake);
      expect(find.byKey(const ValueKey('chip-d3')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auto')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final yellowY = tester.getTopLeft(find.byKey(const ValueKey('yellow-d1'))).dy;
      final pooledY = tester.getTopLeft(find.byKey(const ValueKey('chip-d3'))).dy;
      expect(yellowY, lessThan(pooledY), reason: 'd1 is the first stop of the run');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('CONFIRM applies the plan', (tester) async {
      final (c, f) = await withPreview(tester);
      f.confirmResult = const PlanConfirmResult(applied: ['d1'], skipped: [PlanLeftover(orderId: 'd5', reason: 'sent')]);
      await tester.tap(find.text('CONFIRM'));
      await tester.pump();
      expect(callsOf(f, 'confirm').single.extra['planId'], 'plan-1');
      expect(callsOf(f, 'confirm').single.extra['filtered'], isFalse, reason: 'unedited: the whole plan');
      expect(c.read(autoPreviewProvider), isNull);
      expect(find.text('Applied 1 · skipped #1105 (changed meanwhile)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an edited preview confirms only the suggestions still showing', (tester) async {
      final (_, f) = await withPreview(tester);
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('yellow-d5')), matching: find.byTooltip('Drop this suggestion')),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('row-d5')), findsOneWidget, reason: 'back on the left');
      await tester.tap(find.text('CONFIRM'));
      await tester.pump();
      final confirm = callsOf(f, 'confirm').single;
      expect(confirm.extra['planId'], 'plan-1');
      expect(confirm.ids, ['d1']);
      expect(callsOf(f, 'pool'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('CLEAR drops it', (tester) async {
      final (c, f) = await withPreview(tester);
      await tester.tap(find.text('CLEAR'));
      await tester.pump();
      expect(c.read(autoPreviewProvider), isNull);
      expect(find.byKey(const ValueKey('row-d1')), findsOneWidget);
      expect(callsOf(f, 'confirm'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Send Out on a driver with yellow stops sends them too (with the plan id)', (tester) async {
      final (c, f) = await withPreview(tester);
      await tester.tap(find.byKey(const ValueKey('send-d-ana')));
      await tester.pumpAndSettle();
      final s = callsOf(f, 'sendOut').single;
      expect(s.driver, 'd-ana');
      expect(s.ids, ['d1']);
      expect(s.extra['planId'], 'plan-1');
      // Joe's suggestion stays up.
      expect(c.read(autoPreviewProvider)!.suggestedFor('d-joe'), ['d5']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping a driver name shows the pool map with the yellow stops', (tester) async {
      final (_, f) = await withPreview(tester);
      f.trip = const PoolTrip(orderIds: ['d1', 'd3'], approximate: true);
      await tester.tap(find.byKey(const ValueKey('driver-header-d-ana')));
      await tester.pumpAndSettle();
      expect(find.byType(PoolMapScreen), findsOneWidget);
      expect(callsOf(f, 'trip').single.ids.toSet(), {'d3', 'd1'});
      expect(find.text("Ana's run · 2 stops"), findsOneWidget);
      expect(find.textContaining('approximate'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('dropped with a toast when the floor changes under it', (tester) async {
      final (c, f) = await withPreview(tester);
      // d1 was sent out from another tablet.
      final d1 = c.read(floorProvider).orders['d1']!;
      final sent = StoredOrder(
        order: d1.order,
        status: const OrderStatus(state: OrderState.onDelivery, driverId: 'd-sam', driverName: 'Sam'),
        geo: d1.geo,
      );
      f.push(c.read(floorProvider).withOrder(sent));
      await tester.pump();
      expect(c.read(autoPreviewProvider), isNull);
      expect(find.text('The floor changed — AUTO suggestion cleared. Tap AUTO again.'), findsOneWidget);
      expect(find.byKey(const ValueKey('auto-preview-bar')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no free driver → plain toast', (tester) async {
      final fake = FakeDeliveryFloor(deliveryFloor())
        ..autoPlanError = const AgentException('x', statusCode: 409, code: kNoDrivers);
      await pumpPane(tester, fake: fake);
      await tester.tap(find.byKey(const ValueKey('auto')));
      await tester.pump();
      expect(find.text('No driver is free — clock one in on the Drivers tab.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('dragging a yellow stop to the left drops just that suggestion', (tester) async {
      final (c, f) = await withPreview(tester);
      await longDrag(tester, find.byKey(const ValueKey('yellow-d5')), leftColumn);
      expect(c.read(autoPreviewProvider)!.suggestedIds, {'d1'});
      expect(callsOf(f, 'pool'), isEmpty, reason: 'it was never pooled');
      expect(find.byKey(const ValueKey('row-d5')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
