// Quibase 1.7.2: an address main couldn't find gets plain "Not found on the
// map" text with SEARCH ADDRESS (type it again → the Pi's geo/search → the
// candidates, or "No match") and PLACE PIN (the pin mode, with a clear
// instruction), and the new `corrected` geo tag.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/features/maps/delivery_map.dart';
import 'package:mobile_agent/features/maps/geo_format.dart';
import 'package:mobile_agent/features/maps/map_layers.dart';
import 'package:mobile_agent/features/maps/search_address_sheet.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/settings/pos_settings_cards.dart';

import 'delivery_fixtures.dart';

/// The fake floor plus SEARCH ADDRESS and the candidate choice.
class _SearchFloor extends FakeDeliveryFloor {
  _SearchFloor(super.initial);

  /// The next search throws this.
  AgentException? searchError;

  /// Applied to the floor before the search answers (main was quick).
  StoredOrder? answerFirst;

  @override
  Future<void> searchGeo(String orderId, String query) async {
    calls.add((op: 'search', ids: [orderId], driver: null, extra: {'query': query}));
    if (searchError != null) throw searchError!;
    if (answerFirst != null) push(state.withOrder(answerFirst!));
  }

  @override
  Future<void> chooseGeo(String orderId, int index) async {
    calls.add((op: 'choose', ids: [orderId], driver: null, extra: {'index': index}));
  }
}

const _street = '1613 Wadsworth Way, HOUSE';

StoredOrder _lost({String state = 'not_found', String? updatedAt}) =>
    delivery('s1', 1201, street: _street, geo: {'state': state, 'updated_at': ?updatedAt});

/// Main's answer: two places to pick from.
StoredOrder _candidates() => delivery(
  's1',
  1201,
  street: _street,
  geo: const {
    'state': 'check',
    'updated_at': '2026-10-26T22:00:05Z',
    'candidates': [
      {'label': '1613 Wadsworth Way, Towson, MD 21286'},
      {'label': '1613 Wadsworth Rd, Parkville, MD 21234'},
    ],
  },
);

Future<_SearchFloor> _pump(WidgetTester tester, StoredOrder order, {MapSource? map = _map}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final f = _SearchFloor(deliveryFloor().withOrder(order));
  final c = await deliveryContainer(f, map: map);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(width: 560, child: DeliveryMap(order: order)),
        ),
      ),
    ),
  );
  await tester.pump();
  return f;
}

const _map = MapSource(url: 'http://pi:8080/api/map.pmtiles', version: '1');

Future<void> _openSearch(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('search-address')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _tapSearch(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('search-go')));
  await tester.pump();
}

