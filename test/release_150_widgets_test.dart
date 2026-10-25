// Quibase 1.5.0 screens: the time picker (accept / first ring of a future
// order / ring again), the Later strip, POS tickets (number, POS tag, PAID),
// the card bar and the paid wave, board_hidden, Check address, Driver #,
// Settings switches, hub toasts vs banners, and the soft chime.
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
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/ring_bridge.dart';
import 'package:mobile_agent/core/ring_platform.dart';
import 'package:mobile_agent/core/soft_chime.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/arrived/accept_controls.dart';
import 'package:mobile_agent/features/deliveries/delivery_widgets.dart';
import 'package:mobile_agent/features/drivers/drivers_pane.dart';
import 'package:mobile_agent/features/integration/integration_alerts.dart';
import 'package:mobile_agent/features/kitchen/kitchen_pane.dart';
import 'package:mobile_agent/features/maps/check_address_sheet.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:mobile_agent/features/settings/pos_settings_cards.dart';
import 'package:mobile_agent/features/setup/steps/drivers_step.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'pos_fixtures.dart';

const _paired = {'agent_address': 'http://10.0.0.5:8080', 'device_key': 'qagt_k', 'device_name': 'Counter'};

ThemeData _theme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// An online pickup (card-paid) in [state], [ago] since it arrived.
Map<String, dynamic> _online(
  String id, {
  String state = 'accepted',
  String type = 'pickup',
  Map<String, Object?> status = const {},
  Duration ago = const Duration(minutes: 3),
}) {
  final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  final at = DateTime.now().toUtc().subtract(ago).toIso8601String();
  (m['order'] as Map)['id'] = id;
  ((m['order'] as Map)['fulfillment'] as Map)['type'] = type;
  (m['status'] as Map)
    ..['state'] = state
    ..['arrival_date'] = at
    ..['accepted_at'] = at
    ..addAll(status);
  if (state == 'accepted' && !(m['status'] as Map).containsKey('ext_source')) {
    (m['status'] as Map)['kitchen_number'] = 1104;
  }
  return m;
}

Map<String, dynamic> _pos(
  String id, {
  int number = 99,
  String type = 'pickup',
  Map<String, Object?> status = const {},
}) => _online(
  id,
  type: type,
  status: {'ext_source': 'softtouch', 'ext_ref': '12$number', 'display_number': number, ...status},
);

/// A FloorController that never touches the network on its own; [apply]
/// feeds it an SSE frame.
class _FakeFloor extends FloorController {
  final FloorState initial;
  _FakeFloor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}

  void apply(SseEvent ev) => state = applySseEvent(state, ev).state;
}

class _Agent {
  final List<http.Request> requests = [];
  http.Response Function(http.Request req) handler;
  _Agent([http.Response Function(http.Request req)? handler]) : handler = handler ?? ((_) => _json(const {}));

  AgentClient client() => AgentClient(
    baseUrl: 'http://10.0.0.5:8080',
    deviceKey: 'qagt_k',
    client: MockClient((req) async {
      requests.add(req);
      return handler(req);
    }),
  );

  List<String> get paths => [for (final r in requests) '${r.method} ${r.url.path}'];
  Map<String, dynamic> bodyOf(String path) =>
      jsonDecode(requests.lastWhere((r) => '${r.method} ${r.url.path}' == path).body) as Map<String, dynamic>;
}

FloorState _floorState(
  List<StoredOrder> orders, {
  Map<String, Object?> settings = const {},
  Map<String, Object?>? integration,
  List<Driver> drivers = const [],
}) {
  final f = jsonDecode(floorJson) as Map<String, dynamic>;
  f['settings'] = settings;
  if (integration != null) f['integration'] = integration;
  return const FloorState(connection: SseStatus.connected).withSnapshot(
    floor: Floor.fromJson(f),
    current: [
      for (final o in orders)
        if (o.state != OrderState.arrived) o,
    ],
    arrived: [
      for (final o in orders)
        if (o.state == OrderState.arrived) o,
    ],
    drivers: drivers,
    at: DateTime.now(),
  );
}

Future<ProviderContainer> _pump(WidgetTester tester, _Agent agent, FloorState floor, Widget body) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(_paired);
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      agentClientProvider.overrideWithValue(agent.client()),
      floorProvider.overrideWith(() => _FakeFloor(floor)),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: _theme(), home: body),
    ),
  );
  await _settle(tester);
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Unmounts (stops tickers / waves) and lets snackbar timers finish.
Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 10));
}

