// Wire models for driver pools, AUTO plans and pool trips (agent 2.0.9,
// contract/agent.md — pools / AUTO plan / pool trip).

import 'json.dart';

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
  final String reason;
  const PlanLeftover({required this.orderId, this.reason = ''});

  factory PlanLeftover.fromJson(Map<String, dynamic> json) =>
      PlanLeftover(orderId: jStr(json['order_id']), reason: jStr(json['reason']));
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

  const DeliverySettings({
    required this.soonReadyMinutes,
    required this.deliveryTargetMinutes,
    this.nearbyRule,
    this.nearbyDetourMinutes,
    this.nearbyDistanceMi,
    this.deliveryRadiusM,
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
  );

  Map<String, Object> toJson() => {
    'soon_ready_minutes': soonReadyMinutes,
    'delivery_target_minutes': deliveryTargetMinutes,
    'nearby_rule': ?nearbyRule?.name,
    'nearby_detour_minutes': ?nearbyDetourMinutes,
    'nearby_distance_mi': ?nearbyDistanceMi,
    'delivery_radius_m': ?deliveryRadiusM,
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
