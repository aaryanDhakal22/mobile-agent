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
  GeoState.check => 'check address',
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

  /// Amber, quiet: main placed a corrected address, not the one typed
  /// (1.7.2, geo `corrected`).
  const GeoTag.corrected({super.key, this.fontSize = 12})
    : text = 'address corrected',
      color = QuiccColors.statusFiring;

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
  if (g != null && g.corrected) GeoTag.corrected(fontSize: fontSize),
];

/// "931 Taylor Avenue" — the street part of an address (for chips).
String streetOf(StoredOrder o) => streetLine(o.order.fulfillment.address) ?? 'No address';

/// An address's street line: line1, else the whole address (null = none).
String? streetLine(Address? a) {
  if (a == null || a.isEmpty) return null;
  final l1 = a.line1.trim();
  return l1.isNotEmpty ? l1 : a.oneLine;
}

/// Unit words: from here on an address line is the apartment / suite part.
const _unitWords = {
  'apt', 'apartment', 'unit', 'suite', 'ste', 'bldg', 'building', 'fl', 'floor', 'rm', 'room', 'lot', //
};

/// The house number + street of an address line: what comes before the first
/// comma, without an apartment / unit / suite part (a keyword right after the
/// house number is the street: "7 Unit Rd"). A port of the agent's tested
/// `order.StreetOnly` (driver report slips) — keep the two in step.
String streetOnly(String line1) {
  var s = line1;
  final comma = s.indexOf(',');
  if (comma >= 0) s = s.substring(0, comma);
  final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  for (var i = 2; i < words.length; i++) {
    final w = words[i];
    final lw = w.toLowerCase().replaceFirst(RegExp(r'[.:]+$'), '');
    if (w.startsWith('#') || _unitWords.contains(lw)) {
      words.removeRange(i, words.length);
      break;
    }
  }
  return words.join(' ');
}

/// Street suffixes and their short forms ("Street" → "St").
const _suffixes = {
  'street': 'St', 'st': 'St', 'avenue': 'Ave', 'ave': 'Ave', 'av': 'Ave', 'road': 'Rd', 'rd': 'Rd', //
  'drive': 'Dr', 'dr': 'Dr', 'lane': 'Ln', 'ln': 'Ln', 'court': 'Ct', 'ct': 'Ct', 'place': 'Pl', 'pl': 'Pl', //
  'boulevard': 'Blvd', 'blvd': 'Blvd', 'circle': 'Cir', 'cir': 'Cir', 'terrace': 'Ter', 'ter': 'Ter', //
  'parkway': 'Pkwy', 'pkwy': 'Pkwy', 'highway': 'Hwy', 'hwy': 'Hwy', 'square': 'Sq', 'sq': 'Sq', //
  'trail': 'Trl', 'trl': 'Trl', 'way': 'Way', 'pike': 'Pike', 'alley': 'Aly', 'crescent': 'Cres', //
};

/// Compass words, kept upper case ("NW") and shortened ("North" → "N").
const _compass = {
  'n': 'N', 'north': 'N', 's': 'S', 'south': 'S', 'e': 'E', 'east': 'E', 'w': 'W', 'west': 'W', //
  'ne': 'NE', 'nw': 'NW', 'se': 'SE', 'sw': 'SW', //
};

/// "TAYLOR" → "Taylor", "1ST" → "1st"; mixed case ("McCormick") stays.
String _titleCaps(String w) {
  if (w.length < 2 || w != w.toUpperCase() || w == w.toLowerCase()) return w;
  return w[0] + w.substring(1).toLowerCase();
}

/// A delivery's street for its Kitchen ticket heading (1.9.0): the house
/// number + the first one or two street words, the suffix shortened, no
/// apartment and no town — "4108 Old Court Rd, Apt 2" → "4108 Old Court",
/// "12 Main Street" → "12 Main St", a POS's "931 TAYLOR AVE" → "931 Taylor
/// Ave". Null without a house number (the ticket shows the name instead).
String? ticketStreet(Address? a) {
  final line = streetLine(a);
  if (line == null) return null;
  final words = streetOnly(line).split(' ').map((w) => w.replaceFirst(RegExp(r'[.,]+$'), '')).toList();
  if (words.length < 2 || words.first.isEmpty || !RegExp(r'^[0-9]').hasMatch(words.first)) return null;
  final out = <String>[words.first.toUpperCase()];
  final all = words.skip(1).where((w) => w.isNotEmpty).toList();
  final street = all.take(2).toList();
  for (var i = 0; i < street.length; i++) {
    final w = street[i];
    final lw = w.toLowerCase();
    // Only the street's real last word is its suffix: "4108 Old Court Rd"
    // keeps "Court" when it is cut to two words.
    if (i > 0 && i == all.length - 1 && _suffixes.containsKey(lw)) {
      out.add(_suffixes[lw]!);
    } else if (i == 0 && all.length > 1 && _compass.containsKey(lw) && !_suffixes.containsKey(all[1].toLowerCase())) {
      out.add(_compass[lw]!);
    } else {
      out.add(_titleCaps(w));
    }
  }
  return out.join(' ');
}
