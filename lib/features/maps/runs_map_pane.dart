import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/delivery_models.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/polyline.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import 'geo_format.dart';
import 'map_layers.dart';

/// One colour per driver, by roster position, so a driver keeps his colour
/// all shift. Picked to stand apart on both map themes.
const kDriverColors = <Color>[
  Color(0xFF8B5CF6),
  Color(0xFF0EA5E9),
  Color(0xFFF97316),
  Color(0xFF10B981),
  Color(0xFFEC4899),
  Color(0xFFEAB308),
  Color(0xFFEF4444),
  Color(0xFF14B8A6),
];

Color driverColor(List<Driver> roster, String driverId) {
  final i = roster.indexWhere((d) => d.id == driverId);
  return kDriverColors[(i < 0 ? 0 : i) % kDriverColors.length];
}

/// One driver out on a run: who, his colour, and his stops.
@immutable
class OutRun {
  final Driver driver;
  final Color color;
  final List<StoredOrder> stops;
  final DateTime? outAt;
  const OutRun(this.driver, this.color, this.stops, this.outAt);

  List<String> get ids => [for (final o in stops) o.id];
}

/// The drivers out right now with the deliveries they carry, in roster order.
List<OutRun> outRuns(List<Driver> drivers, List<StoredOrder> onDelivery) => [
  for (final d in drivers)
    if (onDelivery.any((o) => o.status.driverId == d.id))
      () {
        final stops = onDelivery.where((o) => o.status.driverId == d.id).toList();
        final out = stops.map((o) => o.status.outAt).whereType<DateTime>().fold<DateTime?>(
          null,
          (a, b) => a == null || b.isBefore(a) ? b : a,
        );
        return OutRun(d, driverColor(drivers, d.id), stops, out);
      }(),
];

/// Each out run's road route (the Pi's `pool/trip`, which also takes orders
/// already out). Keyed by the run's order ids so a new run asks again.
final _runTripProvider = FutureProvider.autoDispose.family<PoolTrip?, ({String driver, String ids})>((ref, k) async {
  try {
    return await ref.read(floorProvider.notifier).poolTrip(k.driver, k.ids.split(','));
  } catch (_) {
    return null; // straight lines instead
  }
});

