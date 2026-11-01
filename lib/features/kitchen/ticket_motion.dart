import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/time.dart';

// "Bubbly" Kitchen (1.9.0, 2.0.0): a new ticket pops in, a READY ticket
// implodes while the others slide springily to their new places, and the big buttons squish
// when pressed (common/squish.dart). Everything follows Motion (lib/core/motion.dart): durations
// through Motion.scale; with Motion off only fades, no transforms.

/// The pop: 0 → 110 % → 95 % → 100 % with a small jiggle.
const Duration kTicketPop = Duration(milliseconds: 520);

/// A READY ticket implodes (2.0.0, owner): a squash, then it collapses to a
/// point in about 280 ms, and a small green ✓ bursts where it vanished.
const Duration kTicketExit = Duration(milliseconds: 460);

/// The part of [kTicketExit] the collapse takes; the ✓ burst finishes it.
const double kTicketCollapseEnd = 0.62;

/// The others slide to their new places, springy: past the spot a little,
/// one wobble, settled (2.0.0).
const Duration kTicketGlide = Duration(milliseconds: 450);

/// The slide's spring: overshoots about 11 %, then about 1 %, then rests.
class SpringyCurve extends Curve {
  const SpringyCurve();

  @override
  double transformInternal(double t) => 1 - math.exp(-5.5 * t) * math.cos(8.0 * t);
}

/// Only a ticket accepted this recently pops (an older one that shows up
/// with a refresh just appears).
const Duration kPopRecent = Duration(seconds: 60);

/// The ids Kitchen has shown, for the whole session (a pane switch builds the
/// board again; nothing may pop then). Seeded with the board on the first
/// load, so nothing pops when the app starts either.
class KitchenSeen {
  final Set<String> _ids = {};
  bool _seeded = false;

  bool get seeded => _seeded;

  void seed(Iterable<String> ids) {
    _ids.addAll(ids);
    _seeded = true;
  }

  /// True the first time [o] is seen, if it was accepted within
  /// [kPopRecent] of [now]; every later call says false.
  bool popFirstTime(StoredOrder o, DateTime now) {
    if (!_seeded || !_ids.add(o.id)) return false;
    final at = o.status.acceptedAt;
    // abs(): a tablet clock a little behind the Pi's.
    return at != null && now.difference(at).abs() <= kPopRecent;
  }
}

final kitchenSeenProvider = Provider<KitchenSeen>((_) => KitchenSeen());

/// Pops [child] in once when [pop] is true at first build: a scale and a
/// small jiggle (Motion on), or a fade (Motion off). At rest it draws its
/// child unchanged.
class TicketPop extends ConsumerStatefulWidget {
  final bool pop;
  final Widget child;
  const TicketPop({super.key, required this.pop, required this.child});

  @override
  ConsumerState<TicketPop> createState() => _TicketPopState();
}

class _TicketPopState extends ConsumerState<TicketPop> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  bool _started = false;

  static final _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.10).chain(CurveTween(curve: Curves.easeOutCubic)), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.10, end: 0.95).chain(CurveTween(curve: Curves.easeInOut)), weight: 25),
    TweenSequenceItem(tween: Tween(begin: 0.95, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 35),
  ]);

  /// Turns: a small wobble (about ±1.5°) that settles at 0.
  static final _jiggle = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.004), weight: 30),
    TweenSequenceItem(tween: Tween(begin: 0.004, end: -0.003), weight: 25),
    TweenSequenceItem(tween: Tween(begin: -0.003, end: 0.0015), weight: 25),
    TweenSequenceItem(tween: Tween(begin: 0.0015, end: 0.0), weight: 20),
  ]);

  static final _fadeIn = CurveTween(curve: const Interval(0, 0.3, curve: Curves.easeOut));

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, value: widget.pop ? 0 : 1);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final motion = Motion.of(context, ref);
    if (widget.pop && !_started) {
      _started = true;
      _c.duration = motion.full ? motion.scale(kTicketPop) : motion.fade;
      _c.forward(from: 0);
    }
    if (!motion.full) {
      // Motion off: a fade, never a transform.
      return FadeTransition(key: const ValueKey('ticket-pop-fade'), opacity: _c, child: widget.child);
    }
    return ScaleTransition(
      key: const ValueKey('ticket-pop'),
      scale: _scale.animate(_c),
      child: RotationTransition(
        turns: _jiggle.animate(_c),
        child: FadeTransition(opacity: _fadeIn.animate(_c), child: widget.child),
      ),
    );
  }
}

