// Wire models for driver pools, AUTO plans and pool trips (agent 2.0.9,
// contract/agent.md — pools / AUTO plan / pool trip).

import 'json.dart';
import 'models.dart';

/// One stop of an AUTO run.
class PlanStop {
  final String orderId;
  final DateTime? eta;
  final int placedToDoorS;
  final bool late;
  const PlanStop({required this.orderId, this.eta, this.placedToDoorS = 0, this.late = false});

  factory PlanStop.fromJson(Map<String, dynamic> json) => PlanStop(
    orderId: jStr(json['order_id']),
    eta: jDate(json['eta']),
    placedToDoorS: jInt(json['placed_to_door_s']),
    late: jBool(json['late']),
  );
}

/// One driver's suggested run: [orderIds] in driving order (already pooled
/// ones included), [suggestedIds] the ones AUTO adds.
class PlanRun {
  final String driverId;
  final List<String> orderIds;
  final List<String> suggestedIds;
  final DateTime? departAt;
  final DateTime? returnAt;
  final int driveS;
  final List<PlanStop> stops;

  const PlanRun({
    required this.driverId,
    this.orderIds = const [],
    this.suggestedIds = const [],
    this.departAt,
    this.returnAt,
    this.driveS = 0,
    this.stops = const [],
  });

  factory PlanRun.fromJson(Map<String, dynamic> json) => PlanRun(
    driverId: jStr(json['driver_id']),
    orderIds: _ids(json['order_ids']),
    suggestedIds: _ids(json['suggested_ids']),
    departAt: jDate(json['depart_at']),
    returnAt: jDate(json['return_at']),
    driveS: jInt(json['drive_s']),
    stops: jList(json['stops'], PlanStop.fromJson),
  );
}

/// A delivery AUTO left on the left, and why.
class PlanLeftover {
  final String orderId;

  /// no_location | not_ready_soon | no_driver | no_feasible_run | over_limit
  /// | held_for_returning_driver (2.2.1)
  final String reason;

  /// 2.2.1: kept for a driver on his way back (`held_for_returning_driver`).
  final HeldFor? heldFor;
  const PlanLeftover({required this.orderId, this.reason = '', this.heldFor});

  factory PlanLeftover.fromJson(Map<String, dynamic> json) => PlanLeftover(
    orderId: jStr(json['order_id']),
    reason: jStr(json['reason']),
    heldFor: HeldFor.fromJson(json['held_for']),
  );
}

/// The driver on his way back a delivery is better kept for (Pi 2.2.1): it
/// is the other way from the run going out now.
class HeldFor {
  final String driverId;
  final String name;

  /// When the Pi expects him back.
  final DateTime? returnAt;
  const HeldFor({required this.driverId, required this.name, this.returnAt});

  static HeldFor? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = jMap(raw);
    final id = jStr(m['driver_id']);
    final name = jStr(m['name']).trim();
    if (id.isEmpty && name.isEmpty) return null;
    return HeldFor(driverId: id, name: name.isEmpty ? 'the driver' : name, returnAt: jDate(m['return_at']));
  }

  /// "~6 min" until he is back (from [now]); "any minute" once due; null
  /// without a time.
  String? backIn(DateTime now) {
    final t = returnAt;
    if (t == null) return null;
    final m = (t.difference(now).inSeconds / 60).ceil();
    return m <= 0 ? 'any minute' : '~$m min';
  }
}

/// One stop the send-out would be better without (`GET
/// /api/drivers/{id}/send-check`, Pi 2.2.1).
class HeldStop {
  final String orderId;
  final String address;
  final HeldFor? heldFor;
  const HeldStop({required this.orderId, this.address = '', this.heldFor});

  factory HeldStop.fromJson(Map<String, dynamic> json) => HeldStop(
    orderId: jStr(json['order_id']),
    address: jStr(json['address']).trim(),
    heldFor: HeldFor.fromJson(json['held_for']),
  );
}

/// `POST /api/deliveries/auto-plan` → a suggestion; nothing changed yet.
class AutoPlan {
  final String planId;
  final DateTime? createdAt;

  /// Some drive times were guessed (the Pi had no road time for a pair —
  /// e.g. offline).
  final bool estimated;
  final bool fallback;
  final int solveMs;
  final List<PlanRun> runs;
  final List<PlanLeftover> unassigned;

