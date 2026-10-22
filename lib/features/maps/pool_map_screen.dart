import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/delivery_models.dart';
import '../../core/models.dart';
import '../../core/polyline.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../order_detail/order_detail_screen.dart';
import 'geo_format.dart';
import 'map_layers.dart';

/// A driver's run on the map: the store and the pooled stops, numbered in
/// the fastest driving order (a suggestion — main's road route, or straight
/// lines marked approximate when main can't be reached), with the total
/// miles and minutes. [orderIds] are explicit so AUTO's yellow stops
/// ([yellowIds]) show too.
class PoolMapScreen extends ConsumerStatefulWidget {
  final String driverId;
  final String driverName;
  final List<String> orderIds;
  final Set<String> yellowIds;
  const PoolMapScreen({
    super.key,
    required this.driverId,
    required this.driverName,
    required this.orderIds,
    this.yellowIds = const {},
  });

  @override
  ConsumerState<PoolMapScreen> createState() => _PoolMapScreenState();
}

class _PoolMapScreenState extends ConsumerState<PoolMapScreen> {
  final MapController _ctrl = MapController();
  PoolTrip? _trip;
  bool _loading = true;

  /// The trip couldn't be asked for (Pi unreachable / older Pi): the stops
  /// show in pool order with straight lines.
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.orderIds.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    try {
      final t = await ref.read(floorProvider.notifier).poolTrip(widget.driverId, widget.orderIds);
      if (mounted) {
        setState(() {
          _trip = t;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
      if (e is! AgentException || e.code != kPoolsUnsupported) {
        toastError(context, e, lead: 'Fastest order not worked out — showing the pool order', area: 'maps');
      }
    }
  }

  /// The stops in trip order (any the trip left out go last).
  List<String> get _ordered {
    final t = _trip?.orderIds ?? const <String>[];
    return [
      for (final id in t)
        if (widget.orderIds.contains(id)) id,
      for (final id in widget.orderIds)
        if (!t.contains(id)) id,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(floorProvider.select((s) => s.orders));
    final store = ref.watch(floorProvider.select((s) => s.floor?.store));
    final source = ref.watch(mapSourceProvider);
    final stops = [
      for (final id in _ordered)
        if (orders[id] != null) orders[id]!,
    ];
    final trip = _trip;
    final approximate = _failed || (trip?.approximate ?? false) || (trip != null && trip.polyline.isEmpty);
    final n = stops.length;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: context.palette.bgSurface,
        toolbarHeight: 72,
        title: Row(
          children: [
            const Icon(Icons.route, color: QuiccColors.brand400, size: 28),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                "${widget.driverName}'s run · $n stop${n == 1 ? '' : 's'}",
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _map(context, stops, store?.point, source, approximate),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 2,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
              children: [
                _Totals(trip: trip, stops: stops, store: store?.point, approximate: approximate, loading: _loading),
                const SizedBox(height: 16),
                const Eyebrow('Stops, fastest order first'),
                const SizedBox(height: 8),
                if (stops.isEmpty) Text('No stops.', style: TextStyle(color: context.palette.textMuted)),
                for (var i = 0; i < stops.length; i++)
                  _StopTile(n: i + 1, order: stops[i], yellow: widget.yellowIds.contains(stops[i].id)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _map(BuildContext context, List<StoredOrder> stops, GeoPoint? store, MapSource? source, bool approximate) {
    if (source == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 64, color: context.palette.textMuted),
            const SizedBox(height: 12),
            const Text('Map not downloaded yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('The stops are listed on the right.', style: TextStyle(color: context.palette.textSecondary)),
          ],
        ),
      );
    }
    final located = [
      for (var i = 0; i < stops.length; i++)
        if (stops[i].geo?.point != null) (n: i + 1, order: stops[i], p: stops[i].geo!.point!),
    ];
    final pts = <GeoPoint>[?store, for (final s in located) s.p];
    if (pts.isEmpty) {
      return Center(
        child: Text('None of these stops is on the map yet.', style: TextStyle(color: context.palette.textSecondary)),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final route = (!approximate && _trip != null) ? decodePolyline(_trip!.polyline) : const <GeoPoint>[];
    final line = route.length >= 2 ? routeLine(route) : (pts.length >= 2 ? routeLine(pts, dashed: true) : null);
    // Generous room so no stop (or the store) sits under an edge, the
    // recenter button or a toast.
    final fit = fitPoints(pts, padding: const EdgeInsets.fromLTRB(64, 64, 64, 112));
    return ClipRRect(
      borderRadius: BorderRadius.circular(QuiccRadius.md),
      child: Stack(
        children: [
          FlutterMap(
            mapController: _ctrl,
            options: MapOptions(
              initialCameraFit: fit,
              backgroundColor: mapBackground(dark),
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            ),
            children: [
              ref.watch(mapBaseLayerProvider)(context, source, dark),
              if (line != null) PolylineLayer(polylines: [line]),
              MarkerLayer(
                markers: [
                  if (store != null) storeMarker(store),
                  for (final s in located) stopMarker(s.p, s.n, yellow: widget.yellowIds.contains(s.order.id)),
                ],
              ),
              const MapAttribution(),
            ],
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Material(
              color: context.palette.bgSurface,
              shape: const CircleBorder(),
              elevation: 2,
              child: IconButton(
                tooltip: 'Recenter',
                icon: const Icon(Icons.center_focus_strong, color: QuiccColors.brand400),
                onPressed: () => _ctrl.fitCamera(fit),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  final PoolTrip? trip;
  final List<StoredOrder> stops;
  final GeoPoint? store;
  final bool approximate;
  final bool loading;
  const _Totals({
    required this.trip,
    required this.stops,
    required this.store,
    required this.approximate,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final t = trip;
    String text;
    if (loading) {
      text = 'Working out the fastest order…';
    } else if (t != null && (t.distanceM > 0 || t.durationS > 0)) {
      text = [
        if (t.distanceM > 0) milesLabel(t.distanceM),
        if (t.durationS > 0) driveMinutesLabel(t.durationS),
      ].join(' · ');
    } else {
      // No road totals: the straight-line length store → stops, as a hint.
      final pts = <GeoPoint>[?store, for (final o in stops) ?o.geo?.point];
      var m = 0.0;
      const d = Distance();
      for (var i = 1; i < pts.length; i++) {
        m += d.as(LengthUnit.Meter, LatLng(pts[i - 1].lat, pts[i - 1].lng), LatLng(pts[i].lat, pts[i].lng));
      }
      text = m > 0 ? 'about ${milesLabel(m.round())} in a straight line' : 'No distance yet';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Eyebrow('Total'),
        const SizedBox(height: 4),
        Text(text, key: const ValueKey('trip-total'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        if (approximate && !loading) ...[
          const SizedBox(height: 6),
          const GeoTag('approximate — straight lines, no road route', color: QuiccColors.statusFiring),
        ],
      ],
    );
  }
}

class _StopTile extends StatelessWidget {
  final int n;
  final StoredOrder order;
  final bool yellow;
  const _StopTile({required this.n, required this.order, required this.yellow});

  @override
  Widget build(BuildContext context) {
    final g = order.geo;
    final label = driveLabel(g) ?? geoHint(g);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        side: BorderSide(color: yellow ? QuiccColors.statusFiring : Colors.transparent, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => OrderDetailScreen(orderId: order.id, initial: order))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: yellow ? QuiccColors.statusFiring : QuiccColors.brand600,
                child: Text(
                  '$n',
                  style: TextStyle(color: yellow ? QuiccColors.brand900 : Colors.white, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                order.displayNumber,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: QuiccColors.brand400),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(streetOf(order), maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (label != null)
                      Text(label, style: TextStyle(color: context.palette.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
              ...geoTags(g),
            ],
          ),
        ),
      ),
    );
  }
}