Widget _accept(StoredOrder so) => Scaffold(
  body: Center(
    child: SizedBox(width: 560, child: AcceptControls(order: so)),
  ),
);

bool _enabled(WidgetTester tester, String key) =>
    tester
        .widget<OutlinedButton>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(OutlinedButton)))
        .onPressed !=
    null;

void main() {
  group('time picker on accept', () {
    testWidgets('X is preselected: one CONFIRM sends the default pickup time', (tester) async {
      final so = StoredOrder.fromJson(_online('a-1', state: 'arrived'));
      final agent = _Agent((req) => _json(_online('a-1')));
      await _pump(tester, agent, _floorState([so]), _accept(so));
      expect(find.byKey(const ValueKey('time-picker')), findsOneWidget);
      expect(find.text('ACCEPT · 15 MIN'), findsOneWidget);
      expect(find.text('15 min', findRichText: true), findsOneWidget);
      expect(find.text('20 min', findRichText: true), findsOneWidget);
      expect(find.text('25 min', findRichText: true), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('accept-confirm')));
      await _settle(tester);
      expect(agent.paths, ['POST /api/orders/a-1/accept']);
      expect(agent.bodyOf('POST /api/orders/a-1/accept'), {'prep_minutes': 15});
      await _done(tester);
    });

    testWidgets('X+5 and the stepped X+10 are sent; −5 never goes below X+10', (tester) async {
      final so = StoredOrder.fromJson(_online('a-2', state: 'arrived'));
      final agent = _Agent((req) => _json(_online('a-2')));
      await _pump(
        tester,
        agent,
        _floorState(
          [so],
          settings: {
            'times': {'default_pickup_minutes': 20},
          },
        ),
        _accept(so),
      );
      expect(find.text('ACCEPT · 20 MIN'), findsOneWidget);
      expect(_enabled(tester, 'pick-minus'), isFalse, reason: 'already at X+10');

      await tester.tap(find.byKey(const ValueKey('pick-x5')));
      await tester.pump();
      expect(find.text('ACCEPT · 25 MIN'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pick-plus')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pick-plus')));
      await tester.pump();
      expect(find.text('ACCEPT · 40 MIN'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pick-minus')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pick-minus')));
      await tester.pump();
      expect(find.text('ACCEPT · 30 MIN'), findsOneWidget);
      expect(_enabled(tester, 'pick-minus'), isFalse);
      await tester.tap(find.byKey(const ValueKey('pick-minus')), warnIfMissed: false);
      await tester.pump();
      expect(find.text('ACCEPT · 30 MIN'), findsOneWidget, reason: 'floored at X+10');

      await tester.tap(find.byKey(const ValueKey('accept-confirm')));
      await _settle(tester);
      expect(agent.bodyOf('POST /api/orders/a-2/accept'), {'prep_minutes': 30});
      await _done(tester);
    });

    testWidgets('a delivery starts from the default delivery time (Y)', (tester) async {
      final so = StoredOrder.fromJson(_online('a-3', state: 'arrived', type: 'delivery'));
      await _pump(tester, _Agent(), _floorState([so]), _accept(so));
      expect(find.text('ACCEPT · 35 MIN'), findsOneWidget);
      expect(find.text('45 min', findRichText: true), findsOneWidget, reason: 'Y+10');
      await _done(tester);
    });

    testWidgets("a future order's first ring sets the lead time: POST /schedule, nothing printed", (tester) async {
      final so = StoredOrder.fromJson(
        _online('f-1', state: 'arrived', status: {'future': true})
          ..['order']['fulfillment']['promised_at'] = '2030-01-01T20:00:00Z',
      );
      final agent = _Agent((req) => _json(_online('f-1', state: 'scheduled', status: {'future': true})));
      await _pump(tester, agent, _floorState([so]), _accept(so));
      expect(find.byKey(const ValueKey('time-picker')), findsOneWidget);
      expect(find.text('CONFIRM · 15 MIN BEFORE'), findsOneWidget);
      expect(find.textContaining('Nothing prints now'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('accept-confirm')));
      await _settle(tester);
      expect(agent.paths, ['POST /api/orders/f-1/schedule']);
      expect(agent.bodyOf('POST /api/orders/f-1/schedule'), {'lead_minutes': 15});
      await _done(tester);
    });

    testWidgets('rung again (rerung): no picker, one CONFIRM prints with the lead picked before', (tester) async {
      final so = StoredOrder.fromJson(
        _online('f-2', state: 'arrived', status: {'future': true, 'rerung': true, 'scheduled_lead_minutes': 25}),
      );
      final agent = _Agent((req) => _json(_online('f-2')));
      await _pump(tester, agent, _floorState([so]), _accept(so));
      expect(find.byKey(const ValueKey('time-picker')), findsNothing);
      expect(find.text('CONFIRM · PRINT'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('accept-confirm')));
      await _settle(tester);
      expect(agent.paths, ['POST /api/orders/f-2/accept']);
      expect(agent.bodyOf('POST /api/orders/f-2/accept'), {'prep_minutes': 25});
      await _done(tester);
    });
  });

  group('Kitchen board', () {
    testWidgets('the Later strip shows scheduled orders greyed with the due time; tap edits the lead', (tester) async {
      final due = DateTime.now().add(const Duration(hours: 3)).toUtc();
      final m = _online(
        'l-1',
        state: 'scheduled',
        status: {
          'future': true,
          'scheduled_lead_minutes': 20,
          'ring_at': due.subtract(const Duration(minutes: 20)).toIso8601String(),
        },
      );
      (m['order']['fulfillment'] as Map)['promised_at'] = due.toIso8601String();
      final so = StoredOrder.fromJson(m);
      final agent = _Agent((req) => _json(m));
      await _pump(tester, agent, _floorState([so]), const Scaffold(body: KitchenPane()));

      expect(find.byKey(const ValueKey('later-strip')), findsOneWidget);
      expect(find.text('Due ${_clock(due)}'), findsOneWidget);
      expect(find.textContaining('20 min lead'), findsOneWidget);
      expect(find.byType(KitchenCard), findsNothing, reason: 'not cooking yet');

      await tester.tap(find.byKey(const ValueKey('later-l-1')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pick-x10')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lead-confirm')));
      await _settle(tester);
      expect(agent.paths, ['POST /api/orders/l-1/schedule']);
      expect(agent.bodyOf('POST /api/orders/l-1/schedule'), {'lead_minutes': 25});
      await _done(tester);
    });

    testWidgets('a POS ticket: plain check #, POS tag, PAID; board_hidden ones never show', (tester) async {
      final shown = StoredOrder.fromJson(_pos('p-1', number: 99, status: {'paid': true}));
      final hidden = StoredOrder.fromJson(_pos('p-2', number: 98, type: 'dine_in', status: {'board_hidden': true}));
      await _pump(tester, _Agent(), _floorState([shown, hidden]), const Scaffold(body: KitchenPane()));
      expect(find.byType(KitchenCard), findsOneWidget);
      expect(find.text('99'), findsOneWidget);
      expect(find.text('98'), findsNothing);
      expect(find.byKey(const ValueKey('pos-tag')), findsOneWidget);
      expect(find.byKey(const ValueKey('paid-badge')), findsOneWidget);
      await _done(tester);
    });

    testWidgets('the card has a white body and a header bar in the urgency colour', (tester) async {
      final fresh = StoredOrder.fromJson(_online('c-1'));
      final late = StoredOrder.fromJson(_online('c-2', ago: const Duration(minutes: 50)));
      await _pump(tester, _Agent(), _floorState([fresh, late]), const Scaffold(body: KitchenPane()));
      Color barOf(String id) => tester
          .widget<Container>(
            find.descendant(of: find.byKey(ValueKey(id)), matching: find.byKey(const ValueKey('card-bar'))),
          )
          .color!;
      expect(barOf('c-1'), QuiccColors.statusPaid, reason: 'green while fresh');
      expect(barOf('c-2'), QuiccColors.statusVoided, reason: 'red at twice the green time');
      final card = tester.widget<Container>(
        find.descendant(of: find.byKey(const ValueKey('c-1')), matching: find.byType(Container)).first,
      );
      expect((card.decoration! as BoxDecoration).color, Colors.white);
      await _done(tester);
    });

    testWidgets('the paid wave: on a paid pickup while cooking, not at ready, not when switched off', (tester) async {
      final paid = StoredOrder.fromJson(_online('w-1'));
      final cash = _online('w-2');
      (cash['order']['payments'] as List)
        ..clear()
        ..add({'method': 'cash', 'amount_cents': 2755});
      await _pump(
        tester,
        _Agent(),
        _floorState([paid, StoredOrder.fromJson(cash)]),
        const Scaffold(body: KitchenPane()),
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('w-1')), matching: find.byKey(const ValueKey('paid-wave'))),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('w-2')), matching: find.byKey(const ValueKey('paid-wave'))),
        findsNothing,
        reason: 'cash still due',
      );
      // It animates (a slow sweep), so the frame keeps changing.
      expect(tester.binding.hasScheduledFrame, isTrue);
      await _done(tester);

      // Ready: the ticket no longer waves.
      final ready = StoredOrder.fromJson(_online('w-3', state: 'ready'));
      await _pump(
        tester,
        _Agent(),
        _floorState([ready]),
        Scaffold(
          body: SizedBox(
            width: kTicketWidth,
            child: KitchenCard(order: ready),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('paid-wave')), findsNothing);
      await _done(tester);

      // Feature off.
      await _pump(
        tester,
        _Agent(),
        _floorState(
          [paid],
          settings: {
            'features': {'paid_wave': false},
          },
        ),
        const Scaffold(body: KitchenPane()),
      );
      expect(find.byType(KitchenCard), findsOneWidget);
      expect(find.byKey(const ValueKey('paid-wave')), findsNothing);
      await _done(tester);
    });

    testWidgets("an order's flag shows on its ticket", (tester) async {
      final so = StoredOrder.fromJson(
        _online(
          'fl-1',
          status: {
            'flag': {'text': 'Settle manually: unmapped item X', 'severity': 'warn'},
          },
        ),
      );
      await _pump(tester, _Agent(), _floorState([so]), const Scaffold(body: KitchenPane()));
      expect(find.byKey(const ValueKey('order-flag')), findsOneWidget);
      expect(find.text('Settle manually: unmapped item X'), findsOneWidget);
      await _done(tester);
    });
  });

  group('Check address', () {
    testWidgets('the sheet lists the candidates; picking one calls geo/choose', (tester) async {
      final so = StoredOrder.fromJson(jsonDecode(posDeliveryJson) as Map<String, dynamic>);
      final agent = _Agent((req) => http.Response('', 202));
      await _pump(
        tester,
        agent,
        _floorState([so]),
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(onPressed: () => showCheckAddressSheet(context, so), child: const Text('OPEN')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OPEN'));
      await _settle(tester);
      expect(find.text('12 York Rd, Towson, MD 21204'), findsOneWidget);
      expect(find.text('12 Yorke Ct, Towson, MD 21286'), findsOneWidget);
      expect(find.text('12 Yorkshire Dr, Towson, MD 21286'), findsOneWidget);
      expect(find.byKey(const ValueKey('drop-pin')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('candidate-1')));
      await _settle(tester);
      expect(agent.paths, ['POST /api/orders/pos-0001/geo/choose']);
      expect(agent.bodyOf('POST /api/orders/pos-0001/geo/choose'), {'index': 1});
      expect(find.byType(CheckAddressSheet), findsNothing, reason: 'closed after the choice');
      await _done(tester);
    });

    testWidgets('the delivery row offers CHECK ADDRESS (and shows the POS #)', (tester) async {
      final so = StoredOrder.fromJson(jsonDecode(posDeliveryJson) as Map<String, dynamic>);
      await _pump(
        tester,
        _Agent(),
        _floorState([so]),
        Scaffold(
          body: SizedBox(
            width: 600,
            child: UnassignedRow(order: so, selectMode: false, selected: false, targetMinutes: 45, onTap: () {}),
          ),
        ),
      );
      expect(find.text('99'), findsOneWidget);
      expect(find.byKey(const ValueKey('pos-tag')), findsOneWidget);
      expect(find.text('CASH \$21.20'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('check-address-pos-0001')));
      await _settle(tester);
      expect(find.byType(CheckAddressSheet), findsOneWidget);
      await _done(tester);
    });
  });

  group('order detail', () {
    testWidgets('a POS delivery: check # + POS tag, flag, CHECK ADDRESS, Reprint and Resend', (tester) async {
      final so = StoredOrder.fromJson(jsonDecode(posDeliveryJson) as Map<String, dynamic>);
      await _pump(tester, _Agent(), _floorState([so]), OrderDetailScreen(orderId: so.id, initial: so));
      expect(find.text('99'), findsWidgets);
      expect(find.byKey(const ValueKey('pos-tag')), findsOneWidget);
      expect(find.byKey(const ValueKey('order-flag')), findsOneWidget);
      expect(find.text('Settle manually: unmapped item X'), findsOneWidget);
      expect(find.text('POS says #12 (not clocked in)'), findsOneWidget);
      expect(find.text('REPRINT RECEIPT'), findsOneWidget);
      expect(find.text('RESEND TO KITCHEN'), findsOneWidget, reason: 'a POS order has no kitchen # but can resend');
      expect(find.text('CASH DUE \$21.20'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('check-address')));
      await _settle(tester);
      expect(find.byType(CheckAddressSheet), findsOneWidget);
      await _done(tester);
    });

    testWidgets('a scheduled order: due time, CHANGE LEAD TIME, nothing to reprint', (tester) async {
      final due = DateTime.now().add(const Duration(hours: 2)).toUtc();
      final m = _online('s-1', state: 'scheduled', status: {'future': true, 'scheduled_lead_minutes': 20});
      (m['order']['fulfillment'] as Map)['promised_at'] = due.toIso8601String();
      final so = StoredOrder.fromJson(m);
      await _pump(tester, _Agent(), _floorState([so]), OrderDetailScreen(orderId: so.id, initial: so));
      expect(find.text('Due ${_clock(due)}'), findsOneWidget);
      expect(find.text('CHANGE LEAD TIME'), findsOneWidget);
      expect(find.text('REPRINT RECEIPT'), findsNothing);
      expect(find.text('LATER'), findsOneWidget, reason: 'the state pill');
      await _done(tester);
    });
  });

  group('Driver #', () {
    testWidgets('Drivers: add sends pos_number; edit sends only the number', (tester) async {
      const ana = Driver(id: 'd-ana', name: 'Ana', status: DriverStatus.off);
      final agent = _Agent((req) {
        if (req.method == 'GET') {
          return _json([
            {'id': 'd-ana', 'name': 'Ana', 'status': 'off'},
          ]);
        }
        return _json({'id': 'd-new', 'name': 'Bo', 'pos_number': '12'});
      });
      await _pump(tester, agent, _floorState(const [], drivers: const [ana]), const Scaffold(body: DriversPane()));

      await tester.tap(find.text('ADD DRIVER'));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('driver-name')), 'Bo');
      await tester.enterText(find.byKey(const ValueKey('driver-pos-number')), '12x');
      await tester.tap(find.byKey(const ValueKey('driver-save')));
      await _settle(tester);
      expect(agent.bodyOf('POST /api/drivers'), {'name': 'Bo', 'pos_number': '12'}, reason: 'digits only');

      await tester.tap(find.byTooltip('Edit name / Driver #'));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('driver-pos-number')), '7');
      await tester.tap(find.byKey(const ValueKey('driver-save')));
      await _settle(tester);
      expect(agent.bodyOf('PATCH /api/drivers/d-ana'), {'pos_number': '7'});
      await _done(tester);
    });

    testWidgets('setup wizard drivers step: a Driver # box next to the name', (tester) async {
      final agent = _Agent((req) => req.method == 'GET' ? _json(const []) : _json({'id': 'd-1', 'name': 'Cy'}));
      await _pump(
        tester,
        agent,
        _floorState(const []),
        const Scaffold(
          body: Padding(padding: EdgeInsets.all(24), child: DriversPanel()),
        ),
      );
      expect(find.byKey(const ValueKey('driver-pos-number')), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'Cy');
      await tester.enterText(find.byKey(const ValueKey('driver-pos-number')), '31');
      await tester.tap(find.text('ADD'));
      await _settle(tester);
      expect(agent.bodyOf('POST /api/drivers'), {'name': 'Cy', 'pos_number': '31'});
      await _done(tester);
    });
  });

  testWidgets('Settings → Features: a switch saves the whole set on the Pi', (tester) async {
    final agent = _Agent((req) => http.Response(req.body, 200, headers: {'content-type': 'application/json'}));
    final c = await _pump(
      tester,
      agent,
      _floorState(const []),
      const Scaffold(
        body: SingleChildScrollView(child: Column(children: [FeaturesSettingsCard(), KitchenTicketsSettingsCard()])),
      ),
    );
    expect(find.text('POS orders pull-in'), findsOneWidget);
    expect(find.text('Online cash pickup'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('switch-paid_wave')));
    await _settle(tester);
    expect(agent.paths, ['PUT /api/settings/features']);
    expect(agent.bodyOf('PUT /api/settings/features')['paid_wave'], false);
    expect(agent.bodyOf('PUT /api/settings/features')['pos_pull'], true);
    expect(c.read(floorProvider).settings.features.paidWave, isFalse);
    await _done(tester);
  });

  testWidgets('hub problems: info / warn as a top-right toast, serious as a banner that stays', (tester) async {
    final c = await _pump(
      tester,
      _Agent(),
      _floorState(
        const [],
        integration: {
          'connected': true,
          'problems': [
            {'code': 'unmapped', 'text': 'Unmapped item: Calzone', 'severity': 'warn'},
            {'code': 'batch', 'text': 'Quicc batch not open in SoftTouch', 'severity': 'serious'},
          ],
        },
      ),
      const Scaffold(
        body: Column(
          children: [
            IntegrationBanner(),
            Expanded(
              child: Stack(children: [Positioned(top: 12, right: 16, child: IntegrationToastHost())]),
            ),
          ],
        ),
      ),
    );
    final banner = find.byKey(const ValueKey('integration-banner'));
    final toasts = find.byKey(const ValueKey('integration-toasts'));
    expect(find.descendant(of: banner, matching: find.text('Quicc batch not open in SoftTouch')), findsOneWidget);
    expect(find.descendant(of: banner, matching: find.text('Unmapped item: Calzone')), findsNothing);
    expect(find.descendant(of: toasts, matching: find.text('Unmapped item: Calzone')), findsOneWidget);
    expect(find.descendant(of: toasts, matching: find.text('Quicc batch not open in SoftTouch')), findsNothing);

    (c.read(floorProvider.notifier) as _FakeFloor).apply(
      SseEvent('integration.toast', jsonEncode({'text': 'POS says #12 — not clocked in', 'severity': 'warn'})),
    );
    await _settle(tester);
    expect(find.descendant(of: toasts, matching: find.text('POS says #12 — not clocked in')), findsOneWidget);

    // Toasts fade by themselves; the serious banner stays until cleared.
    await tester.pump(kIntegrationToastFor + const Duration(seconds: 1));
    expect(toasts, findsNothing);
    expect(banner, findsOneWidget);

    (c.read(floorProvider.notifier) as _FakeFloor).apply(
      SseEvent('integration.status', jsonEncode({'connected': true, 'ok': true, 'problems': <Object>[]})),
    );
    await tester.pump();
    expect(banner, findsNothing);
    await _done(tester);
  });

  test('a new POS delivery plays the soft chime once (no ring)', () async {
    AlertPlayer.resetForTest(_QuietSink());
    SharedPreferences.setMockInitialValues(_paired);
    final prefs = await SharedPreferences.getInstance();
    final chime = _FakeChime();
    final c = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ringPlatformProvider.overrideWithValue(_FakeRing()),
        softChimeProvider.overrideWithValue(chime),
        floorProvider.overrideWith(() => _FakeFloor(_floorState(const []))),
      ],
    );
    addTearDown(c.dispose);
    final undo = startRingBridge(c);
    addTearDown(undo);
    final floor = c.read(floorProvider.notifier) as _FakeFloor;
    final added = jsonEncode({'order': jsonDecode(posDeliveryJson), 'chime': true});
    floor.apply(SseEvent('order.added', added));
    await Future<void>.delayed(Duration.zero);
    expect(chime.plays, 1);
    floor.apply(SseEvent('order.added', added));
    await Future<void>.delayed(Duration.zero);
    expect(chime.plays, 1, reason: 'the same order again does not chime');
    expect(c.read(alarmProvider).ringing, isFalse);
  });
}

String _clock(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}

class _FakeChime implements SoftChime {
  int plays = 0;
  @override
  Future<void> play() async => plays++;
}

class _FakeRing extends RingPlatform {
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

class _QuietSink implements AlarmSink {
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
