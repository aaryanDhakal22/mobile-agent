// Quibase 1.5.0 (agent 2.1.0): POS orders from the store hub, future orders,
// feature / ticket switches, default times, Check address, Driver #, hub
// status — the wire models, the SSE reducer and the new agent calls.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/arrived/time_picker.dart';
import 'package:mobile_agent/features/integration/integration_alerts.dart';
import 'package:mobile_agent/features/setup/setup_flow.dart';

import 'fixtures.dart';
import 'pos_fixtures.dart';

Map<String, dynamic> _online(String id, {String state = 'accepted', Map<String, Object?> status = const {}}) {
  final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  (m['order'] as Map)['id'] = id;
  (m['status'] as Map)
    ..['state'] = state
    ..addAll(status);
  return m;
}

StoredOrder _so(Map<String, dynamic> m) => StoredOrder.fromJson(m);

FloorState _floor(List<StoredOrder> orders) => const FloorState(connection: SseStatus.connected).withSnapshot(
  floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
  current: orders,
  arrived: const [],
  drivers: const [],
  at: DateTime.now(),
);

SseEvent _ev(String type, Object payload) => SseEvent(type, jsonEncode(payload));

void main() {
  group('models (2.1.0 fields)', () {
    test('a POS order parses every new status field, and shows its check #', () {
      final so = _so(jsonDecode(posDeliveryJson) as Map<String, dynamic>);
      final st = so.status;
      expect(st.extSource, 'softtouch');
      expect(st.extRef, '1276237');
      expect(st.displayNumber, 99);
      expect(st.paid, isFalse);
      expect(st.cashDueCents, 2120);
      expect(st.tipCents, 300);
      expect(st.boardHidden, isFalse);
      expect(st.sentAt, DateTime.utc(2026, 10, 25, 17, 1));
      expect(st.localOnly, isTrue);
      expect(st.flag!.text, 'Settle manually: unmapped item X');
      expect(st.flag!.severity, Severity.serious);
      expect(st.posCheckNumber, 4410);
      expect(st.posDriverNote, 'POS says #12 (not clocked in)');
      expect(so.isPos, isTrue);
      expect(so.displayNumber, '99', reason: 'plain POS #, not a kitchen number');
      expect(so.cashDueCents, 2120, reason: "the hub's figure, not the online payments");
      expect(so.isPaid, isFalse);
    });

    test('future-order fields and the scheduled state', () {
      final so = _so(
        _online(
          'f-1',
          state: 'scheduled',
          status: {'future': true, 'scheduled_lead_minutes': 20, 'ring_at': '2026-10-25T19:10:00Z', 'rerung': false},
        ),
      );
      expect(so.state, OrderState.scheduled);
      expect(so.status.future, isTrue);
      expect(so.status.scheduledLeadMinutes, 20);
      expect(so.status.ringAt, DateTime.utc(2026, 10, 25, 19, 10));
      expect(so.status.rerung, isFalse);
      expect(so.needsLead, isFalse, reason: 'already scheduled');

      final first = _so(_online('f-2', state: 'arrived', status: {'future': true}));
      expect(first.needsLead, isTrue);
      final again = _so(_online('f-3', state: 'arrived', status: {'future': true, 'rerung': true}));
      expect(again.needsLead, isFalse);
      expect(again.status.rerung, isTrue);
    });

    test('an older order has none of them (safe defaults)', () {
      final so = _so(jsonDecode(arrivedPickupJson) as Map<String, dynamic>);
      expect(so.isPos, isFalse);
      expect(so.status.displayNumber, isNull);
      expect(so.status.flag, isNull);
      expect(so.status.future, isFalse);
      expect(so.status.boardHidden, isFalse);
      expect(so.isPaid, isTrue, reason: 'card-paid online order: nothing to collect');
    });

    test('withPool keeps the 2.1.0 fields', () {
      final so = _so(jsonDecode(posDeliveryJson) as Map<String, dynamic>);
      final pooled = so.status.withPool('d-ana');
      expect(pooled.poolDriverId, 'd-ana');
      expect(pooled.displayNumber, 99);
      expect(pooled.extSource, 'softtouch');
      expect(pooled.flag?.text, so.status.flag?.text);
      expect(pooled.cashDueCents, 2120);
    });

    test('OrderGeo: check state, up to 3 candidates, confirmed address', () {
      final g = _so(jsonDecode(posDeliveryJson) as Map<String, dynamic>).geo!;
      expect(g.state, GeoState.check);
      expect(g.needsCheck, isTrue);
      expect(g.needsPin, isTrue, reason: 'the map offers a pin while the address needs a check');
      expect(g.hasPoint, isFalse);
      expect(g.candidates, hasLength(3));
      expect(g.candidates.first.title, '12 York Rd, Towson, MD 21204');
      expect(g.candidates[1].lat, 39.4);
      expect(g.candidates[0].lat, isNull);
      expect(g.confirmedAddress!.line1, '12 York Rd');
      expect(g.confirmedAddress!.postalCode, '21204');
    });

    test('Driver.posNumber', () {
      final d = Driver.fromJson({'id': 'd-1', 'name': 'Ana', 'pos_number': '12'});
      expect(d.posNumber, '12');
      expect(Driver.fromJson({'id': 'd-2', 'name': 'Lee', 'pos_number': ''}).posNumber, isNull);
      expect(Driver.fromJson({'id': 'd-3', 'name': 'Sam'}).posNumber, isNull);
    });

    test('floor settings + integration; defaults from an older Pi', () {
      final f = Floor.fromJson({
        'batch': {'id': 7},
        'settings': {
          'features': {'pos_pull': false, 'order_insert': true, 'paid_wave': false},
          'tickets': {'pos_delivery': true, 'online_card': false},
          'times': {'default_pickup_minutes': 20, 'default_delivery_minutes': 40},
        },
        'integration': {
          'connected': true,
          'ok': false,
          'insert_mode': 'shadow',
          'insert_live': false,
          'problems': [
            {'code': 'unmapped', 'text': 'Unmapped item: Calzone', 'severity': 'warn'},
            {'code': 'link_down', 'text': 'POS link down', 'severity': 'serious'},
            {'code': 'blank', 'text': '', 'severity': 'info'},
          ],
          'last_seen_at': '2026-10-25T17:00:00Z',
        },
      });
      final s = f.settings;
      expect(s.features.posPull, isFalse);
      expect(s.features.orderInsert, isTrue);
      expect(s.features.paidWave, isFalse);
      expect(s.features.driverWriteback, isTrue, reason: 'missing key keeps its default');
      expect(s.tickets.posDelivery, isTrue);
      expect(s.tickets.onlineCard, isFalse);
      expect(s.tickets.onlineCashPickup, isTrue);
      expect(s.times.defaultPickupMinutes, 20);
      expect(s.times.defaultDeliveryMinutes, 40);
      final i = f.integration!;
      expect(i.connected, isTrue);
      expect(i.insertMode, 'shadow');
      expect(i.problems, hasLength(2), reason: 'a problem with no text is dropped');
      expect(i.serious.single.text, 'POS link down');
      expect(i.minor.single.text, 'Unmapped item: Calzone');
      expect(i.lastSeenAt, DateTime.utc(2026, 10, 25, 17));

      final old = Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>);
      expect(old.settings.features, const FeatureToggles());
      expect(old.settings.features.paidWave, isTrue);
      expect(old.settings.features.orderInsert, isFalse);
      expect(old.settings.tickets, const TicketToggles());
      expect(old.settings.times, const DefaultTimes());
      expect(old.times.forType(FulfillmentType.pickup), 15);
      expect(old.times.forType(FulfillmentType.dineIn), 15);
      expect(old.times.forType(FulfillmentType.delivery), 35);
      expect(old.integration, isNull);
    });

    test('toggles round-trip the contract keys; times out of range fall back', () {
      expect(const FeatureToggles().toJson(), {
        'pos_pull': true,
        'order_insert': false,
        'driver_writeback': true,
        'address_heal': true,
        'future_orders': true,
        'paid_wave': true,
      });
      expect(const TicketToggles().toJson(), {
        'pos_delivery': false,
        'pos_takeout': false,
        'pos_counter': false,
        'online_cash_pickup': true,
        'online_cash_delivery': true,
        'online_card': true,
      });
      expect(const FeatureToggles().withKey('paid_wave', false).paidWave, isFalse);
      expect(
        DefaultTimes.fromJson({'default_pickup_minutes': 0, 'default_delivery_minutes': 999}),
        const DefaultTimes(),
      );
      expect(Severity.parse('nope'), Severity.warn);
    });
  });

  group('floor views + SSE (2.1.0)', () {
    test('board_hidden POS counter checks never reach Kitchen', () {
      final hidden = _online('h-1', status: {'ext_source': 'softtouch', 'display_number': 50, 'board_hidden': true});
      final shown = _online('s-1', status: {'ext_source': 'softtouch', 'display_number': 51});
      final fs = _floor([_so(hidden), _so(shown)]);
      expect(fs.kitchen.map((o) => o.id), ['s-1']);
      expect(fs.kitchenByUrgency.map((o) => o.id), ['s-1']);
      expect(fs.orders.containsKey('h-1'), isTrue, reason: 'still stored');
    });

    test('with POS pull-in off, POS orders leave every floor view (still stored)', () {
      final pos = _online('p-1', status: {'ext_source': 'softtouch', 'display_number': 60});
      final web = _online('w-1');
      final fj = jsonDecode(floorJson) as Map<String, dynamic>;
      fj['settings'] = {
        'features': {'pos_pull': false},
      };
      final fs = const FloorState(connection: SseStatus.connected).withSnapshot(
        floor: Floor.fromJson(fj),
        current: [_so(pos), _so(web)],
        arrived: const [],
        drivers: const [],
        at: DateTime.now(),
      );
      expect(fs.kitchen.map((o) => o.id), ['w-1']);
      expect(fs.orders.containsKey('p-1'), isTrue);
      expect(_floor([_so(pos), _so(web)]).kitchen.map((o) => o.id).toSet(), {'p-1', 'w-1'});
    });

    test('scheduled orders sit in Later (soonest ring first), not in Kitchen or Deliveries', () {
      final a = _online('l-a', state: 'scheduled', status: {'future': true, 'ring_at': '2026-10-25T20:00:00Z'});
      final b = _online('l-b', state: 'scheduled', status: {'future': true, 'ring_at': '2026-10-25T19:00:00Z'});
      final fs = _floor([_so(a), _so(b)]);
      expect(fs.later.map((o) => o.id), ['l-b', 'l-a']);
      expect(fs.kitchen, isEmpty);
      expect(fs.arrived, isEmpty);
      expect(fs.unassignedDeliveries, isEmpty);
    });

    test('a scheduled order ringing again (rerung) comes back; a stale arrived frame does not', () {
      final fs = _floor([
        _so(_online('f-1', state: 'scheduled', status: {'future': true})),
      ]);
      final stale = applySseEvent(fs, _ev('order.arrived', _online('f-1', state: 'arrived', status: {'future': true})));
      expect(stale.state.orders['f-1']!.state, OrderState.scheduled);
      final rerung = applySseEvent(
        fs,
        _ev('order.arrived', _online('f-1', state: 'arrived', status: {'future': true, 'rerung': true})),
      );
      expect(rerung.state.orders['f-1']!.state, OrderState.arrived);
      expect(rerung.state.arrived.single.status.rerung, isTrue);
    });

    test('order.added stores the POS order; chime once per new non-hidden order', () {
      final fs = _floor(const []);
      final pos = jsonDecode(posDeliveryJson) as Map<String, dynamic>;
      final first = applySseEvent(fs, _ev('order.added', {'order': pos, 'chime': true})).state;
      expect(first.orders['pos-0001']!.isPos, isTrue);
      expect(first.chimes, 1);
      expect(first.arrived, isEmpty, reason: 'POS orders never ring');
      final replay = applySseEvent(first, _ev('order.added', {'order': pos, 'chime': true})).state;
      expect(replay.chimes, 1, reason: 'a replayed frame does not chime again');
      final quiet = applySseEvent(fs, _ev('order.added', {'order': pos, 'chime': false})).state;
      expect(quiet.chimes, 0);
      final flat = applySseEvent(fs, _ev('order.added', {...pos, 'chime': true})).state;
      expect(flat.orders['pos-0001']!.status.displayNumber, 99, reason: 'a flat StoredOrder + chime reads the same');
      expect(flat.chimes, 1);
    });

    test('settings.updated / integration.status / integration.toast', () {
      final fs = _floor(const []);
      final s = applySseEvent(
        fs,
        _ev('settings.updated', {
          'features': {'paid_wave': false},
          'tickets': {'pos_takeout': true},
          'times': {'default_pickup_minutes': 25, 'default_delivery_minutes': 45},
        }),
      ).state;
      expect(s.settings.features.paidWave, isFalse);
      expect(s.settings.tickets.posTakeout, isTrue);
      expect(s.settings.times.defaultDeliveryMinutes, 45);

      final i = applySseEvent(
        s,
        _ev('integration.status', {
          'connected': false,
          'problems': [
            {'code': 'link_down', 'text': 'POS link down', 'severity': 'serious'},
          ],
        }),
      ).state;
      expect(i.floor!.integration!.serious.single.text, 'POS link down');
      expect(i.settings.features.paidWave, isFalse, reason: 'settings kept');

      final t = applySseEvent(
        i,
        _ev('integration.toast', {'text': 'POS says #12 — not clocked in', 'severity': 'warn'}),
      );
      expect(t.state.toasts, 1);
      expect(t.state.toast!.text, 'POS says #12 — not clocked in');
    });

    test('severity decides toast vs banner', () {
      expect(displayFor(Severity.info), ProblemDisplay.toast);
      expect(displayFor(Severity.warn), ProblemDisplay.toast);
      expect(displayFor(Severity.serious), ProblemDisplay.banner);
    });

    test('paid-not-ready: paid pickups and shown POS dine-in while accepted, never once ready', () {
      final card = _so(_online('p-1'));
      expect(card.paidNotReady, isTrue, reason: 'online card pickup: nothing due');
      final ready = _so(_online('p-2', state: 'ready'));
      expect(ready.paidNotReady, isFalse);
      final cash = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
      ((cash['order'] as Map)['payments'] as List)
        ..clear()
        ..add({'method': 'cash', 'amount_cents': 2755});
      (cash['status'] as Map)['state'] = 'accepted';
      expect(_so(cash).paidNotReady, isFalse, reason: 'cash pickup not settled');
      (cash['status'] as Map)['paid'] = true;
      expect(_so(cash).paidNotReady, isTrue, reason: 'settled at the POS');
      final counter = _online('c-1', status: {'ext_source': 'softtouch', 'display_number': 7});
      ((counter['order'] as Map)['fulfillment'] as Map)['type'] = 'dine_in';
      expect(_so(counter).paidNotReady, isTrue);
      final delivery = _so(jsonDecode(posDeliveryJson) as Map<String, dynamic>);
      expect(delivery.paidNotReady, isFalse, reason: 'deliveries do not wave');
    });
  });

  group('time picker math', () {
    test('X, X+5, X+10; the third steps by 5 and never below X+10', () {
      expect(TimePickerMath.presets(15), [15, 20, 25]);
      expect(TimePickerMath.stepUp(25), 30);
      expect(TimePickerMath.stepDown(30, 15), 25);
      expect(TimePickerMath.stepDown(25, 15), 25);
      expect(TimePickerMath.stepUp(240), 240);
    });
  });

  test('setup gains a Default times step between drivers and the chime', () {
    final i = SetupStep.values.indexOf(SetupStep.times);
    expect(SetupStep.values[i - 1], SetupStep.drivers);
    expect(SetupStep.values[i + 1], SetupStep.chime);
    expect(SetupStep.times.label, 'Default times');
  });

  group('agent calls (2.1.0)', () {
    late List<http.Request> sent;
    late http.Response Function(http.Request) answer;

    AgentClient client() => AgentClient(
      baseUrl: 'http://10.0.0.5:8080',
      deviceKey: 'qagt_k',
      client: MockClient((req) async {
        sent.add(req);
        return answer(req);
      }),
    );

    setUp(() {
      sent = [];
      answer = (req) => http.Response('{}', 200, headers: {'content-type': 'application/json'});
    });

    test('schedule, geo choose', () async {
      answer = (req) => http.Response(
        jsonEncode(_online('f-1', state: 'scheduled', status: {'future': true, 'scheduled_lead_minutes': 25})),
        200,
        headers: {'content-type': 'application/json'},
      );
      final o = await client().schedule('f-1', 25);
      expect(o!.state, OrderState.scheduled);
      expect(sent.last.method, 'POST');
      expect(sent.last.url.path, '/api/orders/f-1/schedule');
      expect(jsonDecode(sent.last.body), {'lead_minutes': 25});

      answer = (req) => http.Response('', 202);
      await client().chooseGeo('pos-0001', 1);
      expect(sent.last.url.path, '/api/orders/pos-0001/geo/choose');
      expect(jsonDecode(sent.last.body), {'index': 1});
    });

    test('settings GET / PUT', () async {
      answer = (req) => http.Response(
        req.method == 'GET' ? jsonEncode({'paid_wave': false}) : req.body,
        200,
        headers: {'content-type': 'application/json'},
      );
      expect((await client().getFeatures()).paidWave, isFalse);
      expect(sent.last.url.path, '/api/settings/features');
      final f = await client().putFeatures(const FeatureToggles(orderInsert: true));
      expect(f.orderInsert, isTrue);
      expect(sent.last.method, 'PUT');
      expect(jsonDecode(sent.last.body), const FeatureToggles(orderInsert: true).toJson());
      await client().putTickets(const TicketToggles(posCounter: true));
      expect(sent.last.url.path, '/api/settings/tickets');
      expect((jsonDecode(sent.last.body) as Map)['pos_counter'], true);
      final t = await client().putTimes(const DefaultTimes(defaultPickupMinutes: 20, defaultDeliveryMinutes: 40));
      expect(sent.last.url.path, '/api/settings/times');
      expect(jsonDecode(sent.last.body), {'default_pickup_minutes': 20, 'default_delivery_minutes': 40});
      expect(t.defaultDeliveryMinutes, 40);
    });

    test('an older Pi without the routes → settings_unsupported', () async {
      answer = (req) => http.Response('404 page not found', 404);
      await expectLater(
        client().getTimes(),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', kSettingsUnsupported)),
      );
      answer = (req) => http.Response('', 405);
      await expectLater(
        client().schedule('x', 15),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', kSettingsUnsupported)),
      );
    });

    test('driver create / update carry pos_number', () async {
      answer = (req) => http.Response(
        jsonEncode({'id': 'd-9', 'name': 'Ana', 'pos_number': '12'}),
        200,
        headers: {'content-type': 'application/json'},
      );
      final d = await client().createDriver('Ana ', posNumber: '12');
      expect(d.posNumber, '12');
      expect(jsonDecode(sent.last.body), {'name': 'Ana', 'pos_number': '12'});
      await client().createDriver('Lee');
      expect(jsonDecode(sent.last.body), {'name': 'Lee'});
      await client().updateDriver('d-9', posNumber: '7');
      expect(sent.last.method, 'PATCH');
      expect(sent.last.url.path, '/api/drivers/d-9');
      expect(jsonDecode(sent.last.body), {'pos_number': '7'});
      await client().updateDriver('d-9', name: 'Ana B', posNumber: '');
      expect(jsonDecode(sent.last.body), {'name': 'Ana B', 'pos_number': ''});
    });
  });
}
