import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../theme/quicc_colors.dart';

const double _metersPerMile = 1609.344;

/// 3700 m → "2.3 mi" (one decimal under 10 mi).
String milesLabel(int meters) {
  final mi = meters / _metersPerMile;
  return mi >= 10 ? '${mi.round()} mi' : '${mi.toStringAsFixed(1)} mi';
}

/// 420 s → "7 min" (at least 1 min).
String driveMinutesLabel(int seconds) {
  final m = (seconds / 60).round();
  if (m >= 60) return '${m ~/ 60} h ${m % 60} min';
  return '${m < 1 ? 1 : m} min';
}

/// "2.3 mi · 7 min" for a located order with a drive, else null.
String? driveLabel(OrderGeo? g) {
  if (g == null || g.state != GeoState.located || !g.hasDrive) return null;
  final parts = [if (g.distanceM > 0) milesLabel(g.distanceM), if (g.durationS > 0) driveMinutesLabel(g.durationS)];
  return parts.join(' · ');
}

/// The location hint for an order without a drive label: "locating…" while
/// main is still looking, "no location" when it gave up (null = nothing to
/// say).
String? geoHint(OrderGeo? g) => switch (g?.state) {
  null || GeoState.pending => 'locating…',
  GeoState.notFound || GeoState.unavailable => 'no location',
  GeoState.located => null,
};

/// A small tag: amber "approx", red "outside area", grey hints.
class GeoTag extends StatelessWidget {
  final String text;
  final Color color;
  final double fontSize;
  const GeoTag(this.text, {super.key, required this.color, this.fontSize = 12});

  /// Amber: the address matched only roughly (street / zip level).
  const GeoTag.approx({super.key, this.fontSize = 12}) : text = 'approx', color = QuiccColors.statusFiring;

  /// Red: farther than the store's delivery radius.
  const GeoTag.outside({super.key, this.fontSize = 12}) : text = 'outside area', color = QuiccColors.statusVoided;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// The tags an order's location earns (none when it's exact and inside).
List<Widget> geoTags(OrderGeo? g, {double fontSize = 12}) => [
  if (g != null && g.isApprox) GeoTag.approx(fontSize: fontSize),
  if (g != null && g.state == GeoState.located && g.outsideArea) GeoTag.outside(fontSize: fontSize),
];

/// "931 Taylor Avenue" — the street part of an address (for chips).
String streetOf(StoredOrder o) {
  final a = o.order.fulfillment.address;
  if (a == null || a.isEmpty) return 'No address';
  final l1 = a.line1.trim();
  return l1.isNotEmpty ? l1 : a.oneLine;
}
