import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../theme/quicc_colors.dart';

/// A yellow "lava lamp" behind [child] (1.6.0, the AUTO button): four soft
/// amber blobs drift, stretch and merge in a slow loop, spilling [bleed]
/// past the child so they read as a halo around it. Speed follows the Motion
/// setting; with Motion off (or Android's "remove animations") it is one
/// still, soft glow. [active] false draws nothing (nothing for AUTO to do).
///
/// Cheap by design: one ticker, a [RepaintBoundary] so only the glow's own
/// layer repaints, and the blur runs over a button-sized area.
class LavaGlow extends ConsumerStatefulWidget {
  final Widget child;
  final bool active;
  final EdgeInsets bleed;
  final Color color;

  /// One full loop at speed 1.0.
  static const Duration period = Duration(seconds: 12);

  const LavaGlow({
    super.key,
    required this.child,
    this.active = true,
    this.bleed = const EdgeInsets.fromLTRB(24, 18, 10, 14),
    this.color = QuiccColors.statusFiring,
  });

  @override
  ConsumerState<LavaGlow> createState() => _LavaGlowState();
}

class _LavaGlowState extends ConsumerState<LavaGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: LavaGlow.period);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Runs the loop only while it is visible and Motion is full.
  void _sync(bool animate, Duration period) {
    if (!animate) {
      if (_ctrl.isAnimating) _ctrl.stop();
      return;
    }
    if (_ctrl.duration != period) {
      _ctrl.duration = period;
      if (_ctrl.isAnimating) _ctrl.repeat();
    }
    if (!_ctrl.isAnimating) _ctrl.repeat();
  }

  @override
  Widget build(BuildContext context) {
    final m = Motion.of(context, ref);
    final animate = widget.active && m.full;
    _sync(animate, m.scale(LavaGlow.period));
    final b = widget.bleed;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (widget.active)
          Positioned(
            left: -b.left,
            top: -b.top,
            right: -b.right,
            bottom: -b.bottom,
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('lava-glow'),
                  painter: LavaPainter(
                    // Still glow: a pleasant frame where the blobs overlap.
                    progress: animate ? _ctrl : const AlwaysStoppedAnimation(0.18),
                    color: widget.color,
                    bleed: b,
                  ),
                ),
              ),
            ),
          ),
        widget.child,
      ],
    );
  }
}

/// One blob's loop. Blobs travel round the child on an ellipse just outside
/// its edge; [laps] is an integer (negative = the other way), so t = 0 and
/// t = 1 match and the loop never jumps.
class _Blob {
  final int laps; // trips round the child per period
  final double phase; // start angle (fraction of a turn)
  final double r; // radius (fraction of the child's height)
  final int breaths; // radius pulses per period
  final double pulse; // radius breathing
  final double wobble; // in/out drift off the ellipse (fraction of r)
  const _Blob(this.laps, this.phase, this.r, this.breaths, this.pulse, this.wobble);
}

const _blobs = [
  _Blob(1, 0.00, 0.42, 2, 0.18, 0.35),
  _Blob(-1, 0.30, 0.36, 3, 0.22, 0.30),
  _Blob(2, 0.55, 0.30, 1, 0.20, 0.40),
  _Blob(-2, 0.80, 0.34, 2, 0.16, 0.25),
];

/// Paints the blobs as radial gradients, blurred together and then given a
/// gentle alpha contrast so touching blobs merge like wax (the "goo" trick),
/// at a capped opacity so the label on top stays easy to read. [bleed] says
/// where the child sits inside the painted box.
class LavaPainter extends CustomPainter {
  final Animation<double> progress;
  final Color color;
  final EdgeInsets bleed;
  LavaPainter({required this.progress, required this.color, this.bleed = EdgeInsets.zero})
    : super(repaint: progress);

  static const double _maxOpacity = 0.8;

  // alpha' = 2.2·a − 0.2: thin tails fade out, overlaps fuse into one soft
  // shape (a gentle goo, not hard-edged).
  static const _goo = ColorFilter.matrix(<double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 2.2, -0.2 * 255, //
  ]);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = progress.value;
    final bounds = Offset.zero & size;
    final child = bleed.deflateRect(bounds);
    final ch = child.height <= 0 ? size.height : child.height;
    final sigma = ch * 0.12;
    final turn = 2 * math.pi;

    canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, _maxOpacity));
    canvas.saveLayer(bounds, Paint()..colorFilter = _goo);
    canvas.saveLayer(bounds, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma));
    for (final b in _blobs) {
      final r = ch * b.r * (1 + b.pulse * math.sin(turn * (b.breaths * t + b.phase)));
      final a = turn * (b.laps * t + b.phase);
      final out = 1 + b.wobble * r / ch * math.sin(turn * (2 * t + b.phase * 3));
      var c = Offset(
        child.center.dx + (child.width / 2) * out * math.cos(a),
        child.center.dy + (ch / 2 + r * 0.2) * out * math.sin(a),
      );
      // Stay a blur's width inside the box, so no edge of the glow is ever
      // cut off straight (a blob near a tight edge slides in behind the
      // child instead).
      final m = r + 1.5 * sigma;
      c = Offset(
        c.dx.clamp(math.min(m, size.width / 2), math.max(size.width - m, size.width / 2)),
        c.dy.clamp(math.min(m, size.height / 2), math.max(size.height - m, size.height / 2)),
      );
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0.85), color.withValues(alpha: 0)],
            stops: const [0, 0.5, 1],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
    canvas
      ..restore()
      ..restore()
      ..restore();
  }

  @override
  bool shouldRepaint(LavaPainter old) => old.progress != progress || old.color != color || old.bleed != bleed;
}

/// A soft yellow outline that pulses around [child] while [active] — the
/// Deliveries screen marks the deliveries someone wants you to look at
/// (e.g. one near the next driver's run). Still (no pulse) with Motion off.
class HighlightPulse extends ConsumerStatefulWidget {
  final bool active;
  final Widget child;
  final BorderRadius borderRadius;

  static const Duration period = Duration(milliseconds: 1400);

  const HighlightPulse({
    super.key,
    required this.active,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(QuiccRadius.lg)),
  });

  @override
  ConsumerState<HighlightPulse> createState() => _HighlightPulseState();
}

class _HighlightPulseState extends ConsumerState<HighlightPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: HighlightPulse.period);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      if (_ctrl.isAnimating) _ctrl.stop();
      return widget.child;
    }
    final m = Motion.of(context, ref);
    if (m.full) {
      final d = m.scale(HighlightPulse.period);
      if (_ctrl.duration != d) _ctrl.duration = d;
      if (!_ctrl.isAnimating) _ctrl.repeat(reverse: true);
    } else if (_ctrl.isAnimating) {
      _ctrl.stop();
    }
    final still = !m.full;
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, child) {
        final v = still ? 0.7 : Curves.easeInOut.transform(_ctrl.value);
        return Container(
          key: const ValueKey('highlight-glow'),
          foregroundDecoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: Border.all(color: QuiccColors.statusFiring.withValues(alpha: 0.55 + 0.45 * v), width: 2.5),
          ),
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            boxShadow: [
              BoxShadow(
                color: QuiccColors.statusFiring.withValues(alpha: 0.18 + 0.32 * v),
                blurRadius: 8 + 10 * v,
                spreadRadius: 1 + 2 * v,
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }
}
