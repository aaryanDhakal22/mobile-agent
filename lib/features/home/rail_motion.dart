import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The rail's mode-switch choreography (1.6.0), in designed seconds (speed
/// 1.0). The controller runs linearly over [total]; everything below is a
/// pure function of the designed time, so a slower or faster speed setting
/// just stretches the clock.
///
///   0.00 s  the icons under the q let go, bottom one first, and fall under
///           gravity, each tumbling round its off-centre centre of mass;
///   0.45 s  the new mode's icons pop in top to bottom, 70 ms apart:
///           0 → 120 % (fast) → 90 % (slow) → 110 % (slower) → 100 % (slow).
class RailSwitchTiming {
  RailSwitchTiming._();

  /// Each falling icon lets go this long after the one below it.
  static const double fallStagger = 0.045;

  /// The first new icon starts popping in.
  static const double enterStart = 0.45;

  /// Between two new icons.
  static const double enterStagger = 0.07;

  /// One icon's bounce.
  static const double bounce = 0.54;

  /// Gravity as a multiple of the rail's height per s² — the same feel on any
  /// screen. (On the 800 px tablet ≈ 5 200 px/s².)
  static const double gravity = 7.6;

  /// A small upward pop as an icon lets go (in rail heights per second).
  static const double kick = 0.18;

  /// The whole switch for [count] new icons.
  static double total(int count) => enterStart + enterStagger * math.max(0, count - 1) + bounce;

  static Duration duration(int count) => Duration(microseconds: (total(count) * 1e6).round());
}

/// 0 → 1.2 → 0.9 → 1.1 → 1.0 with eased segments (fast, slow, slower, slow).
final Animatable<double> kRailBounce = TweenSequence<double>([
  TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.2).chain(CurveTween(curve: Curves.easeOutCubic)), weight: 120),
  TweenSequenceItem(tween: Tween(begin: 1.2, end: 0.9).chain(CurveTween(curve: Curves.easeInOutSine)), weight: 140),
  TweenSequenceItem(tween: Tween(begin: 0.9, end: 1.1).chain(CurveTween(curve: Curves.easeInOutSine)), weight: 170),
  TweenSequenceItem(tween: Tween(begin: 1.1, end: 1.0).chain(CurveTween(curve: Curves.easeInOutSine)), weight: 150),
]);

/// A falling icon's body: where its centre of mass sits (as a fraction of the
/// icon's size, off the visual centre) — which way and how hard it tumbles.
@immutable
class FallBody {
  /// Centre of mass offset, −0.2 … 0.2 of the icon's width / height.
  final double comX;
  final double comY;

  const FallBody(this.comX, this.comY);

  /// Random-looking but the same every time for the same [seed] (the label),
  /// so the fall can be tested and never looks "stuck" (|comX| ≥ 0.07).
  factory FallBody.seeded(String seed) {
    var h = 0x811c9dc5;
    for (final c in seed.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    final a = (h & 0xffff) / 0xffff; // 0..1
    final b = ((h >> 16) & 0xffff) / 0xffff;
    final sign = (h & 0x10000) == 0 ? -1.0 : 1.0;
    final x = sign * (0.07 + a * 0.13);
    final y = (b - 0.5) * 0.2;
    return FallBody(x, y);
  }

  /// Angular acceleration (rad/s²) the off-centre mass gives it as it tips
  /// off its slot: more offset, faster tumble.
  double get spin => comX * 70;
}

/// Where a falling icon is [t] designed seconds after it let go.
@immutable
class FallPose {
  final double dx;
  final double dy;
  final double angle;
  const FallPose(this.dx, this.dy, this.angle);

  static const rest = FallPose(0, 0, 0);

  /// [height] is the rail's height (gravity scales with it).
  factory FallPose.at(double t, FallBody body, double height) {
    if (t <= 0) return rest;
    final g = RailSwitchTiming.gravity * height;
    final v0 = RailSwitchTiming.kick * height;
    final dy = -v0 * t + 0.5 * g * t * t;
    // It tips toward its heavy side, drifting a little that way.
    final angle = body.comX * 2.2 * t + 0.5 * body.spin * t * t;
    final dx = body.comX * 0.25 * height * t;
    return FallPose(dx, dy, angle);
  }
}
