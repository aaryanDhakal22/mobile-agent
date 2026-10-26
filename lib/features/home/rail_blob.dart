import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/animation.dart';
import 'package:flutter/rendering.dart';

/// The selected-destination highlight (1.6.0): a soft pill that, when another
/// destination is picked, stretches toward it — the leading edge races ahead,
/// the trailing edge follows later, the middle thins like a drop of goo — and
/// lands with a little squash.
///
/// Geometry is in the rail's destination area: [from] / [to] are the pill's
/// vertical extents (top, bottom) at rest; [t] runs 0 → 1 linearly.
class BlobGeometry {
  BlobGeometry._();

  /// The leading edge is there by this point of the move…
  static const double leadEnd = 0.52;

  /// …the trailing edge starts a moment later and lands here…
  static const double trailStart = 0.1;
  static const double trailEnd = 0.74;

  /// …then the squash plays out to the end.
  static const double squashStart = 0.66;

  static const Curve _lead = Cubic(0.3, 0.0, 0.15, 1.0);
  static const Curve _trail = Curves.easeInOutCubic;

  static double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  /// The blob's (top, bottom, width scale) at [t].
  static (double top, double bottom, double widthScale) at(
    double t,
    (double, double) from,
    (double, double) to, {
    required bool full,
  }) {
    final (fTop, fBot) = from;
    final (tTop, tBot) = to;
    if (!full) {
      final k = Curves.easeOut.transform(t);
      return (lerpDouble(fTop, tTop, k)!, lerpDouble(fBot, tBot, k)!, 1.0);
    }
    final down = tTop >= fTop;
    final lead = _lead.transform(_seg(t, 0, leadEnd));
    final trail = _trail.transform(_seg(t, trailStart, trailEnd));
    var top = lerpDouble(fTop, tTop, down ? trail : lead)!;
    var bottom = lerpDouble(fBot, tBot, down ? lead : trail)!;
    var widthScale = 1.0;
    // Squash on arrival: a damped wobble around the resting size, flatter and
    // wider first, then a touch taller, then still.
    final s = _seg(t, squashStart, 1);
    if (s > 0 && s < 1) {
      final a = math.sin(2 * math.pi * s) * (1 - s) * 0.13;
      final mid = (top + bottom) / 2;
      final half = (bottom - top) / 2 * (1 - a);
      top = mid - half;
      bottom = mid + half;
      widthScale = 1 + a * 0.9;
    }
    return (top, bottom, widthScale);
  }
}

class RailBlobPainter extends CustomPainter {
  final double top;
  final double bottom;

  /// The pill's resting width and height.
  final double width;
  final double restHeight;
  final double widthScale;
  final Color color;
  final double opacity;

  const RailBlobPainter({
    required this.top,
    required this.bottom,
    required this.width,
    required this.restHeight,
    required this.color,
    this.widthScale = 1,
    this.opacity = 1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final len = bottom - top;
    if (len <= 0) return;
    // Stretched = thinner (it keeps roughly its area), the middle thinner still.
    final stretch = ((len - restHeight) / restHeight).clamp(0.0, 1.5);
    final w = width * widthScale * math.max(0.66, math.sqrt(restHeight / math.max(len, restHeight)));
    final cx = size.width / 2;
    final paint = Paint()
      ..color = color.withValues(alpha: color.a * opacity)
      ..isAntiAlias = true;
    final r = w / 2;
    if (len <= w + 0.5 || stretch < 0.02) {
      final rect = Rect.fromLTRB(cx - r, top, cx + r, bottom);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(math.min(rect.width, rect.height) / 2)), paint);
      return;
    }
    // A peanut: round caps joined by a waist.
    final neck = r * (1 - 0.28 * math.min(1.0, stretch));
    final capTop = top + r;
    final capBot = bottom - r;
    final mid = (capTop + capBot) / 2;
    final reach = (capBot - capTop) / 2;
    final path = Path()
      ..moveTo(cx - r, capTop)
      ..arcToPoint(Offset(cx + r, capTop), radius: Radius.circular(r))
      ..cubicTo(cx + r, capTop + reach * 0.55, cx + neck, mid - reach * 0.45, cx + neck, mid)
      ..cubicTo(cx + neck, mid + reach * 0.45, cx + r, capBot - reach * 0.55, cx + r, capBot)
      ..arcToPoint(Offset(cx - r, capBot), radius: Radius.circular(r))
      ..cubicTo(cx - r, capBot - reach * 0.55, cx - neck, mid + reach * 0.45, cx - neck, mid)
      ..cubicTo(cx - neck, mid - reach * 0.45, cx - r, capTop + reach * 0.55, cx - r, capTop)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(RailBlobPainter old) =>
      old.top != top ||
      old.bottom != bottom ||
      old.width != width ||
      old.restHeight != restHeight ||
      old.widthScale != widthScale ||
      old.color != color ||
      old.opacity != opacity;
}