/// Kitchen mode → Map (1.6.1): every driver who is out, his route in his
/// colour, a legend on the right. An overview, not a tracker: the Pi has no
/// driver positions, and the map doesn't move (no gestures).
class RunsMapPane extends ConsumerWidget {
  const RunsMapPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(floorProvider.select((s) => s.drivers));
    final onDelivery = ref.watch(floorProvider.select((s) => s.onDelivery));
    final store = ref.watch(floorProvider.select((s) => s.floor?.store?.point));
    final source = ref.watch(mapSourceProvider);
    final runs = outRuns(drivers, onDelivery);
    final trips = {
      for (final r in runs) r.driver.id: ref.watch(_runTripProvider((driver: r.driver.id, ids: r.ids.join(',')))).valueOrNull,
    };
    final n = runs.length;
    return Padding(
      padding: QuiccSpace.paneInsets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(
            title: 'Map',
            subtitle: n == 0 ? 'No driver is out' : '$n driver${n == 1 ? '' : 's'} out · each in their colour',
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(QuiccRadius.md),
                    child: _RunsMap(runs: runs, trips: trips, store: store, source: source),
                  ),
                ),
                QuiccSpace.gapLg,
                SizedBox(width: 300, child: _Legend(runs: runs, trips: trips)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RunsMap extends ConsumerWidget {
  final List<OutRun> runs;
  final Map<String, PoolTrip?> trips;
  final GeoPoint? store;
  final MapSource? source;
  const _RunsMap({required this.runs, required this.trips, required this.store, required this.source});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    if (source == null) {
      return ColoredBox(
        color: palette.bgSurface,
        child: Center(
          child: Text(
            'Map not downloaded to the Pi yet.',
            style: QuiccType.text(QuiccType.body, color: palette.textSecondary),
          ),
        ),
      );
    }
    final pts = <GeoPoint>[?store, for (final r in runs) for (final o in r.stops) ?o.geo?.point];
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lines = <Polyline>[
      for (final r in runs) ?_line(r, trips[r.driver.id]),
    ];
    // The whole delivery area when nobody is out; otherwise fit the runs.
    final fit = pts.length <= 1 && store != null
        ? CameraFit.coordinates(coordinates: [ll(store!)], maxZoom: 13)
        : fitPoints(pts, padding: const EdgeInsets.all(56));
    return IgnorePointer(
      child: FlutterMap(
        // A new set of runs refits the camera.
        key: ValueKey(runs.map((r) => r.ids.join(',')).join('|')),
        options: MapOptions(
          initialCameraFit: pts.isEmpty ? null : fit,
          backgroundColor: mapBackground(dark),
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
        ),
        children: [
          ref.watch(mapBaseLayerProvider)(context, source!, dark),
          PolylineLayer(polylines: lines),
          MarkerLayer(
            markers: [
              if (store != null) storeMarker(store!),
              for (final r in runs)
                for (final o in r.stops)
                  if (o.geo?.point != null) _stop(o.geo!.point!, o.displayNumber, r.color),
            ],
          ),
          const MapAttribution(),
        ],
      ),
    );
  }

  /// The road route, or straight dashed lines store → stops when the Pi
  /// couldn't give one.
  Polyline? _line(OutRun r, PoolTrip? trip) {
    final road = trip == null || trip.approximate || trip.polyline.isEmpty
        ? const <GeoPoint>[]
        : decodePolyline(trip.polyline);
    final straight = <GeoPoint>[?store, for (final o in r.stops) ?o.geo?.point];
    final pts = road.length >= 2 ? road : straight;
    if (pts.length < 2) return null;
    final dashed = road.length < 2;
    return Polyline(
      points: [for (final p in pts) ll(p)],
      strokeWidth: dashed ? 4 : 6,
      color: r.color,
      borderStrokeWidth: 2,
      borderColor: Colors.white70,
      pattern: dashed ? StrokePattern.dashed(segments: const [10, 8]) : const StrokePattern.solid(),
    );
  }

  Marker _stop(GeoPoint p, String number, Color color) => Marker(
    point: ll(p),
    width: 64,
    height: 30,
    child: Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
      ),
      child: Text(number, style: QuiccType.number(QuiccType.label, weight: FontWeight.w700, color: Colors.white)),
    ),
  );
}

class _Legend extends StatelessWidget {
  final List<OutRun> runs;
  final Map<String, PoolTrip?> trips;
  const _Legend({required this.runs, required this.trips});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (runs.isEmpty) {
      return Text(
        'When a driver goes out, his run shows here in his own colour.',
        style: QuiccType.text(QuiccType.body, color: palette.textSecondary),
      );
    }
    return Ticker(
      interval: const Duration(seconds: 30),
      builder: (context, now) => ListView(
        children: [
          for (final r in runs)
            Padding(
              key: ValueKey('legend-${r.driver.id}'),
              padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 8,
                    height: 56,
                    decoration: BoxDecoration(color: r.color, borderRadius: BorderRadius.circular(4)),
                  ),
                  QuiccSpace.gapMd,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.driver.name, style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700)),
                        Text(
                          [
                            '${r.stops.length} stop${r.stops.length == 1 ? '' : 's'}',
                            if (r.outAt != null) 'out ${minutes(now.difference(r.outAt!))}',
                            if (trips[r.driver.id] case final t? when t.distanceM > 0) milesLabel(t.distanceM),
                          ].join(' · '),
                          style: QuiccType.text(QuiccType.label, color: palette.textSecondary),
                        ),
                        QuiccSpace.gapXs,
                        Text(
                          r.stops.map((o) => o.displayNumber).join('  '),
                          style: QuiccType.number(QuiccType.label, color: r.color),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