  const AutoPlan({
    required this.planId,
    this.createdAt,
    this.estimated = false,
    this.fallback = false,
    this.solveMs = 0,
    this.runs = const [],
    this.unassigned = const [],
  });

  factory AutoPlan.fromJson(Map<String, dynamic> json) => AutoPlan(
    planId: jStr(json['plan_id']),
    createdAt: jDate(json['created_at']),
    estimated: jBool(json['estimated']),
    fallback: jBool(json['fallback']),
    solveMs: jInt(json['solve_ms']),
    runs: jList(json['runs'], PlanRun.fromJson),
    unassigned: jList(json['unassigned'], PlanLeftover.fromJson),
  );

  /// Every order AUTO adds, across drivers.
  int get suggestedCount => runs.fold(0, (n, r) => n + r.suggestedIds.length);
}

/// `POST /api/deliveries/auto-plan/{id}/confirm` → what was pooled and what
/// was skipped (sent or moved meanwhile).
class PlanConfirmResult {
  final List<String> applied;
  final List<PlanLeftover> skipped;
  const PlanConfirmResult({this.applied = const [], this.skipped = const []});

  factory PlanConfirmResult.fromJson(Map<String, dynamic> json) =>
      PlanConfirmResult(applied: _ids(json['applied']), skipped: jList(json['skipped'], PlanLeftover.fromJson));
}

/// `GET /api/drivers/{id}/pool/trip` → the stops in the fastest driving
/// order. [approximate]: main was unreachable — the Pi's own order, no road
/// route ([polyline] empty, draw straight lines).
class PoolTrip {
  final List<String> orderIds;
  final String polyline;
  final int distanceM;
  final int durationS;
  final bool approximate;

  const PoolTrip({
    this.orderIds = const [],
    this.polyline = '',
    this.distanceM = 0,
    this.durationS = 0,
    this.approximate = false,
  });

  factory PoolTrip.fromJson(Map<String, dynamic> json) => PoolTrip(
    orderIds: _ids(json['order_ids']),
    polyline: jStr(json['polyline']),
    distanceM: jInt(json['distance_m']),
    durationS: jInt(json['duration_s']),
    approximate: jBool(json['approximate']),
  );
}

/// `PUT /api/settings/deliveries`.
/// The "nearby" rule (2.2.0): when the driver button's NEXT sends you to
/// Deliveries because an unassigned delivery is close to the next driver's run.
enum NearbyRule {
  /// Adds at most N minutes of driving to his run.
  detour,

  /// Within X miles (straight line) of a stop in his pool.
  distance,

  /// AUTO would put it in his run.
  bundle,
  off;

  static NearbyRule? parse(Object? raw) => switch ('$raw') {
    'detour' => NearbyRule.detour,
    'distance' => NearbyRule.distance,
    'bundle' => NearbyRule.bundle,
    'off' => NearbyRule.off,
    _ => null,
  };
}

/// `PUT /api/settings/deliveries` (2.0.9; nearby + radius 2.2.0). The 2.2.0
/// fields are sent only when set, so an older Pi still takes the rest.
class DeliverySettings {
  final int soonReadyMinutes;
  final int deliveryTargetMinutes;
  final NearbyRule? nearbyRule;
  final int? nearbyDetourMinutes;
  final double? nearbyDistanceMi;

  /// Synced to main (RPC `location.radius`); main pushes the store back.
  final int? deliveryRadiusM;

  /// Simple auto-assign (2.2.1); sent only when set.
  final bool? autoAssign;

  const DeliverySettings({
    required this.soonReadyMinutes,
    required this.deliveryTargetMinutes,
    this.nearbyRule,
    this.nearbyDetourMinutes,
    this.nearbyDistanceMi,
    this.deliveryRadiusM,
    this.autoAssign,
  });

  static const int minSoonReady = 0, maxSoonReady = 30;
  static const int minTarget = 15, maxTarget = 120;
  static const int minDetour = 1, maxDetour = 30, defaultDetour = 5;
  static const double minDistanceMi = 0.1, maxDistanceMi = 10, defaultDistanceMi = 1.0;
  static const int minRadiusM = 500, maxRadiusM = 80467;

