// Quibase 1.6.0: the new-order screen (a delivery gets one big ACCEPT at the
// store's delivery default with −5 / +5 nudges and a read-only map under the
// timer; a pickup keeps X / X+5 / X+10), the larger Kitchen tickets with a
// "details" affordance, and the X-Quibase-Version header on every request
// to the agent and on the SSE stream.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/app_version.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/alert/new_order_alert.dart';
import 'package:mobile_agent/features/arrived/time_picker.dart';
import 'package:mobile_agent/features/kitchen/kitchen_pane.dart';
import 'package:mobile_agent/features/maps/delivery_map.dart';
import 'package:mobile_agent/features/maps/map_layers.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:mobile_agent/theme/quicc_type.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';

/// [delivery] / the pickup fixture as a just-arrived order (no kitchen #).
StoredOrder arrivedDelivery(String id, {Map<String, dynamic>? geo, bool withAddress = true}) {
  final m = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
  final now = DateTime.now().toUtc();
  (m['order'] as Map)
    ..['id'] = id
    ..['placed_at'] = now.subtract(const Duration(minutes: 1)).toIso8601String()
    ..remove('kitchen_order_number');
  if (!withAddress) ((m['order'] as Map)['fulfillment'] as Map).remove('address');
  m['status'] = {'state': 'arrived', 'arrival_date': now.subtract(const Duration(seconds: 40)).toIso8601String()};
  if (geo != null) m['geo'] = geo;
  return StoredOrder.fromJson(m);
}

StoredOrder arrivedPickup(String id) {
  final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  (m['order'] as Map)['id'] = id;
  (m['status'] as Map)
    ..['state'] = 'arrived'
    ..['arrival_date'] = DateTime.now().toUtc().subtract(const Duration(seconds: 30)).toIso8601String();
  return StoredOrder.fromJson(m);
}

/// Records accepts instead of calling the Pi.
class _AlertFloor extends FakeDeliveryFloor {
  _AlertFloor(super.initial);

  @override
  Future<StoredOrder> accept(String id, int? prepMinutes) async {
    calls.add((op: 'accept', ids: [id], driver: null, extra: {'prep': prepMinutes}));
    throw const AgentException('Printer offline', statusCode: 502);
  }
}

FloorState _withArrived(List<StoredOrder> arrived, {Map<String, Object?>? settings}) {
  final base = deliveryFloor(floorExtra: settings == null ? null : {'settings': settings});
  return base.withSnapshot(
    floor: base.floor!,
    current: base.orders.values.where((o) => o.state != OrderState.arrived).toList(),
    arrived: arrived,
    drivers: base.drivers,
    at: DateTime.now(),
  );
}

