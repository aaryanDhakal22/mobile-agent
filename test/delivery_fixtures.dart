// Fixtures + a recording fake floor for the 1.4.0 Deliveries screen (pools,
// AUTO, maps). Shapes follow the 2.0.9 wire contract (§A).

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/delivery_models.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/polyline.dart';
import 'package:mobile_agent/core/printer_models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/maps/map_layers.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const storeLat = 40.6687, storeLng = -74.1143;

/// A located geo with a road route from the store.
Map<String, dynamic> locatedGeo({
  String quality = 'exact',
  bool outside = false,
  int distanceM = 3700,
  int durationS = 420,
  bool withRoute = true,
}) => {
  'state': 'located',
  'lat': 40.6801,
  'lng': -74.0990,
  'quality': quality,
  'distance_m': distanceM,
  'duration_s': durationS,
  'polyline': withRoute
      ? encodePolyline([
          (lat: storeLat, lng: storeLng),
          (lat: 40.6750, lng: -74.1050),
          (lat: 40.6801, lng: -74.0990),
        ])
      : '',
  'outside_area': outside,
  'updated_at': '2026-10-22T17:00:00Z',
};

/// A delivery order (from the onDelivery fixture) in [state], kitchen #[k].
StoredOrder delivery(
  String id,
  int k, {
  String state = 'ready',
  String? pool,
  int? poolSeq,
  Map<String, dynamic>? geo,
  int placedMinutesAgo = 20,
  int? readyInMinutes,
  String street = '931 Taylor Avenue',
  int tipCents = 500,
}) {
  final m = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
  final now = clock.now().toUtc();
  (m['order'] as Map)
    ..['id'] = id
    ..['placed_at'] = now.subtract(Duration(minutes: placedMinutesAgo)).toIso8601String()
    ..['kitchen_order_number'] = k;
  ((m['order'] as Map)['money'] as Map)['tip_cents'] = tipCents;
  (((m['order'] as Map)['fulfillment'] as Map)['address'] as Map)['line1'] = street;
  final st = (m['status'] as Map)
    ..['state'] = state
    ..['kitchen_number'] = k
    ..remove('out_at')
    ..remove('driver_id')
    ..remove('driver_name');
  if (state == 'accepted') st.remove('ready_at');
  if (readyInMinutes != null) st['estimated_ready_at'] = now.add(Duration(minutes: readyInMinutes)).toIso8601String();
  if (pool != null) {
    st['pool_driver_id'] = pool;
    st['pooled_at'] = now.subtract(const Duration(minutes: 2)).toIso8601String();
    if (poolSeq != null) st['pool_seq'] = poolSeq;
  }
  if (geo != null) m['geo'] = geo;
  return StoredOrder.fromJson(m);
}

List<Driver> roster() =>
    (jsonDecode(driversJson) as List).cast<Map<String, dynamic>>().map(Driver.fromJson).toList();

/// Ana (NEXT) and Joe available, Sam out with #1104-style run, Lee off.
/// Unassigned: d1 (ready, exact), d2 (cooking, approx), d5 (ready, not found).
/// Ana's pool: d3 (ready, outside area). Joe's pool: d4 (cooking).
FloorState deliveryFloor({Map<String, dynamic>? floorExtra}) {
  final floor = jsonDecode(floorJson) as Map<String, dynamic>
    ..addAll({
      'soon_ready_minutes': 5,
      'delivery_target_minutes': 45,
      'store': {'lat': storeLat, 'lng': storeLng, 'delivery_radius_m': 8047},
      'map': {
        'version': '20261022',
        'url': '/api/map.pmtiles',
        'bbox': [-74.3, 40.5, -73.9, 40.8],
      },
      ...?floorExtra,
    });
  return const FloorState(connection: SseStatus.connected).withSnapshot(
    floor: Floor.fromJson(floor),
    current: [
      StoredOrder.fromJson(jsonDecode(onDeliveryJson) as Map<String, dynamic>),
      delivery('d1', 1101, geo: locatedGeo(), placedMinutesAgo: 30, street: '12 Avenue A'),
      delivery(
        'd2',
        1102,
        state: 'accepted',
        geo: locatedGeo(quality: 'approx'),
        placedMinutesAgo: 25,
        readyInMinutes: 4,
        street: '40 Broadway',
      ),
      delivery('d3', 1103, pool: 'd-ana', geo: locatedGeo(outside: true), placedMinutesAgo: 22, street: '7 Kennedy Blvd'),
      delivery('d4', 1106, state: 'accepted', pool: 'd-joe', readyInMinutes: 6, geo: locatedGeo(), street: '3 Oak St'),
      delivery('d5', 1105, geo: const {'state': 'not_found'}, placedMinutesAgo: 10, street: '99 Nowhere Rd'),
    ],
    arrived: const [],
    drivers: roster(),
    at: clock.now(),
  );
}