  factory DeliverySettings.fromJson(Map<String, dynamic> json) => DeliverySettings(
    soonReadyMinutes: jInt(json['soon_ready_minutes']),
    deliveryTargetMinutes: jInt(json['delivery_target_minutes']),
    nearbyRule: NearbyRule.parse(json['nearby_rule']),
    nearbyDetourMinutes: jIntOrNull(json['nearby_detour_minutes']),
    nearbyDistanceMi: json['nearby_distance_mi'] is num ? (json['nearby_distance_mi'] as num).toDouble() : null,
    deliveryRadiusM: jIntOrNull(json['delivery_radius_m']),
    autoAssign: json['auto_assign'] is bool ? json['auto_assign'] as bool : null,
  );

  Map<String, Object> toJson() => {
    'soon_ready_minutes': soonReadyMinutes,
    'delivery_target_minutes': deliveryTargetMinutes,
    'nearby_rule': ?nearbyRule?.name,
    'nearby_detour_minutes': ?nearbyDetourMinutes,
    'nearby_distance_mi': ?nearbyDistanceMi,
    'delivery_radius_m': ?deliveryRadiusM,
    'auto_assign': ?autoAssign,
  };
}

/// `GET /api/deliveries/next-check` (2.2.0): unassigned deliveries "nearby"
/// the next driver's run, by the store's rule.
class NextCheck {
  final String? driverId;
  final NearbyRule? rule;
  final List<String> nearbyOrderIds;
  final String reason;
  const NextCheck({this.driverId, this.rule, this.nearbyOrderIds = const [], this.reason = ''});

  bool get redirect => nearbyOrderIds.isNotEmpty;

  factory NextCheck.fromJson(Map<String, dynamic> json) => NextCheck(
    driverId: jStrOrNull(jStr(json['driver_id'])),
    rule: NearbyRule.parse(json['rule']),
    nearbyOrderIds: _ids(json['nearby_order_ids']),
    reason: jStr(json['reason']).trim(),
  );
}

/// One line of the Pi's own log (`GET /api/dev/events`, 2.2.0). No PII.
class PiEvent {
  final int seq;
  final DateTime? at;
  final String level;
  final String kind;
  final String text;
  const PiEvent({required this.seq, this.at, this.level = 'info', this.kind = 'system', this.text = ''});

  factory PiEvent.fromJson(Map<String, dynamic> json) => PiEvent(
    seq: jInt(json['seq']),
    at: jDate(json['at']),
    level: jStr(json['level'], 'info'),
    kind: jStr(json['kind'], 'system'),
    text: jStr(json['text']),
  );
}

List<String> _ids(Object? raw) => raw is List
    ? raw.map((e) => jStr(e)).where((s) => s.isNotEmpty).toList(growable: false)
    : const <String>[];

/// The Pi's simple auto-assign (2.2.1) pooled [orderIds] for the NEXT
/// driver (SSE `deliveries.auto_assigned`, or the "returned" answer). It
/// never sends anyone out: the driver button pops open on the NEXT card.
class AutoAssignment {
  final String driverId;
  final String driverName;
  final List<String> orderIds;
  const AutoAssignment({this.driverId = '', this.driverName = '', this.orderIds = const []});

  static AutoAssignment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = jMap(raw);
    final ids = idList(m['order_ids']);
    if (ids.isEmpty) return null;
    return AutoAssignment(driverId: jStr(m['driver_id']), driverName: jStr(m['driver_name']), orderIds: ids);
  }
}

/// `POST /api/drivers/{id}/returned`: the run's orders, and (2.2.1) what
/// auto-assign pooled for the next driver right after.
class ReturnedResult {
  final List<StoredOrder> orders;
  final AutoAssignment? autoAssigned;
  const ReturnedResult({this.orders = const [], this.autoAssigned});

  /// A list (≤ 2.2.0) or `{orders, auto_assigned_order_ids,
  /// auto_assigned_driver_id?, auto_assigned_driver_name?}` (2.2.1).
  factory ReturnedResult.fromJson(Object? body) {
    if (body is List) return ReturnedResult(orders: jList(body, StoredOrder.fromJson));
    final m = jMap(body);
    final ids = idList(m['auto_assigned_order_ids']);
    return ReturnedResult(
      orders: jList(m['orders'], StoredOrder.fromJson),
      autoAssigned: ids.isEmpty
          ? null
          : AutoAssignment(
              driverId: jStr(m['auto_assigned_driver_id']),
              driverName: jStr(m['auto_assigned_driver_name']),
              orderIds: ids,
            ),
    );
  }
}

/// Non-empty strings of a JSON list.
List<String> idList(Object? raw) => [
  if (raw is List)
    for (final x in raw)
      if (jStr(x).isNotEmpty) jStr(x),
];