/// Pumps the alert the way the app does: in MaterialApp.builder, above the
/// Navigator — no Overlay ancestor (a Tooltip there would throw).
Future<(ProviderContainer, _AlertFloor)> pumpAlert(
  WidgetTester tester,
  FloorState floor, {
  MapSource? map = const MapSource(url: 'http://pi:8080/api/map.pmtiles', version: '1'),
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = _AlertFloor(floor);
  final c = await deliveryContainer(fake, map: map);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(body: SizedBox.expand()),
        builder: (context, child) => Stack(
          children: [
            Positioned.fill(child: child!),
            const Positioned.fill(child: NewOrderAlert()),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  return (c, fake);
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

String _acceptLabel(WidgetTester tester) {
  final b = find.byKey(const ValueKey('accept-confirm'));
  return tester.widgetList<Text>(find.descendant(of: b, matching: find.byType(Text))).map((t) => t.data).join();
}

bool _nudgeEnabled(WidgetTester tester, String key) =>
    tester
        .widget<OutlinedButton>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(OutlinedButton)))
        .onPressed !=
    null;

void main() {
  group('nudge math', () {
    test('−5 floors at 5, +5 caps at 240', () {
      expect(TimePickerMath.nudgeDown(35), 30);
      expect(TimePickerMath.nudgeDown(8), 5);
      expect(TimePickerMath.nudgeDown(5), 5);
      expect(TimePickerMath.nudgeUp(35), 40);
      expect(TimePickerMath.nudgeUp(238), 240);
      expect(TimePickerMath.nudgeUp(240), 240);
    });
  });

  group('new-order screen: delivery', () {
    testWidgets('one big ACCEPT at the delivery default, −5 / +5 nudges, no X / X+5 / X+10', (tester) async {
      final so = arrivedDelivery('a-d1', geo: locatedGeo());
      final (_, f) = await pumpAlert(tester, _withArrived([so]));
      expect(tester.takeException(), isNull);
      expect(find.text('New order'), findsOneWidget);
      expect(_acceptLabel(tester), 'ACCEPT · 35 MIN');
      for (final k in ['pick-x', 'pick-x5', 'pick-x10', 'pick-minus', 'pick-plus', 'time-picker']) {
        expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
      }
      expect(find.byKey(const ValueKey('nudge-minus')), findsOneWidget);
      expect(find.byKey(const ValueKey('nudge-plus')), findsOneWidget);
      // ACCEPT is the big one; the nudges sit beside it, smaller.
      final accept = tester.getRect(find.byKey(const ValueKey('accept-confirm')));
      final minus = tester.getRect(find.byKey(const ValueKey('nudge-minus')));
      final plus = tester.getRect(find.byKey(const ValueKey('nudge-plus')));
      expect(accept.height, greaterThanOrEqualTo(96));
      expect(minus.width, lessThan(accept.width / 2));
      expect(minus.right, lessThanOrEqualTo(accept.left));
      expect(plus.left, greaterThanOrEqualTo(accept.right));

      await tester.tap(find.byKey(const ValueKey('nudge-plus')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nudge-plus')));
      await tester.pump();
      expect(_acceptLabel(tester), 'ACCEPT · 45 MIN');
      expect(find.text('Delivery time — store default 35 min'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('nudge-minus')));
        await tester.pump();
      }
      expect(_acceptLabel(tester), 'ACCEPT · 30 MIN');

      // The error stays inline (no dialog / snackbar above the navigator).
      await tester.tap(find.byKey(const ValueKey('accept-confirm')));
      await tester.pump();
      await tester.pump();
      expect(callsOf(f, 'accept').single.extra['prep'], 30);
      expect(find.textContaining('Printer problem'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      await _done(tester);
    });

    testWidgets('the nudges stop at 5 and at 240', (tester) async {
      final so = arrivedDelivery('a-d2', geo: locatedGeo());
      await pumpAlert(
        tester,
        _withArrived(
          [so],
          settings: {
            'times': {'default_pickup_minutes': 15, 'default_delivery_minutes': 10},
          },
        ),
      );
      expect(_acceptLabel(tester), 'ACCEPT · 10 MIN');
      await tester.tap(find.byKey(const ValueKey('nudge-minus')));
      await tester.pump();
      expect(_acceptLabel(tester), 'ACCEPT · 5 MIN');
      expect(_nudgeEnabled(tester, 'nudge-minus'), isFalse);
      await _done(tester);

      await pumpAlert(
        tester,
        _withArrived(
          [so],
          settings: {
            'times': {'default_delivery_minutes': 235},
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nudge-plus')));
      await tester.pump();
      expect(_acceptLabel(tester), 'ACCEPT · 240 MIN');
      expect(_nudgeEnabled(tester, 'nudge-plus'), isFalse);
      await _done(tester);
    });

    testWidgets('a read-only map under the timer: store, door, route, label, tags; nothing to touch', (tester) async {
      final so = arrivedDelivery('a-d3', geo: locatedGeo(quality: 'approx', outside: true));
      await pumpAlert(tester, _withArrived([so]));
      expect(tester.takeException(), isNull);
      final map = find.byType(StaticDeliveryMap);
      expect(map, findsOneWidget);
      expect(find.descendant(of: map, matching: find.byType(FlutterMap)), findsOneWidget);
      expect(find.byKey(stubTilesKey), findsOneWidget);
      expect(find.descendant(of: map, matching: find.byType(PolylineLayer)), findsOneWidget);
      expect(find.descendant(of: map, matching: find.byIcon(Icons.storefront)), findsOneWidget);
      expect(find.descendant(of: map, matching: find.byIcon(Icons.location_on)), findsOneWidget);
      expect(find.text('2.3 mi · 7 min'), findsOneWidget);
      expect(find.text('approx'), findsOneWidget);
      expect(find.text('outside area'), findsOneWidget);
      // No buttons, no tooltips, no gestures.
      expect(find.descendant(of: map, matching: find.byType(IconButton)), findsNothing);
      expect(find.descendant(of: map, matching: find.byType(Tooltip)), findsNothing);
      expect(find.descendant(of: map, matching: find.byType(IgnorePointer)), findsWidgets);
      final fm = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(fm.options.interactionOptions.flags, InteractiveFlag.none);
      expect(fm.options.onTap, isNull);
      // Fixed height, right under the waiting timer line.
      final rect = tester.getRect(find.byKey(const ValueKey('static-map')));
      expect(rect.height, kStaticMapHeight);
      final waiting = tester.getRect(find.textContaining('waiting', findRichText: true));
      expect(rect.top, greaterThan(waiting.bottom));
      expect(rect.top - waiting.bottom, lessThan(24));
      // Tapping it does nothing (and doesn't throw without an Overlay).
      await tester.tapAt(rect.center);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(StaticDeliveryMap), findsOneWidget);
      await _done(tester);
    });

    testWidgets('no geo yet → one slim "locating" line; not found → a slim note', (tester) async {
      await pumpAlert(tester, _withArrived([arrivedDelivery('a-d4')]));
      expect(find.byKey(const ValueKey('static-map-locating')), findsOneWidget);
      expect(find.text('Locating address…'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      expect(tester.getSize(find.byType(StaticDeliveryMap)).height, lessThan(40));
      await _done(tester);

      await pumpAlert(
        tester,
        _withArrived([
          arrivedDelivery('a-d5', geo: const {'state': 'not_found'}),
        ]),
      );
      expect(find.byKey(const ValueKey('static-map-lost')), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      await _done(tester);
    });

    testWidgets('no map file on the Pi → the distance on one line, with tags', (tester) async {
      await pumpAlert(tester, _withArrived([arrivedDelivery('a-d6', geo: locatedGeo(outside: true))]), map: null);
      expect(find.byKey(const ValueKey('static-map-nofile')), findsOneWidget);
      expect(find.text('Store → door: 2.3 mi · 7 min'), findsOneWidget);
      expect(find.text('outside area'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      await _done(tester);
    });

    testWidgets('a delivery without an address shows no map', (tester) async {
      await pumpAlert(tester, _withArrived([arrivedDelivery('a-d7', withAddress: false)]));
      expect(find.byType(StaticDeliveryMap), findsNothing);
      expect(_acceptLabel(tester), 'ACCEPT · 35 MIN');
      await _done(tester);
    });

    testWidgets('fits a 960×600 tablet without overflow', (tester) async {
      await pumpAlert(
        tester,
        _withArrived([arrivedDelivery('a-d8', geo: locatedGeo()), arrivedPickup('a-p9')]),
        size: const Size(960, 600),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(StaticDeliveryMap), findsOneWidget);
      await _done(tester);
    });
  });

  group('new-order screen: pickup', () {
    testWidgets('unchanged: X / X+5 / X+10 with steppers, no map, no nudges', (tester) async {
      await pumpAlert(tester, _withArrived([arrivedPickup('a-p1')]));
      expect(tester.takeException(), isNull);
      for (final k in ['pick-x', 'pick-x5', 'pick-x10', 'pick-minus', 'pick-plus']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.byKey(const ValueKey('nudge-minus')), findsNothing);
      expect(find.byType(StaticDeliveryMap), findsNothing);
      expect(_acceptLabel(tester), 'ACCEPT · 15 MIN');
      await _done(tester);
    });

    testWidgets('a future delivery keeps the lead-time picker', (tester) async {
      final m = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
      (m['order'] as Map)
        ..['id'] = 'a-f1'
        ..remove('kitchen_order_number');
      ((m['order'] as Map)['fulfillment'] as Map)['promised_at'] = '2030-01-01T20:00:00Z';
      m['status'] = {'state': 'arrived', 'future': true, 'arrival_date': DateTime.now().toUtc().toIso8601String()};
      await pumpAlert(tester, _withArrived([StoredOrder.fromJson(m)]));
      expect(find.byKey(const ValueKey('time-picker')), findsOneWidget);
      expect(find.byKey(const ValueKey('nudge-plus')), findsNothing);
      expect(_acceptLabel(tester), 'CONFIRM · 35 MIN BEFORE');
      await _done(tester);
    });
  });

  group('Kitchen tickets', () {
    Future<void> pumpKitchen(WidgetTester tester, List<StoredOrder> orders) async {
      tester.view.physicalSize = const Size(1280 - 104, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final base = deliveryFloor();
      final f = FakeDeliveryFloor(
        base.withSnapshot(
          floor: base.floor!,
          current: orders,
          arrived: const [],
          drivers: base.drivers,
          at: DateTime.now(),
        ),
      );
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: const Scaffold(body: KitchenPane()),
          ),
        ),
      );
      await tester.pump();
    }

    List<StoredOrder> cooking(int n) => [
      for (var i = 0; i < n; i++)
        delivery('k$i', 1101 + i, state: 'accepted', readyInMinutes: 10 + i, placedMinutesAgo: 5 + i),
    ];

    testWidgets('three columns on the 1280×800 tablet (about 6 on screen), big mono numbers', (tester) async {
      await pumpKitchen(tester, cooking(7));
      expect(tester.takeException(), isNull);
      final cards = find.byType(KitchenCard);
      final lefts = {for (var i = 0; i < cards.evaluate().length; i++) tester.getTopLeft(cards.at(i)).dx.round()};
      expect(lefts, hasLength(3));
      final w = tester.getSize(find.byType(KitchenCard).first).width;
      expect(w, greaterThanOrEqualTo(kTicketWidth));
      // The kitchen # and the timer in JetBrains Mono at display / title size.
      final number = tester.widget<Text>(find.text('1101'));
      expect(number.style!.fontFamily, QuiccType.mono);
      expect(number.style!.fontSize, QuiccType.display);
      final timer = tester.widget<Text>(find.byKey(const ValueKey('ticket-timer')).first);
      expect(timer.style!.fontFamily, QuiccType.mono);
      expect(timer.style!.fontSize, QuiccType.title);
      await _done(tester);
    });

    testWidgets('each ticket shows a details chevron; tapping the ticket opens the order', (tester) async {
      await pumpKitchen(tester, cooking(2));
      expect(find.byKey(const ValueKey('ticket-details')), findsNWidgets(2));
      await tester.tap(find.text('1101'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(OrderDetailScreen), findsOneWidget);
      await _done(tester);
    });
  });

  group('X-Quibase-Version', () {
    test('version string', () {
      expect(quibaseVersionString('1.6.0', 160), '1.6.0+160');
      expect(quibaseVersionString('1.6.0', '160'), '1.6.0+160');
      expect(quibaseVersionString('1.6.0', null), '1.6.0');
      expect(quibaseVersionString('', 160), '');
    });

    test('every AgentClient request carries it (and none while unknown)', () async {
      final seen = <http.BaseRequest>[];
      final mock = MockClient((req) async {
        seen.add(req);
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      });
      final c = AgentClient(
        baseUrl: 'http://10.0.0.5:8080',
        deviceKey: 'k',
        client: mock,
        appVersion: () => '1.6.0+160',
      );
      await c.getFloor().catchError((Object _) => Floor.fromJson(const {}));
      await c.ready('o1').catchError((Object _) => StoredOrder.fromJson(const {}));
      expect(seen, hasLength(2));
      for (final r in seen) {
        expect(r.headers[kQuibaseVersionHeader], '1.6.0+160');
        expect(r.headers[kDeviceKeyHeader], 'k');
      }

      seen.clear();
      final unknown = AgentClient(
        baseUrl: 'http://10.0.0.5:8080',
        deviceKey: 'k',
        client: mock,
        appVersion: () => null,
      );
      await unknown.getFloor().catchError((Object _) => Floor.fromJson(const {}));
      expect(seen.single.headers.containsKey(kQuibaseVersionHeader), isFalse);
    });

    test('the open pairing / probe calls carry the installed version', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      QuibaseVersion.debugSet('1.6.0+161');
      addTearDown(() => QuibaseVersion.debugSet(null));
      final seen = <http.BaseRequest>[];
      final mock = MockClient((req) async {
        seen.add(req);
        return http.Response('{"key":"qagt_x","device_id":"d"}', 200);
      });
      await AgentClient.pair(address: '10.0.0.5', code: '123456', name: 'Counter', client: mock);
      await AgentClient.version(address: '10.0.0.5', client: mock);
      expect(seen, hasLength(2));
      for (final r in seen) {
        expect(r.headers[kQuibaseVersionHeader], '1.6.0+161');
      }
    });

    test('read from the install channel: versionName + versionCode', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const ch = MethodChannel('quibase/install');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        ch,
        (call) async => call.method == 'version' ? {'versionName': '1.6.0', 'versionCode': 162} : null,
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
        QuibaseVersion.debugSet(null);
      });
      QuibaseVersion.debugSet(null);
      // Allow the lookup again (debugSet pauses it).
      QuibaseVersion.debugAllowLookup();
      expect(QuibaseVersion.current, isNull, reason: 'not known yet: the first request goes without');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(QuibaseVersion.current, '1.6.0+162');
    });

    test('the /api/events stream sends it on connect', () async {
      final got = Completer<http.BaseRequest>();
      final stream = AgentEventStream(
        baseUrl: 'http://10.0.0.5:8080',
        deviceKey: 'k',
        onEvent: (_) {},
        onStatus: (_) {},
        onConnected: () {},
        onDeviceRevoked: () {},
        appVersion: () => '1.6.0+160',
        clientFactory: () => MockClient.streaming((req, body) async {
          if (!got.isCompleted) got.complete(req);
          return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
        }),
        backoff: (_) => const Duration(hours: 1),
      );
      stream.start();
      final req = await got.future.timeout(const Duration(seconds: 5));
      stream.stop();
      expect(req.url.path, '/api/events');
      expect(req.headers[kQuibaseVersionHeader], '1.6.0+160');
      expect(req.headers[kDeviceKeyHeader], 'k');
    });
  });
}