void main() {
  group('geo corrected', () {
    test('parses (absent = false)', () {
      expect(OrderGeo.fromJson(const {'state': 'located', 'corrected': true}).corrected, isTrue);
      expect(OrderGeo.fromJson(const {'state': 'located'}).corrected, isFalse);
      expect(OrderGeo.fromJson(const {'state': 'located', 'corrected': false}).corrected, isFalse);
    });

    testWidgets('a small "address corrected" tag on the order map and the delivery rows', (tester) async {
      final geo = {...locatedGeo(), 'corrected': true};
      await _pump(tester, delivery('s1', 1201, geo: geo));
      expect(find.text('address corrected'), findsOneWidget);
      expect(find.text('approximate location'), findsNothing);
      await tester.pumpWidget(const SizedBox());

      final tags = geoTags(OrderGeo.fromJson(geo));
      expect(tags.whereType<GeoTag>().map((t) => t.text), ['address corrected']);
      expect(geoTags(OrderGeo.fromJson(locatedGeo())), isEmpty);
    });
  });

  test('the search starts from the street part of the address', () {
    expect(searchPrefill(const Address(line1: '1613 Wadsworth Way, HOUSE')), '1613 Wadsworth Way');
    expect(searchPrefill(const Address(line1: '  931 Taylor Ave ')), '931 Taylor Ave');
    expect(searchPrefill(const Address(city: 'Towson', state: 'MD')), 'Towson');
    expect(searchPrefill(null), '');
  });

  group('not found on the order map', () {
    testWidgets('plain text plus SEARCH ADDRESS and PLACE PIN; the text is no button', (tester) async {
      await _pump(tester, _lost());
      expect(find.byKey(const ValueKey('lost-title')), findsOneWidget);
      expect(find.text('Not found on the map'), findsOneWidget);
      expect(
        find.ancestor(of: find.byKey(const ValueKey('lost-title')), matching: find.byType(ButtonStyleButton)),
        findsNothing,
      );
      expect(find.ancestor(of: find.byKey(const ValueKey('lost-title')), matching: find.byType(InkWell)), findsNothing);
      expect(find.text('SEARCH ADDRESS'), findsOneWidget);
      expect(find.text('PLACE PIN'), findsOneWidget);
      expect(find.textContaining('tap to place pin'), findsNothing);
      expect(find.byKey(const ValueKey('pin-banner')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('PLACE PIN → "Tap the map where the door is" → SAVE PIN; ✕ cancels', (tester) async {
      final f = await _pump(tester, _lost());
      await tester.tap(find.byKey(const ValueKey('place-pin')));
      await tester.pump();
      expect(find.text('Tap the map where the door is'), findsOneWidget);
      expect(find.text('SEARCH ADDRESS'), findsNothing, reason: 'the buttons step aside while pinning');
      expect(find.byKey(const ValueKey('cancel-pin')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cancel-pin')));
      await tester.pump();
      expect(find.text('Tap the map where the door is'), findsNothing);
      expect(find.text('SEARCH ADDRESS'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('place-pin')));
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)) + const Offset(30, 20));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Is the pin on the door? Tap again to move it.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-pin')));
      await tester.pump();
      expect(callsOf(f, 'pin').single.ids, ['s1']);
      expect(find.text('Pin saved'), findsOneWidget);
      expect(find.text('SEARCH ADDRESS'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no map file on the Pi: SEARCH ADDRESS only', (tester) async {
      await _pump(tester, _lost(), map: null);
      expect(find.text('SEARCH ADDRESS'), findsOneWidget);
      expect(find.byKey(const ValueKey('place-pin')), findsNothing);
      await _openSearch(tester);
      expect(find.byKey(const ValueKey('search-place-pin')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a located order keeps its pin button, no SEARCH / PLACE PIN', (tester) async {
      await _pump(tester, delivery('s1', 1201, geo: locatedGeo()));
      expect(find.text('SEARCH ADDRESS'), findsNothing);
      expect(find.byKey(const ValueKey('place-pin')), findsNothing);
      expect(find.byTooltip('Wrong spot? Place a pin'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the order detail screen shows the two buttons for a not-found delivery', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final o = _lost();
      final c = await deliveryContainer(_SearchFloor(deliveryFloor().withOrder(o)));
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: OrderDetailScreen(orderId: o.id, initial: o),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('search-address'), skipOffstage: false), findsOneWidget);
      expect(find.byKey(const ValueKey('place-pin'), skipOffstage: false), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('SEARCH ADDRESS sheet', () {
    testWidgets('prefilled → SEARCH → searching… → the candidates → choose one', (tester) async {
      final f = await _pump(tester, _lost(updatedAt: '2026-10-26T21:50:00Z'));
      await _openSearch(tester);
      expect(find.text('Search the address · 1201'), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('search-query')));
      expect(field.controller!.text, '1613 Wadsworth Way');

      await tester.enterText(find.byKey(const ValueKey('search-query')), '1613 Wadsworth Wy');
      await _tapSearch(tester);
      expect(callsOf(f, 'search').single.extra['query'], '1613 Wadsworth Wy');
      expect(find.text(SearchAddressText.searching), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      f.push(f.state.withOrder(_candidates()));
      await tester.pump();
      expect(find.text(SearchAddressText.searching), findsNothing);
      expect(find.text('1613 Wadsworth Way, Towson, MD 21286'), findsOneWidget);
      expect(find.text('1613 Wadsworth Rd, Parkville, MD 21234'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('candidate-1')));
      await tester.pump();
      expect(callsOf(f, 'choose').single.extra['index'], 1);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SearchAddressSheet), findsNothing);
      expect(find.text('Address chosen — the route shows in a moment'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('main answered before the 202 came back: the candidates still show', (tester) async {
      final f = await _pump(tester, _lost());
      f.answerFirst = _candidates();
      await _openSearch(tester);
      await _tapSearch(tester);
      await tester.pump();
      expect(find.text(SearchAddressText.searching), findsNothing);
      expect(find.byKey(const ValueKey('candidate-0')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pending first, then not found again → "No match", PLACE PIN starts the pin', (tester) async {
      final f = await _pump(tester, _lost(updatedAt: '2026-10-26T21:50:00Z'));
      await _openSearch(tester);
      await _tapSearch(tester);
      f.push(f.state.withOrder(_lost(state: 'pending', updatedAt: '2026-10-26T22:00:00Z')));
      await tester.pump();
      expect(find.text(SearchAddressText.searching), findsOneWidget, reason: 'still looking');
      f.push(f.state.withOrder(_lost(updatedAt: '2026-10-26T22:00:04Z')));
      await tester.pump();
      expect(find.text(SearchAddressText.noMatch), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.byKey(const ValueKey('search-place-pin')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SearchAddressSheet), findsNothing);
      expect(find.text('Tap the map where the door is'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('located right away → the sheet closes', (tester) async {
      final f = await _pump(tester, _lost());
      await _openSearch(tester);
      await _tapSearch(tester);
      f.push(f.state.withOrder(delivery('s1', 1201, street: _street, geo: {...locatedGeo(), 'corrected': true})));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SearchAddressSheet), findsNothing);
      expect(find.text(SearchAddressText.found), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no answer in 20 s → "No match"', (tester) async {
      await _pump(tester, _lost());
      await _openSearch(tester);
      await _tapSearch(tester);
      await tester.pump(const Duration(seconds: 19));
      expect(find.text(SearchAddressText.searching), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(SearchAddressText.searching), findsNothing);
      expect(find.text(SearchAddressText.noMatch), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an empty search asks for a street and number (nothing sent)', (tester) async {
      final f = await _pump(tester, _lost());
      await _openSearch(tester);
      await tester.enterText(find.byKey(const ValueKey('search-query')), '   ');
      await _tapSearch(tester);
      expect(find.text(SearchAddressText.badQuery), findsOneWidget);
      expect(callsOf(f, 'search'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    for (final (code, text) in [
      (kBadQuery, SearchAddressText.badQuery),
      (kMainOffline, SearchAddressText.mainOffline),
    ]) {
      testWidgets('error $code → "$text", SEARCH again', (tester) async {
        final f = await _pump(tester, _lost());
        f.searchError = AgentException('x', statusCode: code == kBadQuery ? 400 : 503, code: code);
        await _openSearch(tester);
        await _tapSearch(tester);
        await tester.pump();
        expect(find.text(text), findsOneWidget);
        expect(find.text(SearchAddressText.searching), findsNothing);
        final go = tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('search-go')));
        expect(go.onPressed, isNotNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('an older Pi → "needs an update", SEARCH off, PLACE PIN instead', (tester) async {
      final f = await _pump(tester, _lost());
      f.searchError = const AgentException('x', statusCode: 405, code: kGeoSearchUnsupported);
      await _openSearch(tester);
      await _tapSearch(tester);
      await tester.pump();
      expect(find.text(SearchAddressText.unsupported), findsOneWidget);
      final go = tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('search-go')));
      expect(go.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('search-place-pin')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Tap the map where the door is'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('AgentClient.searchGeo', () {
    late List<http.Request> sent;
    late List<bool> revoked;
    late http.Response Function(http.Request) answer;
    AgentClient client() => AgentClient(
      baseUrl: 'http://10.0.0.5:8080',
      deviceKey: 'qagt_k',
      client: MockClient((req) async {
        sent.add(req);
        return answer(req);
      }),
      onDeviceRevoked: () => revoked.add(true),
    );
    http.Response json(Object body, int status) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    setUp(() {
      sent = [];
      revoked = [];
    });

    test('POST /api/orders/{id}/geo/search {query} → 202', () async {
      answer = (_) => http.Response('{}', 202);
      await client().searchGeo('o 1', ' 1613 Wadsworth Way ');
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, '/api/orders/o%201/geo/search');
      expect(jsonDecode(sent.single.body), {'query': '1613 Wadsworth Way'});
    });

    Future<AgentException> fails() async {
      try {
        await client().searchGeo('o1', 'x');
      } on AgentException catch (e) {
        return e;
      }
      fail('expected an AgentException');
    }

    test('error codes', () async {
      answer = (_) => json({'error': 'bad_query'}, 400);
      expect((await fails()).code, kBadQuery);
      answer = (_) => json({'error': 'Bad query', 'code': 'bad_query'}, 400);
      expect((await fails()).code, kBadQuery);
      answer = (_) => json({'error': "Can't reach the server — try again.", 'code': 'main_offline'}, 503);
      expect((await fails()).code, kMainOffline);
      // An older Pi: the mux's 405, the web UI's plain 404; an older main: 501.
      answer = (_) => http.Response('Method Not Allowed', 405);
      expect((await fails()).code, kGeoSearchUnsupported);
      answer = (_) => http.Response('404 page not found', 404);
      expect((await fails()).code, kGeoSearchUnsupported);
      answer = (_) => json({'error': "The server doesn't support this yet.", 'code': 'main_unsupported'}, 501);
      expect((await fails()).code, kGeoSearchUnsupported);
      // An unknown order stays a 404 not_found.
      answer = (_) => json({'error': 'order not found', 'code': 'not_found'}, 404);
      expect((await fails()).code, 'not_found');
    });

    test('a 401 never unpairs the tablet', () async {
      answer = (_) => json({'error': 'device key required', 'code': 'device_required'}, 401);
      final e = await fails();
      expect(e.statusCode, 401);
      expect(revoked, isEmpty);
    });
  });

  group('Default times card', () {
    testWidgets('SAVE changes only the edited field: a value changed on the Pi meanwhile is kept', (tester) async {
      final f = FakeDeliveryFloor(deliveryFloor());
      final pi = AgentClient(baseUrl: 'http://pi:8080', deviceKey: 'k', client: MockClient((_) async => http.Response('{}', 200)));
      final c = await deliveryContainer(f, extra: [agentClientProvider.overrideWithValue(pi)]);
      addTearDown(c.dispose);
      c.read(floorProvider); // build the controller before setting its state
      void piTimes(int p, int d) => f.state = f.state.copyWith(
        floor: f.state.floor!.copyWith(
          settings: f.state.settings.copyWith(times: DefaultTimes(defaultPickupMinutes: p, defaultDeliveryMinutes: d)),
        ),
      );
      piTimes(15, 40);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: darkTheme(), home: const Scaffold(body: SingleChildScrollView(child: DefaultTimesSettingsCard()))),
        ),
      );
      await tester.pump();
      // Someone nudges pickup on the open card…
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('default-pickup')), matching: find.byIcon(Icons.add)));
      await tester.pump();
      // …delivery is changed to 15 elsewhere meanwhile, then SAVE.
      piTimes(15, 15);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('times-save')));
      await tester.pump();
      final sent = callsOf(f, 'times').single.extra;
      expect(sent['default_pickup_minutes'], 20);
      expect(sent['default_delivery_minutes'], 15, reason: 'the stale 40 on the card must not be written back');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
