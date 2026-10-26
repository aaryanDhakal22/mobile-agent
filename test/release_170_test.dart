// Quibase 1.7.0 (with agent/main 2.2.0): the nearby rule behind the driver
// button's NEXT, the delivery radius + nearby settings, auto-accept from the
// tablet (and its 3 s banner), the Pi's own log in developer mode, and the
// tablets' versions from /api/diag. Every new call degrades on an older Pi.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/delivery_models.dart';
import 'package:mobile_agent/core/diag_models.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/alert/auto_accept_banner.dart';
import 'package:mobile_agent/features/drivers/next_rules.dart';
import 'package:mobile_agent/features/settings/auto_accept_card.dart';
import 'package:mobile_agent/features/settings/delivery_area_card.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';

/// A Pi answering [handler]; records each request as "METHOD path body".
(AgentClient, List<String>, List<bool>) _pi(http.Response Function(http.Request req) handler) {
  final calls = <String>[];
  final revoked = <bool>[];
  final client = AgentClient(
    baseUrl: 'http://10.0.0.5:8080',
    deviceKey: 'qagt_k',
    client: MockClient((req) async {
      calls.add('${req.method} ${req.url.path}${req.url.hasQuery ? '?${req.url.query}' : ''} ${req.body}');
      return handler(req);
    }),
    onDeviceRevoked: () => revoked.add(true),
  );
  return (client, calls, revoked);
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// The delivery floor with the 2.2.0 nearby fields.
FloorState _floor22() => deliveryFloor(
  floorExtra: {'nearby_rule': 'detour', 'nearby_detour_minutes': 5, 'nearby_distance_mi': 1.0},
);

void main() {
  group('nearbyCheck', () {
    Future<NearbyResult> run(AgentClient client) async {
      final f = FakeDeliveryFloor(_floor22());
      final c = await deliveryContainer(f, extra: [agentClientProvider.overrideWithValue(client)]);
      addTearDown(c.dispose);
      final ana = c.read(floorProvider).drivers.firstWhere((d) => d.id == 'd-ana');
      final stops = [(order: c.read(floorProvider).orders['d3']!, suggested: false)];
      return nearbyCheck(c, ana, stops);
    }

    test('the Pi names nearby deliveries: redirect with only those still unassigned', () async {
      final (client, calls, _) = _pi(
        (req) => _json({
          'driver_id': 'd-ana',
          'rule': 'detour',
          'nearby_order_ids': ['d1', 'gone'],
          'reason': '#1101 adds 3 min to Ana\'s run.',
        }),
      );
      final r = await run(client);
      expect(r.redirect, isTrue);
      expect(r.orderIds, ['d1']);
      expect(r.reason, contains('adds 3 min'));
      expect(calls.single, startsWith('GET /api/deliveries/next-check?driver_id=d-ana'));
    });

    test('an older Pi (404), an error or nothing nearby never redirects', () async {
      for (final h in <http.Response Function(http.Request)>[
        (_) => http.Response('404 page not found', 404),
        (_) => _json({'code': 'internal'}, 500),
        (_) => _json({'driver_id': 'd-ana', 'rule': 'detour', 'nearby_order_ids': <String>[], 'reason': ''}),
      ]) {
        final (client, _, _) = _pi(h);
        expect((await run(client)).redirect, isFalse);
      }
    });
  });

  group('auto-accept from the tablet', () {
    test("an older Pi's 401 device_required means 'not here' — it never unpairs the tablet", () async {
      final (client, _, revoked) = _pi((_) => _json({'code': 'device_required', 'error': 'log in'}, 401));
      expect(await client.autoAccept(), isNull);
      expect(revoked, isEmpty, reason: 'the web-UI-only route must not look like a revoked device');
    });

    test('GET / PUT round trip', () async {
      var on = false;
      final (client, calls, _) = _pi((req) {
        if (req.method == 'PUT') on = (jsonDecode(req.body) as Map)['auto_accept'] as bool;
        return _json({'auto_accept': on});
      });
      expect(await client.autoAccept(), isFalse);
      expect(await client.setAutoAccept(true), isTrue);
      expect(calls.last, 'PUT /api/settings/auto-accept {"auto_accept":true}');
    });

    testWidgets('the card asks before turning it on', (tester) async {
      var on = false;
      final (client, _, _) = _pi((req) {
        if (req.method == 'PUT') on = (jsonDecode(req.body) as Map)['auto_accept'] as bool;
        return _json({'auto_accept': on});
      });
      final c = await deliveryContainer(FakeDeliveryFloor(_floor22()), extra: [agentClientProvider.overrideWithValue(client)]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: SingleChildScrollView(child: AutoAcceptCard()))),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-accept-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Turn on auto-accept?'), findsOneWidget);
      await tester.tap(find.text('TURN ON'));
      await tester.pumpAndSettle();
      expect(on, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('auto-accepted orders', () {
    SseEvent updated(StoredOrder o, {bool auto = true}) {
      final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
      (m['order'] as Map)['id'] = o.id;
      (m['status'] as Map)
        ..['state'] = 'accepted'
        ..['kitchen_number'] = 1104
        ..['prep_minutes'] = 15
        ..['auto_accepted'] = auto;
      return SseEvent('order.updated', jsonEncode(m));
    }

    test('a new auto-accepted order chimes and bumps the banner once; a replay does not', () {
      const s0 = FloorState(connection: SseStatus.connected);
      final m0 = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
      (m0['order'] as Map)['id'] = 'a-1';
      final o = StoredOrder.fromJson(m0);
      final s1 = applySseEvent(s0, updated(o)).state;
      expect(s1.autoAccepts, 1);
      expect(s1.chimes, 1);
      expect(s1.autoAccepted, 'a-1');
      final s2 = applySseEvent(s1, updated(o)).state;
      expect(s2.autoAccepts, 1, reason: 'already seen accepted');
      final s3 = applySseEvent(s0, updated(o, auto: false)).state;
      expect(s3.autoAccepts, 0, reason: 'accepted by staff');
    });

    testWidgets('the banner shows for 3 s, then goes', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = FakeDeliveryFloor(_floor22());
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: Stack(children: [AutoAcceptBanner()]))),
        ),
      );
      final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
      (m['order'] as Map)['id'] = 'auto-1';
      (m['status'] as Map)
        ..['state'] = 'accepted'
        ..['kitchen_number'] = 1104
        ..['prep_minutes'] = 15
        ..['auto_accepted'] = true;
      f.push(applySseEvent(f.state, SseEvent('order.updated', jsonEncode(m))).state);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('auto-accept-banner')), findsOneWidget);
      expect(find.text('#1104 auto-accepted · 15 min'), findsOneWidget);
      await tester.pump(kAutoAcceptBannerTime);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('auto-accept-banner')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('delivery area and nearby settings', () {
    testWidgets('save sends the nearby rule, and the radius only when it moved; main offline says why', (
      tester,
    ) async {
      final f = FakeDeliveryFloor(_floor22());
      final c = await deliveryContainer(
        f,
        prefs: const {'agent_address': 'http://10.0.0.5:8080', 'device_key': 'qagt_k', 'device_name': 'Counter'},
      );
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: const Scaffold(body: SingleChildScrollView(child: DeliveryAreaCard())),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('5.0 mi'), findsOneWidget, reason: '8047 m');

      await tester.tap(find.text('Distance'));
      await tester.pump();
      expect(find.byKey(const ValueKey('nearby-distance')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delivery-area-save')));
      await tester.pumpAndSettle();
      final first = callsOf(f, 'settings').single.extra;
      expect(first['nearby_rule'], 'distance');
      expect(first.containsKey('delivery_radius_m'), isFalse, reason: 'radius untouched');
      expect(c.read(floorProvider).floor!.nearbyRule, NearbyRule.distance);

      // Move the radius; main is offline: nothing saved, plain words.
      f.settingsError = const AgentException('main offline', statusCode: 503, code: 'main_offline');
      final slider = find.byKey(const ValueKey('radius-slider'));
      await tester.tapAt(tester.getCenter(slider) + const Offset(80, 0));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delivery-area-save')));
      await tester.pumpAndSettle();
      expect(callsOf(f, 'settings').last.extra['delivery_radius_m'], isA<int>());
      expect(find.textContaining("couldn't reach the Quicc website"), findsOneWidget);
      expect(c.read(floorProvider).floor!.store!.deliveryRadiusM, 8047, reason: 'unchanged');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('wire shapes', () {
    test('NextCheck, PiEvent, DiagTablet and DeliverySettings', () {
      final n = NextCheck.fromJson({'driver_id': 'd1', 'rule': 'bundle', 'nearby_order_ids': ['a'], 'reason': 'x'});
      expect((n.redirect, n.rule), (true, NearbyRule.bundle));
      final e = PiEvent.fromJson({'seq': 7, 'at': '2026-10-26T12:00:00Z', 'level': 'warn', 'kind': 'print', 'text': 'x'});
      expect((e.seq, e.level, e.kind), (7, 'warn', 'print'));
      final d = PiDiag.fromJson({
        'version': '2.2.0',
        'tablets': [
          {'device_id': 't1', 'name': 'Counter', 'app_version': '1.7.0+1', 'connected': true},
        ],
      });
      expect(d.tablets.single.appVersion, '1.7.0+1');
      expect(
        const DeliverySettings(soonReadyMinutes: 5, deliveryTargetMinutes: 45).toJson().keys,
        ['soon_ready_minutes', 'delivery_target_minutes'],
        reason: 'an older Pi only gets the fields it knows',
      );
      expect(Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>).nearbyRule, isNull, reason: 'older Pi');
    });
  });
}
