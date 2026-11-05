// 2.0.4: Kitchen's All · Delivery · Pickup buttons (counts, kept across
// restarts, a blink for new tickets the filter hides) and the gear's
// Condensed tickets + Ticket number order.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/kitchen/kitchen_pane.dart';
import 'package:mobile_agent/features/kitchen/kitchen_view.dart';
import 'package:mobile_agent/theme/quicc_theme.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';

/// An online pickup cooking: kitchen #[k], arrived [ago] minutes ago.
StoredOrder pickup(String id, int k, {int ago = 5, String name = 'Erik Davis'}) {
  final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  final now = clock.now().toUtc();
  (m['order'] as Map)['id'] = id;
  ((m['order'] as Map)['customer'] as Map)['display_name'] = name;
  (m['status'] as Map)
    ..['state'] = 'accepted'
    ..['kitchen_number'] = k
    ..['arrival_date'] = now.subtract(Duration(minutes: ago)).toIso8601String()
    ..['accepted_at'] = now.subtract(Duration(minutes: ago)).toIso8601String()
    ..['estimated_ready_at'] = now.add(Duration(minutes: 30 - ago)).toIso8601String();
  return StoredOrder.fromJson(m);
}

/// A POS counter order (dine-in) sent [ago] minutes ago as check #[check].
StoredOrder counter(String id, int check, {int ago = 3}) {
  final now = clock.now().toUtc();
  return StoredOrder.fromJson({
    'order': {
      'id': id,
      'source': 'pos',
      'customer': {'display_name': 'Counter'},
      'fulfillment': {'type': 'dine_in'},
      'items': [
        {'id': 'c1', 'name': 'Cheese Steak', 'quantity': 1},
      ],
      'placed_at': now.subtract(Duration(minutes: ago)).toIso8601String(),
    },
    'status': {
      'state': 'accepted',
      'display_number': check,
      'ext_source': 'softtouch',
      'ext_ref': '$check',
      'sent_at': now.subtract(Duration(minutes: ago)).toIso8601String(),
      'accepted_at': now.subtract(Duration(minutes: ago)).toIso8601String(),
      'estimated_ready_at': now.add(const Duration(minutes: 20)).toIso8601String(),
    },
  });
}

/// A delivery cooking that arrived [ago] minutes ago.
StoredOrder cookingDelivery(String id, int k, {int ago = 10, int readyIn = 20, String street = '12 Main St'}) {
  final m = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
  final now = clock.now().toUtc();
  (m['order'] as Map)
    ..['id'] = id
    ..['placed_at'] = now.subtract(Duration(minutes: ago)).toIso8601String()
    ..['kitchen_order_number'] = k;
  (((m['order'] as Map)['fulfillment'] as Map)['address'] as Map)['line1'] = street;
  m['status'] = {
    'state': 'accepted',
    'kitchen_number': k,
    'batch_id': 7,
    'arrival_date': now.subtract(Duration(minutes: ago)).toIso8601String(),
    'accepted_at': now.subtract(Duration(minutes: ago)).toIso8601String(),
    'estimated_ready_at': now.add(Duration(minutes: readyIn)).toIso8601String(),
  };
  return StoredOrder.fromJson(m);
}

FloorState board(List<StoredOrder> orders) {
  final base = deliveryFloor();
  return base.withSnapshot(
    floor: base.floor!,
    current: orders,
    arrived: const [],
    drivers: base.drivers,
    at: clock.now(),
  );
}

Future<(ProviderContainer, FakeDeliveryFloor)> pumpKitchen(
  WidgetTester tester,
  List<StoredOrder> orders, {
  Map<String, Object> prefs = const {},
}) async {
  tester.view.physicalSize = const Size(1280 - 104, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final f = FakeDeliveryFloor(board(orders));
  final c = await deliveryContainer(f, prefs: prefs);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: QuiccTheme.dark(),
        home: const Scaffold(body: KitchenPane()),
      ),
    ),
  );
  await tester.pump();
  return (c, f);
}

