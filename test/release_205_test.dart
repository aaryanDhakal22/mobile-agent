// 2.0.5 (Pi 2.4.3): a waiting future order's MAKE NOW / CHANGE DUE TIME /
// PRINT NOW / CANCEL; Deliveries without the row jump, mass MARK DELIVERED,
// the details closing after MARK DELIVERED; no READY implosion on a Kitchen
// filter switch; Settings as a list; the store's colours.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/common/island.dart';
import 'package:mobile_agent/features/deliveries/deliveries_pane.dart';
import 'package:mobile_agent/features/kitchen/kitchen_view.dart';
import 'package:mobile_agent/features/kitchen/ticket_motion.dart';
import 'package:mobile_agent/features/order_detail/future_actions.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:mobile_agent/features/settings/store_settings_screen.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';
import 'release_204_test.dart' show board, cookingDelivery, pickup, pumpKitchen, tapFilter;

/// A scheduled future delivery due tomorrow at 8 PM with a [lead]-minute
/// lead (ring time from it).
StoredOrder futureDelivery(String id, {int lead = 45, String state = 'scheduled', bool card = true}) {
  final m = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
  final n = clock.now();
  final due = DateTime(n.year, n.month, n.day + 1, 20).toUtc();
  final o = m['order'] as Map;
  o['id'] = id;
  (o['fulfillment'] as Map)['promised_at'] = due.toIso8601String();
  o['payments'] = card
      ? [
          {'method': 'card', 'amount_cents': 2755, 'status': 'captured'},
        ]
      : <Object>[];
  m['status'] = {
    'state': state,
    'future': true,
    'batch_id': 7,
    'arrival_date': clock.now().toUtc().toIso8601String(),
    if (state == 'scheduled') 'scheduled_lead_minutes': lead,
    if (state == 'scheduled') 'ring_at': due.subtract(Duration(minutes: lead)).toIso8601String(),
  };
  return StoredOrder.fromJson(m);
}

/// The fake floor with the 2.4.3 actions recorded (and applied).
class FutureFloor extends FakeDeliveryFloor {
  FutureFloor(super.initial);

  bool unsupported = false;

  void _check() {
    if (unsupported) throw const AgentException('missing', statusCode: 405, code: kFutureActionsUnsupported);
  }

  @override
  Future<StoredOrder> makeNow(String id, int prepMinutes) async {
    _check();
    calls.add((op: 'makeNow', ids: [id], driver: null, extra: {'prep': prepMinutes}));
    final o = state.orders[id]!;
    final next = o.copyWith(status: o.status.copyWith(state: OrderState.accepted, kitchenNumber: 1150));
    state = state.withOrders([next]);
    return next;
  }

  @override
  Future<StoredOrder> changeDue(String id, DateTime due) async {
    _check();
    calls.add((op: 'due', ids: [id], driver: null, extra: {'due': due}));
    return state.orders[id]!;
  }

  @override
  Future<KitchenResend> printNow(String id, {required bool kitchen, required bool receipt}) async {
    _check();
    calls.add((op: 'printNow', ids: [id], driver: null, extra: {'kitchen': kitchen, 'receipt': receipt}));
    return KitchenResend(printed: [if (kitchen) 'Pizza', if (receipt) 'Front']);
  }

  @override
  Future<StoredOrder> cancelFuture(String id) async {
    _check();
    calls.add((op: 'cancel', ids: [id], driver: null, extra: const {}));
    final o = state.orders[id]!;
    final next = o.copyWith(status: o.status.copyWith(state: OrderState.cancelled));
    state = state.withOrders([next]);
    return next;
  }

  @override
  Future<StoreLook> saveLook({Color? accent, Color? delivery, Color? pickup, Color? counter}) async {
    _check();
    calls.add((
      op: 'look',
      ids: const [],
      driver: null,
      extra: {'accent': accent, 'delivery': delivery, 'pickup': pickup, 'counter': counter},
    ));
    final cur = state.settings.look ?? const StoreLook();
    final next = cur.copyWith(accent: accent, delivery: delivery, pickup: pickup, counter: counter);
    state = state.copyWith(floor: state.floor!.copyWith(settings: state.settings.copyWith(look: next)));
    return next;
  }
}

