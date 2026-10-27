import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/polyline.dart';
import 'package:mobile_agent/features/maps/delivery_map.dart';
import 'package:mobile_agent/features/maps/geo_format.dart';
import 'package:mobile_agent/features/maps/map_layers.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
// ignore: implementation_imports
import 'package:vector_map_tiles_pmtiles/src/themes/v4/_package.dart' as protomaps_v4;

import 'delivery_fixtures.dart';

Future<(ProviderContainer, FakeDeliveryFloor)> pumpMap(
  WidgetTester tester,
  StoredOrder order, {
  MapSource? map = const MapSource(url: 'http://pi:8080/api/map.pmtiles', version: '1'),
  FakeDeliveryFloor? fake,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final f = fake ?? FakeDeliveryFloor(deliveryFloor().withOrder(order));
  final c = await deliveryContainer(f, map: map);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(width: 480, child: DeliveryMap(order: order)),
        ),
      ),
    ),
  );
  await tester.pump();
  return (c, f);
}

void main() {
  group('polyline', () {
    test("decodes Google's reference example", () {
      final pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(pts, hasLength(3));
      expect(pts[0].lat, closeTo(38.5, 1e-9));
      expect(pts[0].lng, closeTo(-120.2, 1e-9));
      expect(pts[1].lat, closeTo(40.7, 1e-9));
      expect(pts[1].lng, closeTo(-120.95, 1e-9));
      expect(pts[2].lat, closeTo(43.252, 1e-9));
      expect(pts[2].lng, closeTo(-126.453, 1e-9));
    });

    test('round-trips and survives junk', () {
      final pts = [(lat: 40.66871, lng: -74.11432), (lat: 40.68012, lng: -74.09901), (lat: 40.7, lng: -74.0)];
      final back = decodePolyline(encodePolyline(pts));
      for (var i = 0; i < pts.length; i++) {
        expect(back[i].lat, closeTo(pts[i].lat, 1e-5));
        expect(back[i].lng, closeTo(pts[i].lng, 1e-5));
      }
      expect(decodePolyline(''), isEmpty);
      // Truncated mid-point: only the complete points come back.
      final enc = encodePolyline(pts);
      expect(decodePolyline(enc.substring(0, enc.length - 2)), hasLength(2));
    });
  });

  test('labels: mi · min, hints', () {
    expect(milesLabel(3700), '2.3 mi');
    expect(milesLabel(20000), '12 mi');
    expect(driveMinutesLabel(420), '7 min');
    expect(driveMinutesLabel(10), '1 min');
    expect(driveLabel(const OrderGeo(state: GeoState.located, distanceM: 3700, durationS: 420)), '2.3 mi · 7 min');
    expect(driveLabel(const OrderGeo(state: GeoState.located)), isNull);
    expect(geoHint(null), 'locating…');
    expect(geoHint(const OrderGeo(state: GeoState.notFound)), 'no location');
    expect(geoHint(const OrderGeo(state: GeoState.unavailable)), 'no location');
    expect(geoHint(const OrderGeo(state: GeoState.pending)), 'locating…');
  });

  test('the offline style: every label is a plain name, no icons, no format', () {
    for (final layers in [protomaps_v4.themeLight, protomaps_v4.themeDark]) {
      final out = offlineProtomapsLayers(layers);
      final symbols = out.where((l) => (l['layout'] as Map?)?.containsKey('text-field') ?? false).toList();
      expect(symbols, isNotEmpty);
      for (final l in out) {
        final layout = l['layout'] as Map?;
        if (layout == null) continue;
        expect(layout.containsKey('icon-image'), isFalse);
        if (layout.containsKey('text-field')) {
          expect(layout['text-field'], [
            'coalesce',
            ['get', 'name:en'],
            ['get', 'name'],
          ]);
          expect((layout['text-font'] as List).single, isA<String>());
        }
      }
      expect(out.toString().contains('format'), isFalse);
    }
    // Parses into a theme with a "protomaps" source.
    expect(protomapsTheme(dark: false).tileSources, contains('protomaps'));
    expect(protomapsTheme(dark: true).tileSources, contains('protomaps'));
  });

  group('DeliveryMap', () {
    testWidgets('located: map, store + door, route, label, recenter; no tags when exact', (tester) async {
      await pumpMap(tester, delivery('m1', 1201, geo: locatedGeo()));
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.byKey(stubTilesKey), findsOneWidget, reason: 'tile layer stubbed');
      expect(find.text('2.3 mi · 7 min'), findsOneWidget);
      expect(find.byType(PolylineLayer), findsOneWidget);
      expect(find.byIcon(Icons.storefront), findsOneWidget);
      expect(find.byIcon(Icons.location_on), findsOneWidget);
      expect(find.text('approximate location'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('recenter')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('located without a road route: a dashed straight line', (tester) async {
      await pumpMap(tester, delivery('m1', 1201, geo: locatedGeo(withRoute: false)));
      final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
      expect(layer.polylines.single.points, hasLength(2));
      expect(layer.polylines.single.pattern, isNot(const StrokePattern.solid()));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('approx → amber tag; outside → red tag', (tester) async {
      await pumpMap(tester, delivery('m1', 1201, geo: locatedGeo(quality: 'approx', outside: true)));
      expect(find.text('approximate location'), findsOneWidget);
      expect(find.text('outside delivery area'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pending / no geo yet → Locating…', (tester) async {
      await pumpMap(tester, delivery('m1', 1201, geo: const {'state': 'pending'}));
      expect(find.text('Locating…'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      await tester.pumpWidget(const SizedBox());

      await pumpMap(tester, delivery('m2', 1202));
      expect(find.text('Locating…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('not found → tap the map to place a pin, SAVE PIN sends it', (tester) async {
      final (_, f) = await pumpMap(tester, delivery('m1', 1201, geo: const {'state': 'not_found'}));
      expect(find.text('Not found on the map'), findsOneWidget);
      expect(find.text('SEARCH ADDRESS'), findsOneWidget);
      expect(find.byKey(const ValueKey('confirm-pin')), findsNothing);
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)) + const Offset(40, 30));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('confirm-pin')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-pin')));
      await tester.pump();
      final pin = callsOf(f, 'pin').single;
      expect(pin.ids, ['m1']);
      expect(pin.extra['lat'], isA<double>());
      expect(find.text('Pin saved'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unavailable (never located) → "No map location", pin drop offered', (tester) async {
      final (_, f) = await pumpMap(tester, delivery('m1', 1201, geo: const {'state': 'unavailable'}));
      expect(find.text('Locating…'), findsNothing);
      expect(find.text('No map location'), findsOneWidget);
      expect(find.text('PLACE PIN'), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)) + const Offset(-30, 20));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('confirm-pin')));
      await tester.pump();
      expect(callsOf(f, 'pin').single.ids, ['m1']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no map file on the Pi yet → a plain card with the distance', (tester) async {
      await pumpMap(tester, delivery('m1', 1201, geo: locatedGeo(outside: true)), map: null);
      expect(find.text('Map not downloaded yet'), findsOneWidget);
      expect(find.textContaining('2.3 mi · 7 min'), findsWidgets);
      expect(find.text('outside delivery area'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('follows light and dark', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final seen = <bool>[];
      final f = FakeDeliveryFloor(deliveryFloor());
      final c = await deliveryContainer(f);
      addTearDown(c.dispose);
      final o = delivery('m1', 1201, geo: locatedGeo());
      final child = ProviderContainer(
        parent: c,
        overrides: [
          mapBaseLayerProvider.overrideWithValue((context, source, dark) {
            seen.add(dark);
            return const SizedBox.expand();
          }),
        ],
      );
      addTearDown(child.dispose);
      for (final b in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: child,
            child: MaterialApp(
              theme: ThemeData(brightness: b),
              home: Scaffold(body: SizedBox(width: 480, child: DeliveryMap(order: o))),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400)); // the theme animates
      }
      expect(seen, containsAllInOrder([false, true]));
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('order detail shows the map above the address for a delivery', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final o = delivery('m1', 1201, geo: locatedGeo());
    final c = await deliveryContainer(FakeDeliveryFloor(deliveryFloor().withOrder(o)));
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
    expect(find.byType(DeliveryMap), findsOneWidget);
    final mapY = tester.getTopLeft(find.byType(DeliveryMap)).dy;
    final addrY = tester.getTopLeft(find.text('DELIVERY ADDRESS')).dy;
    expect(mapY, lessThan(addrY));
    await tester.pumpWidget(const SizedBox());
  });
}