Future<void> done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

String countOf(WidgetTester tester, KitchenFilter f) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('kitchen-filter-${f.name}')),
        matching: find.byKey(const ValueKey('filter-count')),
      ),
    )
    .data!;

Future<void> tapFilter(WidgetTester tester, KitchenFilter f) async {
  await tester.tap(find.byKey(ValueKey('kitchen-filter-${f.name}')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

List<String> shownIds(WidgetTester tester) => [
  for (final e in find.byType(KitchenCard).evaluate()) (e.widget as KitchenCard).order.id,
];

void main() {
  final mix = [
    cookingDelivery('d1', 1101, ago: 12, street: '12 Main St'),
    cookingDelivery('d2', 1102, ago: 6, street: '40 Elm St'),
    pickup('p1', 1103, ago: 4),
    counter('c1', 250, ago: 9),
  ];

  testWidgets('All · Delivery · Pickup: counts, and each button shows its kind (counter orders are pickups)', (
    tester,
  ) async {
    final (c, _) = await pumpKitchen(tester, mix);
    expect(countOf(tester, KitchenFilter.all), '4');
    expect(countOf(tester, KitchenFilter.delivery), '2');
    expect(countOf(tester, KitchenFilter.pickup), '2');
    expect(shownIds(tester).toSet(), {'d1', 'd2', 'p1', 'c1'});

    await tapFilter(tester, KitchenFilter.delivery);
    expect(shownIds(tester).toSet(), {'d1', 'd2'});
    expect(c.read(sharedPrefsProvider).getString(KitchenViewNotifier.kFilter), 'delivery');

    await tapFilter(tester, KitchenFilter.pickup);
    expect(shownIds(tester).toSet(), {'p1', 'c1'});

    await tapFilter(tester, KitchenFilter.all);
    expect(shownIds(tester), hasLength(4));
    await done(tester);
  });

  testWidgets('the chosen filter and view are kept across a restart', (tester) async {
    await pumpKitchen(
      tester,
      mix,
      prefs: const {'kitchen_filter': 'pickup', 'kitchen_condensed': true, 'kitchen_sort': 'received'},
    );
    expect(shownIds(tester).toSet(), {'p1', 'c1'});
    expect(find.text('+ Add Pineapple'), findsNothing, reason: 'condensed');
    expect(find.textContaining('by ticket number'), findsOneWidget);
    await done(tester);
  });

  testWidgets('a filter with nothing in it says so', (tester) async {
    await pumpKitchen(tester, [pickup('p1', 1103)], prefs: const {'kitchen_filter': 'delivery'});
    expect(find.byType(KitchenCard), findsNothing);
    expect(find.text('No deliveries cooking'), findsOneWidget);
    await done(tester);
  });

  testWidgets('a new ticket the filter hides makes its button (and All) blink until chosen', (tester) async {
    final (_, f) = await pumpKitchen(tester, mix, prefs: const {'kitchen_filter': 'delivery'});
    expect(find.byKey(const ValueKey('filter-blink')), findsNothing, reason: 'the first board is not new');

    // A new delivery is shown: nothing blinks.
    f.push(board([...mix, cookingDelivery('d3', 1104, ago: 0)]));
    await tester.pump();
    expect(find.byKey(const ValueKey('filter-blink')), findsNothing);

    // A new pickup is hidden: Pickup and All blink.
    f.push(board([...mix, cookingDelivery('d3', 1104, ago: 0), pickup('p2', 1105, ago: 0)]));
    await tester.pump();
    final blinking = find.byKey(const ValueKey('filter-blink'));
    expect(blinking, findsNWidgets(2));
    expect(
      find.descendant(of: find.byKey(const ValueKey('kitchen-filter-pickup')), matching: blinking),
      findsOneWidget,
    );
    expect(find.descendant(of: find.byKey(const ValueKey('kitchen-filter-all')), matching: blinking), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.takeException(), isNull);

    await tapFilter(tester, KitchenFilter.pickup);
    expect(find.byKey(const ValueKey('filter-blink')), findsNothing);
    expect(shownIds(tester), contains('p2'));

    // Back on Delivery the seen pickup doesn't blink again.
    await tapFilter(tester, KitchenFilter.delivery);
    expect(find.byKey(const ValueKey('filter-blink')), findsNothing);

    // A hidden ticket that leaves the board (READY) stops the blink.
    f.push(
      board([...mix, cookingDelivery('d3', 1104, ago: 0), pickup('p2', 1105, ago: 0), pickup('p3', 1106, ago: 0)]),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('filter-blink')), findsNWidgets(2));
    f.push(board([...mix, cookingDelivery('d3', 1104, ago: 0), pickup('p2', 1105, ago: 0)]));
    await tester.pump();
    expect(find.byKey(const ValueKey('filter-blink')), findsNothing);
    await done(tester);
  });

  testWidgets('gear: Condensed hides modifiers and notes; Ticket number orders by when received', (tester) async {
    final orders = [
      pickup('p1', 1103, ago: 4),
      cookingDelivery('d1', 1101, ago: 12, readyIn: 40),
      counter('c1', 250, ago: 9),
    ];
    final (c, _) = await pumpKitchen(tester, orders);
    expect(find.text('+ Add Pineapple'), findsOneWidget);
    expect(find.text('“well done”'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('kitchen-gear')));
    await tester.pumpAndSettle();
    expect(find.byType(KitchenViewSheet), findsOneWidget);
    await tester.tap(find.text('Condensed'));
    await tester.pump();
    expect(c.read(kitchenViewProvider).condensed, isTrue);
    await tester.tap(find.text('Ticket number'));
    await tester.pump();
    expect(c.read(kitchenViewProvider).sort, KitchenSort.received);
    expect(c.read(sharedPrefsProvider).getString(KitchenViewNotifier.kSort), 'received');
    Navigator.of(tester.element(find.byType(KitchenViewSheet))).pop();
    await tester.pumpAndSettle();

    expect(find.text('+ Add Pineapple'), findsNothing);
    expect(find.text('“well done”'), findsNothing);
    expect(find.textContaining('Regular Tomato Cheese Pizza'), findsWidgets, reason: 'item names stay');
    // Oldest first, online and POS together: d1 (12 min), c1 (9), p1 (4).
    final cards = find.byType(KitchenCard);
    final byLeft = [
      for (var i = 0; i < cards.evaluate().length; i++)
        (tester.getTopLeft(cards.at(i)).dx, (cards.at(i).evaluate().single.widget as KitchenCard).order.id),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    expect([for (final e in byLeft) e.$2], ['d1', 'c1', 'p1']);
    await done(tester);
  });

  test('byReceived: oldest first, a ticket with no time last, ties keep their order', () {
    final now = DateTime.utc(2026, 11, 5, 18);
    withClock(Clock.fixed(now), () {
      final a = pickup('a', 1, ago: 2), b = counter('b', 2, ago: 7), c = cookingDelivery('c', 3, ago: 5);
      expect(byReceived([a, b, c]).map((o) => o.id), ['b', 'c', 'a']);
      final noTime = StoredOrder.fromJson(const {
        'order': {'id': 'n'},
        'status': {'state': 'accepted'},
      });
      expect(byReceived([noTime, a]).map((o) => o.id), ['a', 'n']);
      final a2 = pickup('a2', 4, ago: 2);
      expect(byReceived([a2, a]).map((o) => o.id), ['a2', 'a']);
    });
  });

  test('kitchenShows: Pickup is everything that is not a delivery', () {
    expect(kitchenShows(KitchenFilter.pickup, counter('c', 1)), isTrue);
    expect(kitchenShows(KitchenFilter.delivery, counter('c', 1)), isFalse);
    expect(kitchenShows(KitchenFilter.all, counter('c', 1)), isTrue);
  });
}