/// The detail page of [so], pushed over a plain home (so closing it shows).
Future<FutureFloor> pumpFutureDetail(WidgetTester tester, StoredOrder so, {bool unsupported = false}) async {
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final f = FutureFloor(deliveryFloor().withOrders([so]))..unsupported = unsupported;
  final c = await deliveryContainer(f);
  addTearDown(c.dispose);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        navigatorKey: nav,
        theme: darkTheme(),
        home: IslandHost(navigatorKey: nav, child: const Scaffold(body: Text('HOME'))),
      ),
    ),
  );
  nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => OrderDetailScreen(orderId: so.id, initial: so)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  if (unsupported) c.read(futureActionsUnsupportedProvider.notifier).state = true;
  await tester.pump();
  return f;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  tearDown(() => QuiccColors.setAccent(StoreLook.defaultAccent));

  group('future order actions', () {
    test('the due picker maths: slots from the next 5-minute mark today, all day tomorrow', () {
      final now = DateTime(2026, 11, 6, 14, 2);
      final today = dueSlots(DateTime(2026, 11, 6), now);
      expect(today.first, DateTime(2026, 11, 6, 14, 5));
      expect(today.last, DateTime(2026, 11, 6, 23, 55));
      expect(dueSlots(DateTime(2026, 11, 7), now).length, 24 * 12);
      expect(dayClock(DateTime(2026, 11, 6, 19, 30), now: now), 'Today 7:30 PM');
      expect(dayClock(DateTime(2026, 11, 7, 23, 0), now: now), 'Tomorrow 11:00 PM');
      expect(dayClock(DateTime(2026, 11, 9, 12, 0), now: now), 'Mon, Nov 9 · 12:00 PM');
    });

    test('the API: paths and bodies; a missing route is unsupported', () async {
      final seen = <http.Request>[];
      var missing = false;
      final client = AgentClient(
        baseUrl: 'http://pi:8080',
        deviceKey: 'k',
        client: MockClient((req) async {
          seen.add(req);
          if (missing) return http.Response('', 405);
          if (req.url.path.endsWith('/print-now')) {
            return http.Response(jsonEncode({'order': null, 'printed': ['Pizza'], 'failed': [], 'rerouted': []}), 200);
          }
          if (req.url.path == '/api/settings/look') {
            return http.Response(
              jsonEncode({
                'accent': '#4FD1C5',
                'tickets': {'delivery': '#8B5CF6', 'pickup': '#3B82F6', 'counter': '#3B82F6'},
              }),
              200,
            );
          }
          return http.Response(onDeliveryJson, 200);
        }),
      );
      await client.makeNow('o1', 20);
      await client.changeDue('o1', DateTime.utc(2026, 11, 7, 3));
      final r = await client.printNow('o1', kitchen: true, receipt: false);
      await client.cancelFuture('o1');
      final look = await client.setLook(accent: const Color(0xFF4FD1C5), delivery: const Color(0xFF8B5CF6));
      expect([for (final q in seen) '${q.method} ${q.url.path}'], [
        'POST /api/orders/o1/make-now',
        'POST /api/orders/o1/due',
        'POST /api/orders/o1/print-now',
        'POST /api/orders/o1/cancel',
        'PUT /api/settings/look',
      ]);
      expect(jsonDecode(seen[0].body), {'prep_minutes': 20});
      expect(jsonDecode(seen[1].body), {'promised_at': '2026-11-07T03:00:00.000Z'});
      expect(jsonDecode(seen[2].body), {'kitchen': true, 'receipt': false});
      expect(jsonDecode(seen[4].body), {
        'accent': '#4FD1C5',
        'tickets': {'delivery': '#8B5CF6'},
      });
      expect(r.printed, ['Pizza']);
      expect(look.delivery, const Color(0xFF8B5CF6));
      missing = true;
      await expectLater(
        client.makeNow('o1', 20),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', kFutureActionsUnsupported)),
      );
    });

    testWidgets('MAKE NOW: the store default with −5 / +5, then back to Kitchen', (tester) async {
      final so = futureDelivery('f1');
      final f = await pumpFutureDetail(tester, so);
      expect(find.byKey(const ValueKey('later-panel')), findsOneWidget);
      expect(find.textContaining('Due Tomorrow'), findsWidgets);
      await tapKey(tester, 'future-make-now');
      final base = int.parse(tester.widget<Text>(find.byKey(const ValueKey('make-now-minutes'))).data!.split(' ').first);
      await tester.tap(find.byKey(const ValueKey('make-now-plus')));
      await tester.pump();
      await tapKey(tester, 'make-now-confirm');
      expect(callsOf(f, 'makeNow').single.extra['prep'], base + 5);
      expect(find.text('HOME'), findsOneWidget, reason: 'the details closed');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('CHANGE DUE TIME: Today / Tomorrow chips and the wheel', (tester) async {
      final f = await pumpFutureDetail(tester, futureDelivery('f2'));
      await tapKey(tester, 'future-due');
      expect(find.byKey(const ValueKey('due-tomorrow')), findsOneWidget);
      expect(find.textContaining('rings at'), findsOneWidget);
      await tapKey(tester, 'due-today');
      await tapKey(tester, 'due-confirm');
      final due = callsOf(f, 'due').single.extra['due']! as DateTime;
      final now = clock.now();
      expect(due.isAfter(now), isTrue);
      expect(due.day, now.day, reason: 'Today keeps the time of day where it can');
      expect(due.minute % 5, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('PRINT NOW: kitchen / receipt / both', (tester) async {
      final f = await pumpFutureDetail(tester, futureDelivery('f3'));
      await tapKey(tester, 'future-print');
      await tapKey(tester, 'print-now-both');
      expect(callsOf(f, 'printNow').single.extra, {'kitchen': true, 'receipt': true});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('CANCEL: a red confirm with the total and the card refund line', (tester) async {
      final f = await pumpFutureDetail(tester, futureDelivery('f4'));
      await tapKey(tester, 'future-cancel');
      expect(find.textContaining(kCardRefundNote), findsOneWidget);
      await tester.tap(find.text('KEEP IT'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(callsOf(f, 'cancel'), isEmpty);
      await tapKey(tester, 'future-cancel');
      await tester.tap(find.text('CANCEL ORDER').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(callsOf(f, 'cancel').single.ids, ['f4']);
      await tester.pumpWidget(const SizedBox());
      // A cash order: no refund line.
      await pumpFutureDetail(tester, futureDelivery('f5', card: false));
      await tapKey(tester, 'future-cancel');
      expect(find.textContaining(kCardRefundNote), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an arrived future order has the panel too; an older Pi keeps only CHANGE LEAD TIME', (tester) async {
      await pumpFutureDetail(tester, futureDelivery('f6', state: 'arrived'));
      expect(find.byKey(const ValueKey('future-make-now')), findsOneWidget);
      expect(find.byKey(const ValueKey('future-lead')), findsNothing, reason: 'not scheduled yet');
      await tester.pumpWidget(const SizedBox());
      await pumpFutureDetail(tester, futureDelivery('f7'), unsupported: true);
      expect(find.byKey(const ValueKey('future-make-now')), findsNothing);
      expect(find.byKey(const ValueKey('future-cancel')), findsNothing);
      expect(find.byKey(const ValueKey('future-lead')), findsOneWidget);
      expect(find.textContaining('This Pi needs an update'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Deliveries', () {
    Future<FutureFloor> pumpPane(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = FutureFloor(deliveryFloor());
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            builder: (context, child) =>
                MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
            home: const Scaffold(body: DeliveriesPane()),
          ),
        ),
      );
      await tester.pump();
      return f;
    }

    testWidgets('selecting does not move the rows', (tester) async {
      await pumpPane(tester);
      final before = tester.getTopLeft(find.byKey(const ValueKey('row-d1')));
      await tester.tap(find.byKey(const ValueKey('row-d1')));
      await tester.pump();
      expect(find.byKey(const ValueKey('select-bar')), findsOneWidget);
      expect(find.text('Tap here to take the selected out of their pools'), findsNothing);
      expect(tester.getTopLeft(find.byKey(const ValueKey('row-d1'))), before);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('MARK DELIVERED on the selection marks every one', (tester) async {
      final f = await pumpPane(tester);
      await tester.tap(find.byKey(const ValueKey('row-d1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('row-d5')));
      await tester.pump();
      expect(find.text('MARK DELIVERED · 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mark-delivered-selected')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(callsOf(f, 'delivered').map((c) => c.ids.single), ['d1', 'd5']);
      expect(find.byKey(const ValueKey('select-bar')), findsNothing, reason: 'the selection is done');
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('MARK DELIVERED on the details closes them', (tester) async {
    final so = delivery('m9', 1309, state: 'accepted', readyInMinutes: 10);
    final f = await pumpFutureDetail(tester, so);
    await tapKey(tester, 'mark-delivered');
    expect(callsOf(f, 'delivered').single.ids, ['m9']);
    expect(find.text('HOME'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('Kitchen', () {
    testWidgets('a filter switch hides tickets without the READY implosion', (tester) async {
      await pumpKitchen(tester, [pickup('p1', 1101), cookingDelivery('d1', 1102)]);
      final grid = tester.state<AnimatedKitchenGridState>(find.byType(AnimatedKitchenGrid));
      await tapFilter(tester, KitchenFilter.delivery);
      expect(grid.ghosts, isEmpty);
      await tapFilter(tester, KitchenFilter.all);
      expect(grid.ghosts, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('READY still implodes', (tester) async {
      final (_, f) = await pumpKitchen(tester, [pickup('p1', 1101), pickup('p2', 1102)]);
      final grid = tester.state<AnimatedKitchenGridState>(find.byType(AnimatedKitchenGrid));
      f.push(board([pickup('p2', 1102)]));
      await tester.pump();
      expect(grid.ghosts, ['p1']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets("the bar takes the type's colour; the timer keeps green → red", (tester) async {
      final purple = const Color(0xFF8B5CF6);
      final (_, f) = await pumpKitchen(tester, [
        pickup('p1', 1101),
        cookingDelivery('d1', 1102, ago: 60),
      ]);
      final s = f.state;
      f.push(
        s.copyWith(
          floor: s.floor!.copyWith(
            settings: s.settings.copyWith(look: const StoreLook().copyWith(delivery: purple)),
          ),
        ),
      );
      await tester.pump();
      Color barOf(String id) => tester
          .widget<Container>(
            find.descendant(of: find.byKey(ValueKey(id)), matching: find.byKey(const ValueKey('card-bar'))),
          )
          .color!;
      Color timerOf(String id) =>
          (tester
                      .widget<Container>(
                        find.descendant(
                          of: find.byKey(ValueKey(id)),
                          matching: find.byKey(const ValueKey('ticket-timer-pill')),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      expect(barOf('p1'), StoreLook.defaultTicket);
      expect(barOf('d1'), purple);
      expect(timerOf('p1'), QuiccColors.statusPaid);
      expect(timerOf('d1'), QuiccColors.statusVoided);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('Settings and colours', () {
    test('the accent ramp: the lavender exactly by default, a new anchor otherwise', () {
      expect(QuiccColors.brand400, StoreLook.defaultAccent);
      expect(QuiccColors.brand900, const Color(0xFF241B47));
      expect(QuiccColors.setAccent(const Color(0xFF4FD1C5)), isTrue);
      expect(QuiccColors.brand400, const Color(0xFF4FD1C5));
      expect(QuiccColors.brand900.computeLuminance(), lessThan(0.05), reason: 'deep enough for text');
      expect(QuiccColors.brand50.computeLuminance(), greaterThan(0.8));
      expect(QuiccColors.setAccent(const Color(0xFF4FD1C5)), isFalse);
      QuiccColors.setAccent(StoreLook.defaultAccent);
      expect(QuiccColors.brand600, const Color(0xFF6D4FD4));
    });

    test('StoreLook: defaults, parsing, an older Pi has none', () {
      expect(FloorSettings.fromJson(const {}).look, isNull);
      final l = StoreLook.fromJson({
        'accent': '#4fd1c5',
        'tickets': {'delivery': '#8B5CF6', 'pickup': 'nope'},
      });
      expect(l.accent, const Color(0xFF4FD1C5));
      expect(l.delivery, const Color(0xFF8B5CF6));
      expect(l.pickup, StoreLook.defaultTicket);
      expect(hexOfColor(l.accent), '#4FD1C5');
    });

    testWidgets('Settings is a list; Colors saves a swatch for every tablet', (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final base = deliveryFloor();
      final f = FutureFloor(
        base.copyWith(floor: base.floor!.copyWith(settings: base.settings.copyWith(look: const StoreLook()))),
      );
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: StoreSettingsScreen())),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('group-colors')), findsOneWidget);
      expect(find.byKey(const ValueKey('motion-switch')), findsNothing, reason: 'inside Sound & look');
      await tapKey(tester, 'group-colors');
      expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
      await tapKey(tester, 'swatch-accent-teal');
      expect(callsOf(f, 'look').single.extra['accent'], const Color(0xFF4FD1C5));
      await tapKey(tester, 'swatch-delivery-purple');
      expect(callsOf(f, 'look').last.extra['delivery'], const Color(0xFF8B5CF6));
      expect(c.read(storeLookProvider).delivery, const Color(0xFF8B5CF6));
      await tapKey(tester, 'settings-back');
      expect(find.byKey(const ValueKey('group-colors')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