/// One recorded call on the fake floor.
typedef Call = ({String op, List<String> ids, String? driver, Map<String, Object?> extra});

/// A floor that never touches the network: actions are recorded and applied
/// locally so the screen reacts like it would to the Pi's answer.
class FakeDeliveryFloor extends FloorController {
  final FloorState initial;
  FakeDeliveryFloor(this.initial);

  final List<Call> calls = [];

  /// The next send-out throws this (then is cleared).
  AgentException? sendOutError;
  AutoPlan? plan;
  AgentException? autoPlanError;
  PlanConfirmResult confirmResult = const PlanConfirmResult();
  PoolTrip trip = const PoolTrip();

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}

  void push(FloorState s) => state = s;

  @override
  Future<void> poolOrders(List<String> orderIds, String? driverId) async {
    calls.add((op: 'pool', ids: orderIds, driver: driverId, extra: const {}));
    state = state.withOrders([
      for (final id in orderIds)
        if (state.orders[id] != null) state.orders[id]!.copyWith(status: state.orders[id]!.status.withPool(driverId)),
    ]);
  }

  @override
  Future<List<StoredOrder>> sendOut(
    String driverId, {
    bool markReady = false,
    List<String>? includeOrderIds,
    String? planId,
  }) async {
    calls.add((
      op: 'sendOut',
      ids: includeOrderIds ?? const [],
      driver: driverId,
      extra: {'markReady': markReady, 'planId': planId},
    ));
    final err = sendOutError;
    if (err != null) {
      sendOutError = null;
      throw err;
    }
    return const [];
  }

  @override
  Future<AutoPlan> autoPlan() async {
    calls.add((op: 'autoPlan', ids: const [], driver: null, extra: const {}));
    if (autoPlanError != null) throw autoPlanError!;
    return plan!;
  }

  @override
  Future<PlanConfirmResult> confirmPlan(String planId, {List<String>? orderIds}) async {
    calls.add((op: 'confirm', ids: orderIds ?? const [], driver: null, extra: {'planId': planId, 'filtered': orderIds != null}));
    return confirmResult;
  }

  @override
  Future<void> driverReturned(String driverId) async {
    calls.add((op: 'returned', ids: const [], driver: driverId, extra: const {}));
  }

  @override
  Future<PoolTrip> poolTrip(String driverId, List<String> orderIds) async {
    calls.add((op: 'trip', ids: orderIds, driver: driverId, extra: const {}));
    return trip;
  }

  @override
  Future<void> pinOrder(String orderId, double lat, double lng) async {
    calls.add((op: 'pin', ids: [orderId], driver: null, extra: {'lat': lat, 'lng': lng}));
  }

  @override
  Future<DeliverySettings> setDeliverySettings(DeliverySettings s) async {
    calls.add((op: 'settings', ids: const [], driver: null, extra: s.toJson()));
    state = state.copyWith(
      floor: state.floor!.copyWith(
        soonReadyMinutes: s.soonReadyMinutes,
        deliveryTargetMinutes: s.deliveryTargetMinutes,
      ),
    );
    return s;
  }
}

ThemeData darkTheme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

/// The stub base map (no network in tests).
const stubTilesKey = ValueKey('stub-tiles');

Future<ProviderContainer> deliveryContainer(
  FakeDeliveryFloor fake, {
  MapSource? map = const MapSource(url: 'http://pi:8080/api/map.pmtiles', version: '20261022'),
  Map<String, Object> prefs = const {},
  List<Override> extra = const [],
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(sp),
      floorProvider.overrideWith(() => fake),
      printerStatusProvider.overrideWith((ref) => Stream.value(const <PrinterStatus>[])),
      batchesProvider.overrideWith((ref) async => const [Batch(id: 7)]),
      driverShiftsProvider.overrideWith((ref) async => const []),
      mapSourceProvider.overrideWithValue(map),
      mapBaseLayerProvider.overrideWithValue((context, source, dark) => const SizedBox.expand(key: stubTilesKey)),
      ...extra,
    ],
  );
}

List<Call> callsOf(FakeDeliveryFloor f, String op) => f.calls.where((c) => c.op == op).toList();