// --- the board: FLIP glide + exit ghosts ----------------------------------------

class _Track {
  /// Where the slot was laid out at its last paint, relative to the grid.
  Offset? pos;
  Size size = Size.zero;

  /// The glide: from [from] (offset from [pos]) to zero, starting [start].
  Offset from = Offset.zero;
  Duration? start;
  _RenderFlipSlot? box;

  /// The glide offset it was last drawn with.
  Offset drawn = Offset.zero;
}

/// Measures every ticket's place on the board at paint time and, when a
/// ticket's place changed, draws it gliding from the old place to the new one
/// (FLIP: first, last, invert, play) — relative to the board, so scrolling
/// doesn't count. One ticker for all of them.
class FlipController {
  final TickerProvider vsync;
  FlipController(this.vsync);

  bool enabled = true;
  Duration duration = kTicketGlide;
  Curve curve = const SpringyCurve();
  RenderBox? _grid;
  final Map<Object, _Track> _tracks = {};
  Ticker? _ticker;

  static Duration get _now => SchedulerBinding.instance.currentFrameTimeStamp;

  double _t(_Track t, Duration now) {
    final start = t.start;
    if (start == null || duration <= Duration.zero) return 1;
    return ((now - start).inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
  }

  Offset _shift(_Track t, Duration now) {
    if (t.start == null) return Offset.zero;
    final k = _t(t, now);
    if (k >= 1) return Offset.zero;
    return t.from * (1 - curve.transform(k));
  }

  /// The glide offset the ticket was last drawn with (tests).
  @visibleForTesting
  Offset shiftOf(Object id) => _tracks[id]?.drawn ?? Offset.zero;

  /// Where [id] was last laid out on the board (for its exit ghost).
  Rect? rectOf(Object id) {
    final t = _tracks[id];
    final p = t?.pos;
    return p == null ? null : p & t!.size;
  }

  void forget(Object id) => _tracks.remove(id);

  Offset _paintShift(Object id, _RenderFlipSlot box) {
    final track = _tracks.putIfAbsent(id, _Track.new)..box = box;
    final grid = _grid;
    final now = _now;
    if (grid == null || !grid.attached || !box.attached) return track.drawn = _shift(track, now);
    final pos = box.localToGlobal(Offset.zero, ancestor: grid);
    final last = track.pos;
    if (last != null && enabled && (last - pos).distance > 0.5) {
      // From where it was drawn (mid-glide included) to its new place.
      final drawn = last + _shift(track, now);
      track
        ..from = drawn - pos
        ..start = now;
      SchedulerBinding.instance.addPostFrameCallback((_) => _ensureTicking());
    } else if (!enabled) {
      track.start = null;
    }
    track
      ..pos = pos
      ..size = box.size;
    return track.drawn = _shift(track, now);
  }

  bool _disposed = false;

  void _ensureTicking() {
    if (_disposed) return;
    final ticker = _ticker ??= vsync.createTicker(_onTick);
    if (!ticker.isActive) ticker.start();
  }

  void _onTick(Duration _) {
    final now = _now;
    var active = false;
    for (final t in _tracks.values) {
      if (t.start == null) continue;
      t.box?.markNeedsPaint();
      if (_t(t, now) >= 1) {
        t.start = null;
      } else {
        active = true;
      }
    }
    if (!active) _ticker?.stop();
  }

  void dispose() {
    _disposed = true;
    _ticker?.dispose();
    _ticker = null;
  }
}

/// The board's box: the slots measure their places relative to it.
class _FlipGrid extends SingleChildRenderObjectWidget {
  final FlipController controller;
  const _FlipGrid({required this.controller, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFlipGrid(controller);

  @override
  void updateRenderObject(BuildContext context, _RenderFlipGrid renderObject) => renderObject.controller = controller;
}

class _RenderFlipGrid extends RenderProxyBox {
  FlipController controller;
  _RenderFlipGrid(this.controller);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    controller._grid = this;
  }

  @override
  void detach() {
    if (identical(controller._grid, this)) controller._grid = null;
    super.detach();
  }
}

/// One ticket's place on the board; paints its child shifted while it glides.
class FlipSlot extends SingleChildRenderObjectWidget {
  final Object id;
  final FlipController controller;
  const FlipSlot({super.key, required this.id, required this.controller, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFlipSlot(id, controller);

  @override
  // ignore: library_private_types_in_public_api
  void updateRenderObject(BuildContext context, _RenderFlipSlot renderObject) {
    renderObject
      ..id = id
      ..controller = controller;
  }
}

class _RenderFlipSlot extends RenderProxyBox {
  Object id;
  FlipController controller;
  _RenderFlipSlot(this.id, this.controller);

  @override
  void paint(PaintingContext context, Offset offset) {
    final shift = controller._paintShift(id, this);
    super.paint(context, offset + shift);
  }
}

class _Ghost {
  final StoredOrder order;
  final Rect rect;
  final AnimationController c;
  _Ghost(this.order, this.rect, this.c);
}

/// The Kitchen board (1.9.0): tickets dealt into [columns] masonry columns
/// (most urgent first, read across — [dealIntoColumns]), with
///
///  * a new ticket popping in ([TicketPop], [KitchenSeen]);
///  * a ticket that leaves (READY) kept as a ghost where it was, shrinking
///    to 85 % and fading ([kTicketExit]) — it can't be touched;
///  * the others gliding to their new places ([FlipSlot], [kTicketGlide]) —
///    leaving one deals every later ticket into another column.
///
/// Motion off: the ghost only fades and nothing glides.
class AnimatedKitchenGrid extends ConsumerStatefulWidget {
  final List<StoredOrder> orders;
  final int columns;
  final double gap;

  /// Builds a ticket; [ghost] = the leaving copy (give it no ids tests or
  /// the ticket itself use as keys).
  final Widget Function(BuildContext context, StoredOrder order, bool ghost) itemBuilder;

  /// Deals [orders] into columns (kitchen_pane's [dealIntoColumns]).
  final List<List<StoredOrder>> Function(List<StoredOrder> orders, int columns) deal;

  const AnimatedKitchenGrid({
    super.key,
    required this.orders,
    required this.columns,
    required this.gap,
    required this.itemBuilder,
    required this.deal,
  });

  @override
  ConsumerState<AnimatedKitchenGrid> createState() => AnimatedKitchenGridState();
}

class AnimatedKitchenGridState extends ConsumerState<AnimatedKitchenGrid> with TickerProviderStateMixin {
  late final FlipController flip = FlipController(this);
  final Map<String, _Ghost> _ghosts = {};
  Motion _motion = const Motion(full: true, speed: 1);

  /// The leaving tickets still on screen (tests).
  @visibleForTesting
  Iterable<String> get ghosts => _ghosts.keys;

  @override
  void didUpdateWidget(AnimatedKitchenGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    final now = {for (final o in widget.orders) o.id};
    for (final o in old.orders) {
      if (now.contains(o.id)) continue;
      final rect = flip.rectOf(o.id);
      flip.forget(o.id);
      if (rect == null || rect.isEmpty || _ghosts.containsKey(o.id)) continue;
      final c = AnimationController(vsync: this, duration: _motion.full ? _motion.scale(kTicketExit) : _motion.fade);
      final g = _Ghost(o, rect, c);
      _ghosts[o.id] = g;
      c.forward().whenComplete(() {
        if (!mounted || !identical(_ghosts[o.id], g)) return;
        setState(() => _ghosts.remove(o.id));
        c.dispose();
      });
    }
    // Back before its ghost finished (e.g. READY undone): no ghost.
    for (final id in _ghosts.keys.where(now.contains).toList()) {
      _ghosts.remove(id)?.c.dispose();
    }
  }

  @override
  void dispose() {
    for (final g in _ghosts.values) {
      g.c.dispose();
    }
    flip.dispose();
    super.dispose();
  }

  Widget _ghost(BuildContext context, String id, _Ghost g) {
    final card = widget.itemBuilder(context, g.order, true);
    if (!_motion.full) {
      // Motion off: a quick fade, nothing else.
      return Positioned.fromRect(
        key: ValueKey('kitchen-ghost-$id'),
        rect: g.rect,
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: FadeTransition(opacity: Tween<double>(begin: 1, end: 0).animate(g.c), child: card),
          ),
        ),
      );
    }
    return Positioned.fromRect(
      key: ValueKey('kitchen-ghost-$id'),
      rect: g.rect,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: AnimatedBuilder(
            animation: g.c,
            builder: (context, child) {
              final v = g.c.value;
              final (sx, sy, fade) = implodeAt(v);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  if (fade > 0)
                    Positioned.fill(
                      child: Opacity(
                        opacity: fade,
                        child: Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.diagonal3Values(sx, sy, 1),
                          child: child,
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: Center(child: ReadyBurst(t: burstAt(v))),
                  ),
                ],
              );
            },
            child: card,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _motion = Motion.of(context, ref);
    flip
      ..enabled = _motion.full
      ..duration = _motion.scale(kTicketGlide);
    // Seeded by the Kitchen pane on the first load (nothing pops before).
    final seen = ref.read(kitchenSeenProvider);
    final now = timeNow();
    final columns = widget.deal(widget.orders, math.max(1, widget.columns));
    final grid = _FlipGrid(
      controller: flip,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var c = 0; c < columns.length; c++) ...[
            if (c > 0) SizedBox(width: widget.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final so in columns[c])
                    Padding(
                      key: ValueKey('slot-${so.id}'),
                      padding: EdgeInsets.only(bottom: widget.gap),
                      child: FlipSlot(
                        id: so.id,
                        controller: flip,
                        // Each ticket repaints alone (its timer, the
                        // customer-waiting halo).
                        child: RepaintBoundary(
                          child: TicketPop(
                            pop: seen.popFirstTime(so, now),
                            child: widget.itemBuilder(context, so, false),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    if (_ghosts.isEmpty) return Stack(clipBehavior: Clip.none, children: [grid]);
    return Stack(
      clipBehavior: Clip.none,
      children: [grid, for (final e in _ghosts.entries) _ghost(context, e.key, e.value)],
    );
  }
}

/// The implode at [v] (0..1 of [kTicketExit]): the ticket's x / y scale and
/// opacity. A squash first (wider, flatter), then it collapses to a point by
/// [kTicketCollapseEnd], fading at the very end.
(double, double, double) implodeAt(double v) {
  const squashEnd = 0.18;
  if (v <= squashEnd) {
    final k = Curves.easeOut.transform(v / squashEnd);
    return (1 + 0.05 * k, 1 - 0.10 * k, 1);
  }
  if (v >= kTicketCollapseEnd) return (0, 0, 0);
  final k = Curves.easeInBack.transform((v - squashEnd) / (kTicketCollapseEnd - squashEnd)).clamp(-0.2, 1.0);
  final sx = (1.05 * (1 - k)).clamp(0.0, 1.2);
  final sy = (0.90 * (1 - k)).clamp(0.0, 1.2);
  final fade = v < kTicketCollapseEnd - 0.12 ? 1.0 : ((kTicketCollapseEnd - v) / 0.12).clamp(0.0, 1.0);
  return (sx, sy, fade);
}

/// The ✓ burst's own time (0..1) at [v]: it starts as the ticket is nearly
/// gone and runs to the end; 0 before.
double burstAt(double v) {
  const start = kTicketCollapseEnd - 0.12;
  if (v <= start) return 0;
  return ((v - start) / (1 - start)).clamp(0.0, 1.0);
}

/// The small green ✓ burst where a READY ticket vanished: a check that pops
/// to full size and fades, with a ring and a few dots flying out.
class ReadyBurst extends StatelessWidget {
  final double t;
  const ReadyBurst({super.key, required this.t});

  static const _green = Color(0xFF34C77B);

  @override
  Widget build(BuildContext context) {
    if (t <= 0 || t >= 1) return const SizedBox.shrink();
    final pop = Curves.easeOutBack.transform(math.min(1, t / 0.45));
    final fade = t < 0.6 ? 1.0 : (1 - (t - 0.6) / 0.4);
    return IgnorePointer(
      child: Opacity(
        opacity: fade.clamp(0.0, 1.0),
        child: SizedBox(
          width: 120,
          height: 120,
          child: CustomPaint(
            key: const ValueKey('ready-burst'),
            painter: _BurstPainter(t),
            child: Center(
              child: Transform.scale(
                scale: 0.4 + 0.6 * pop,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, color: Color(0xFFFFFFFF), size: 32),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  final double t;
  _BurstPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final k = Curves.easeOut.transform(t);
    final ring = Paint()
      ..color = ReadyBurst._green.withValues(alpha: (1 - k) * 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(c, 24 + 30 * k, ring);
    final dot = Paint()..color = ReadyBurst._green.withValues(alpha: 1 - k);
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3 + math.pi / 6;
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * (28 + 28 * k), 4 * (1 - k) + 1, dot);
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.t != t;
}
