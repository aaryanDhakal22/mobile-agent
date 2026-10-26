import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auto_preview.dart';
import '../../core/floor_state.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../deliveries/send_out.dart';

/// Where the driver button's NEXT takes you.
enum NextGo {
  /// Send the next driver out with his pool, right here.
  sendOut,

  /// Something needs planning first: open Deliveries.
  deliveries,

  /// Nobody can go: open Drivers (clock someone in).
  drivers,
}

/// What NEXT would do now, and why (1.6.0 rules, owner-approved):
///   no available driver               → Drivers
///   the next driver's pool is empty    → Deliveries
///   more than one delivery unassigned  → Deliveries
///   otherwise                          → SEND OUT here
/// (The fourth rule, "an unassigned delivery is near his run", needs the Pi —
/// see [nearbyCheck].)
class NextPlan {
  final NextGo go;
  final Driver? driver;

  /// The pool plus AUTO's yellow stops for him — what SEND OUT would take.
  final List<SendOutStop> stops;

  /// Unassigned deliveries that would stay behind (his yellow stops excluded).
  final int unassigned;

  /// Plain words for why NEXT goes elsewhere (null when it sends out).
  final String? reason;

  const NextPlan({required this.go, this.driver, this.stops = const [], this.unassigned = 0, this.reason});
}

NextPlan planNext(FloorState fs, AutoPreview? preview) {
  final d = fs.nextDriver;
  if (d == null) {
    return NextPlan(
      go: NextGo.drivers,
      reason: fs.anyDriverOnShift
          ? 'Every driver is out. Clock another one in, or wait for one to come back.'
          : 'No driver is clocked in. Clock one in first.',
    );
  }
  final stops = sendOutStops(fs, preview, d.id);
  final riding = {for (final s in stops) s.order.id};
  final waiting = fs.unassignedDeliveries.where((o) => !riding.contains(o.id)).length;
  String waitingText() => '$waiting deliveries are waiting for a driver';
  if (stops.isEmpty) {
    return NextPlan(
      go: NextGo.deliveries,
      driver: d,
      unassigned: waiting,
      reason: waiting == 0
          ? "${d.name}'s box is empty and no delivery is waiting."
          : "${d.name}'s box is empty. Fill it on Deliveries.",
    );
  }
  if (waiting > 1) {
    return NextPlan(
      go: NextGo.deliveries,
      driver: d,
      stops: stops,
      unassigned: waiting,
      reason: '${waitingText()}. Plan the runs on Deliveries first.',
    );
  }
  return NextPlan(go: NextGo.sendOut, driver: d, stops: stops, unassigned: waiting);
}

/// The answer of the "nearby" check: unassigned deliveries close to the next
/// driver's run. Non-empty = open Deliveries with them glowing instead of
/// sending him out.
class NearbyResult {
  final List<String> orderIds;

  /// The Pi's plain words for why ("#1105 adds 3 min to Juma's run.").
  final String reason;
  const NearbyResult([this.orderIds = const [], this.reason = '']);
  bool get redirect => orderIds.isNotEmpty;
}

/// How long NEXT waits for the Pi's answer before sending anyway.
const Duration kNearbyCheckTimeout = Duration(seconds: 4);

/// Asks the Pi (`GET /api/deliveries/next-check`, 2.2.0) whether an
/// unassigned delivery is "nearby" [driver]'s run, by the rule picked in Store
/// settings → Deliveries (extra driving minutes / straight-line miles / AUTO
/// would bundle it). Never blocks a send-out: an older Pi, no answer within
/// [kNearbyCheckTimeout] or any error means "no redirect". Only deliveries
/// still unassigned on this tablet count (one taken meanwhile is skipped).
Future<NearbyResult> nearbyCheck(ProviderContainer c, Driver driver, List<SendOutStop> stops) async {
  final client = c.read(agentClientProvider);
  if (client == null || stops.isEmpty) return const NearbyResult();
  try {
    final r = await client.nextCheck(driverId: driver.id).timeout(kNearbyCheckTimeout);
    if (r == null || !r.redirect) return const NearbyResult();
    final open = {for (final o in c.read(floorProvider).unassignedDeliveries) o.id};
    final ids = r.nearbyOrderIds.where(open.contains).toList(growable: false);
    return NearbyResult(ids, ids.isEmpty ? '' : r.reason);
  } catch (_) {
    return const NearbyResult();
  }
}
