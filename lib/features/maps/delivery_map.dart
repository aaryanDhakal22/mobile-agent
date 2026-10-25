import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/polyline.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import 'geo_format.dart';
import 'map_layers.dart';

/// The delivery's map on the order detail: the store, the customer's door
/// and the driving route between them ("2.3 mi · 7 min"), with amber
/// "approximate location" / red "outside delivery area" tags, pan + zoom and
/// a recenter button. While main is still looking: "Locating…". Address not
/// found: tap the map to drop a pin (main remembers it for the address).
/// Without a map file on the Pi: a plain card with the distance.
class DeliveryMap extends ConsumerStatefulWidget {
  final StoredOrder order;
  final double height;
  const DeliveryMap({super.key, required this.order, this.height = 280});

  @override
  ConsumerState<DeliveryMap> createState() => _DeliveryMapState();
}

class _DeliveryMapState extends ConsumerState<DeliveryMap> {
  final MapController _ctrl = MapController();

  /// Placing a pin by hand (not found, or staff say the spot is wrong).
  bool _pinMode = false;
  LatLng? _pin;
  bool _sending = false;

  /// A pin was sent; the route comes back as an order update.
  bool _pinSent = false;

  @override
  void didUpdateWidget(DeliveryMap old) {
    super.didUpdateWidget(old);
    final g = widget.order.geo, o = old.order.geo;
    // Main answered the pin (or the location changed): back to normal.
    if (_pinSent && g != null && (g.updatedAt != o?.updatedAt || g.state != o?.state || g.isPinned)) {
      _pinSent = false;
      _pin = null;
      _pinMode = false;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _sendPin() async {
    final p = _pin;
    if (p == null) return;
    setState(() => _sending = true);
    try {
      await ref.read(floorProvider.notifier).pinOrder(widget.order.id, p.latitude, p.longitude);
      if (!mounted) return;
      setState(() {
        _pinSent = true;
        _pinMode = false;
      });
      toast(context, 'Pin saved — the route shows in a moment');
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: kMainOffline) => "The Pi can't reach Quicc right now — try the pin again in a minute.",
        AgentException(code: kPoolsUnsupported) => 'This Pi needs an update to place pins.',
        _ => null,
      };
      msg == null ? toastError(context, e, lead: 'Pin not saved', area: 'maps') : toast(context, msg, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.order.geo;
    final store = ref.watch(floorProvider.select((s) => s.floor?.store));
    final bbox = ref.watch(floorProvider.select((s) => s.floor?.map?.bbox));
    final source = ref.watch(mapSourceProvider);
    final label = driveLabel(g);
    final tags = [
      if (g != null && g.isApprox) const GeoTag('approximate location', color: QuiccColors.statusFiring),
      if (g != null && g.state == GeoState.located && g.outsideArea)
        const GeoTag('outside delivery area', color: QuiccColors.statusVoided),
    ];

    final header = Row(
      children: [
        const Eyebrow('Map'),
        const SizedBox(width: 10),
        if (label != null)
          Flexible(
            child: Text(
              label,
              key: const ValueKey('drive-label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );

    Widget body;
    if (_pinSent) {
      body = _MapCard(
        height: widget.height,
        icon: Icons.push_pin_outlined,
        title: 'Pin saved',
        message: 'The route shows in a moment.',
      );
    } else if (g == null || g.state == GeoState.pending) {
      body = _MapCard(
        height: widget.height,
        busy: true,
        title: 'Locating…',
        message: 'Looking up the address. The map shows when it is found.',
      );
    } else if (source == null) {
      body = _MapCard(
        height: widget.height,
        icon: Icons.map_outlined,
        title: 'Map not downloaded yet',
        message: g.needsPin
            ? '${_lostTitle(g)}. A pin can be placed once the map is on the Pi.'
            : (label == null ? 'The Pi gets the map from Quicc.' : 'Store → door: $label.'),
      );
    } else {
      final center = store?.point ?? _bboxCenter(bbox);
      if (g.needsPin && center == null) {
        body = _MapCard(
          height: widget.height,
          icon: Icons.location_off_outlined,
          title: _lostTitle(g),
          message: 'The store has no spot on the map yet, so a pin can\'t be placed here.',
        );
      } else {
        body = _map(context, g, store?.point, center, source);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (tags.isNotEmpty) ...[const SizedBox(height: 6), Wrap(spacing: 6, runSpacing: 4, children: tags)],
        const SizedBox(height: 8),
        body,
      ],
    );
  }

  /// "Not found on the map" (main looked and found nothing) / "No map
  /// location" (main gave up / never located it).
  static String _lostTitle(OrderGeo g) => switch (g.state) {
    GeoState.unavailable => 'No map location',
    GeoState.check => 'Address needs a check',
    _ => 'Not found on the map',
  };

  static GeoPoint? _bboxCenter(List<double>? b) =>
      (b == null || b.length != 4) ? null : (lat: (b[1] + b[3]) / 2, lng: (b[0] + b[2]) / 2);

  Widget _map(BuildContext context, OrderGeo g, GeoPoint? store, GeoPoint? center, MapSource source) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final notFound = g.needsPin;
    final placing = notFound || _pinMode;
    final dest = g.point;
    final route = g.route;
    final fitPts = <GeoPoint>[?store, ?dest];
    final fit = fitPoints(fitPts.isEmpty ? [center!] : fitPts, padding: const EdgeInsets.fromLTRB(48, 56, 48, 72));
    // The road route when main had one, else a dashed straight line.
    final line = route.length >= 2
        ? routeLine(route)
        : (store != null && dest != null ? routeLine([store, dest], dashed: true) : null);

    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        child: Stack(
          children: [
            FlutterMap(
              mapController: _ctrl,
              options: MapOptions(
                initialCameraFit: fit,
                backgroundColor: mapBackground(dark),
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                onTap: placing ? (_, p) => setState(() => _pin = p) : null,
              ),
              children: [
                ref.watch(mapBaseLayerProvider)(context, source, dark),
                if (line != null && !notFound) PolylineLayer(polylines: [line]),
                MarkerLayer(
                  markers: [
                    if (store != null) storeMarker(store),
                    if (dest != null && !notFound) destinationMarker(dest, approx: g.isApprox),
                    if (_pin != null) destinationMarker((lat: _pin!.latitude, lng: _pin!.longitude)),
                  ],
                ),
                const MapAttribution(),
              ],
            ),
            if (placing)
              Positioned(
                left: 8,
                right: 8,
                top: 8,
                child: _Banner(
                  text: _pin != null
                      ? 'Is the pin on the door? Tap again to move it.'
                      : (notFound ? '${_lostTitle(g)} — tap to place pin' : 'Tap the map where the door is'),
                ),
              ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (placing && _pin != null) ...[
                    FilledButton.icon(
                      key: const ValueKey('confirm-pin'),
                      onPressed: _sending ? null : _sendPin,
                      icon: const Icon(Icons.push_pin),
                      label: const Text('SAVE PIN'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (_pinMode)
                    _RoundButton(
                      icon: Icons.close,
                      tooltip: 'Cancel',
                      onTap: () => setState(() {
                        _pinMode = false;
                        _pin = null;
                      }),
                    )
                  else if (!notFound)
                    _RoundButton(
                      icon: Icons.edit_location_alt_outlined,
                      tooltip: 'Wrong spot? Place a pin',
                      onTap: () => setState(() => _pinMode = true),
                    ),
                  const SizedBox(width: 8),
                  _RoundButton(
                    key: const ValueKey('recenter'),
                    icon: Icons.center_focus_strong,
                    tooltip: 'Recenter',
                    onTap: () => _ctrl.fitCamera(fit),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A map-sized card in place of the map (locating, no map file, …).
class _MapCard extends StatelessWidget {
  final double height;
  final IconData? icon;
  final bool busy;
  final String title;
  final String message;
  const _MapCard({required this.height, this.icon, this.busy = false, required this.title, required this.message});

  @override
  Widget build(BuildContext context) => Container(
    height: height * 0.6,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: context.palette.bgElevated,
      borderRadius: BorderRadius.circular(QuiccRadius.md),
      border: Border.all(color: context.palette.borderSoft),
    ),
    child: Row(
      children: [
        if (busy)
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))
        else
          Icon(icon, size: 32, color: context.palette.textMuted),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(message, style: TextStyle(color: context.palette.textSecondary)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Banner extends StatelessWidget {
  final String text;
  const _Banner({required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: QuiccColors.brand900.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(QuiccRadius.sm),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _RoundButton({super.key, required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
    color: context.palette.bgSurface,
    shape: const CircleBorder(),
    elevation: 2,
    child: IconButton(tooltip: tooltip, icon: Icon(icon, color: QuiccColors.brand400), onPressed: onTap),
  );
}
