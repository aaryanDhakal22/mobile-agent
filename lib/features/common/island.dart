import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_type.dart';

/// The notification island (1.9.0): every toast in the app is a small pill
/// in the top-right corner instead of a full-width bar at the bottom, so it
/// never covers SEND OUT or the driver button. Newest on top, at most
/// [kIslandMax] at once, each one fades by itself ([islandDurationFor]); a tap
/// or a swipe to the right puts it away. It is only as big as its pills:
/// the rest of the screen stays tappable.
///
/// Mounted once, above every route ([IslandHost] in `app.dart`); a context
/// with no host above it (a bare MaterialApp in a test) gets one in its root
/// Overlay. Call [Island.show] — or the old helpers `toast()` / `toastError()`,
/// which come here.
enum IslandKind { info, success, warn, error }

/// How many pills show at once; a newer one pushes the oldest out.
const int kIslandMax = 3;

/// A pill's widest (one with buttons — DETAILS / FIX IT — gets a little more).
const double kIslandMaxWidth = 360;
const double kIslandMaxWidthWithActions = 440;

/// Where the pills sit: below the status area, in from the right edge.
const double kIslandTop = 12;
const double kIslandRight = 16;

/// How long a pill stays up by itself.
Duration islandDurationFor(IslandKind k) => switch (k) {
  IslandKind.info || IslandKind.success => const Duration(milliseconds: 2500),
  IslandKind.warn => const Duration(seconds: 4),
  IslandKind.error => const Duration(seconds: 6),
};

/// A small text button inside a pill. Pressing it also puts the pill away.
@immutable
class IslandAction {
  final String label;
  final VoidCallback onPressed;
  const IslandAction(this.label, this.onPressed);
}

/// One notification.
class IslandEntry {
  final int id;

  /// The first line (the only one when there's no [body]).
  final String title;
  final String? body;
  final IslandKind kind;
  final IconData? icon;
  final List<IslandAction> actions;
  final Duration duration;

  /// Going away: the pill shrinks and fades, then leaves the list.
  bool exiting = false;
  Timer? _timer;
  Timer? _reaper;

  IslandEntry._(this.id, this.title, this.body, this.kind, this.icon, this.actions, this.duration);

  IconData get iconOrDefault =>
      icon ??
      switch (kind) {
        IslandKind.info => Icons.info_outline,
        IslandKind.success => Icons.check_circle_outline,
        IslandKind.warn => Icons.warning_amber_rounded,
        IslandKind.error => Icons.error_outline,
      };

  void _cancel() {
    _timer?.cancel();
    _reaper?.cancel();
  }
}

/// The island's list of pills. One per [IslandHost] (or per root Overlay
/// for the fallback).
class IslandController extends ChangeNotifier {
  final List<IslandEntry> _entries = []; // newest first
  int _next = 0;
  bool _disposed = false;

  /// A context under the Navigator, for DETAILS / FIX IT when the caller's
  /// own context is gone by the time they are pressed.
  BuildContext? Function()? fallbackContext;

  /// Newest first, the ones going away included.
  List<IslandEntry> get entries => List.unmodifiable(_entries);

  /// The pills not going away.
  List<IslandEntry> get live => [
    for (final e in _entries)
      if (!e.exiting) e,
  ];

  /// Shows a pill and returns its id. The same text again (still showing)
  /// moves that pill to the top and restarts its clock instead.
  int show(
    String title, {
    String? body,
    IslandKind kind = IslandKind.info,
    IconData? icon,
    List<IslandAction> actions = const [],
    Duration? duration,
  }) {
    if (_disposed) return -1;
    final b = (body == null || body.trim().isEmpty) ? null : body;
    for (final e in _entries) {
      if (!e.exiting && e.title == title && e.body == b && e.kind == kind) {
        _entries
          ..remove(e)
          ..insert(0, e);
        _arm(e);
        _changed();
        return e.id;
      }
    }
    final e = IslandEntry._(_next++, title, b, kind, icon, actions, duration ?? islandDurationFor(kind));
    _entries.insert(0, e);
    _arm(e);
    for (final old in live.skip(kIslandMax)) {
      _exit(old);
    }
    _changed();
    return e.id;
  }

  /// Puts a pill away (it shrinks and fades first).
  void dismiss(int id) {
    for (final e in _entries) {
      if (e.id == id && !e.exiting) {
        _exit(e);
        _changed();
        return;
      }
    }
  }

  /// Puts every pill away.
  void dismissAll() {
    var any = false;
    for (final e in _entries) {
      if (!e.exiting) {
        _exit(e);
        any = true;
      }
    }
    if (any) _changed();
  }

  /// Takes a pill off at once (its exit animation is done, or it was swiped).
  void remove(int id) {
    if (_disposed) return;
    final before = _entries.length;
    _entries.removeWhere((e) {
      if (e.id != id) return false;
      e._cancel();
      return true;
    });
    if (_entries.length != before) _changed();
  }

  void _arm(IslandEntry e) {
    e._timer?.cancel();
    e._timer = Timer(e.duration, () => dismiss(e.id));
  }

  void _exit(IslandEntry e) {
    e.exiting = true;
    e._timer?.cancel();
    // In case its pill never animates out (offstage, tickers muted).
    e._reaper = Timer(const Duration(seconds: 3), () => remove(e.id));
  }

  /// Rebuilds the pills — on the next frame when asked mid-build (a
  /// provider listener firing while widgets build).
  void _changed() {
    if (_disposed) return;
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
      binding.scheduleFrame();
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final e in _entries) {
      e._cancel();
    }
    _entries.clear();
    super.dispose();
  }
}

/// How to reach the island from anywhere with a context.
abstract final class Island {
  /// The island above [context] — its [IslandHost], else one in the root
  /// Overlay. Null only with neither (e.g. a context above the Navigator).
  static IslandController? maybeOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_IslandScope>();
    if (scope != null) return scope.controller;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    return overlay == null ? null : _fallbackFor(overlay);
  }

  /// Shows a pill (see [IslandController.show]).
  static void show(
    BuildContext context,
    String title, {
    String? body,
    IslandKind kind = IslandKind.info,
    IconData? icon,
    List<IslandAction> actions = const [],
    Duration? duration,
  }) => maybeOf(context)?.show(title, body: body, kind: kind, icon: icon, actions: actions, duration: duration);

  static final Expando<IslandController> _fallbacks = Expando('island');

  static IslandController _fallbackFor(OverlayState overlay) {
    final existing = _fallbacks[overlay];
    if (existing != null) return existing;
    final c = IslandController()..fallbackContext = () => overlay.mounted ? overlay.context : null;
    _fallbacks[overlay] = c;
    final entry = OverlayEntry(
      builder: (_) => _FallbackLayer(controller: c, onGone: () => _fallbacks[overlay] = null),
    );
    void insert() {
      if (overlay.mounted) overlay.insert(entry);
    }

    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => insert());
      binding.scheduleFrame();
    } else {
      insert();
    }
    return c;
  }
}

class _IslandScope extends InheritedWidget {
  final IslandController controller;
  const _IslandScope({required this.controller, required super.child});

  @override
  bool updateShouldNotify(_IslandScope old) => controller != old.controller;
}

/// Hosts the island over [child] (the app's routes). Put it above the
/// Navigator and below anything the island must never cover (the ringing
/// new-order alert).
class IslandHost extends StatefulWidget {
  final Widget child;

  /// For DETAILS / FIX IT once the caller's own screen is gone.
  final GlobalKey<NavigatorState>? navigatorKey;

  const IslandHost({super.key, required this.child, this.navigatorKey});

  @override
  State<IslandHost> createState() => _IslandHostState();
}

class _IslandHostState extends State<IslandHost> {
  final IslandController _controller = IslandController();

  @override
  void initState() {
    super.initState();
    _controller.fallbackContext = () => widget.navigatorKey?.currentContext;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _IslandScope(
    controller: _controller,
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IslandLayer(controller: _controller),
      ],
    ),
  );
}

/// The fallback island in a root Overlay; it owns its controller.
class _FallbackLayer extends StatefulWidget {
  final IslandController controller;
  final VoidCallback onGone;
  const _FallbackLayer({required this.controller, required this.onGone});

  @override
  State<_FallbackLayer> createState() => _FallbackLayerState();
}

class _FallbackLayerState extends State<_FallbackLayer> {
  @override
  void dispose() {
    widget.onGone();
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [IslandLayer(controller: widget.controller)],
  );
}

/// The pills, top-right. A direct child of a Stack. Takes only the pills'
/// own room for touches.
class IslandLayer extends StatelessWidget {
  final IslandController controller;
  const IslandLayer({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Positioned(
      top: pad.top + kIslandTop,
      right: pad.right + kIslandRight,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final entries = controller.entries;
          if (entries.isEmpty) return const SizedBox.shrink();
          final motion = _motionOf(context);
          return Column(
            key: const ValueKey('island'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final e in entries)
                _PillSlot(key: ValueKey('island-slot-${e.id}'), entry: e, controller: controller, motion: motion),
            ],
          );
        },
      ),
    );
  }
}

/// Motion without needing a WidgetRef (the fallback island may have no
/// ProviderScope above it): the setting when there is one, else full.
Motion _motionOf(BuildContext context) {
  final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  try {
    final s = ProviderScope.containerOf(context, listen: false).read(motionProvider);
    return Motion(full: s.enabled && !reduced, speed: s.speed);
  } catch (_) {
    return Motion(full: !reduced, speed: 1);
  }
}

/// The designed timings (scaled by Motion's speed).
const Duration _kPopIn = Duration(milliseconds: 380);
const Duration _kShrinkOut = Duration(milliseconds: 260);

/// 0.6 → 1.05 → 1.0: the pop.
final Animatable<double> _popScale = TweenSequence<double>([
  TweenSequenceItem(tween: Tween(begin: 0.6, end: 1.05).chain(CurveTween(curve: Curves.easeOut)), weight: 60),
  TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 40),
]);

/// One pill with its animations: pops in, shrinks and fades out, and its
/// height grows / collapses so the others slide to make room. Motion off:
/// a fade only, no transforms.
class _PillSlot extends StatefulWidget {
  final IslandEntry entry;
  final IslandController controller;
  final Motion motion;
  const _PillSlot({super.key, required this.entry, required this.controller, required this.motion});

  @override
  State<_PillSlot> createState() => _PillSlotState();
}

class _PillSlotState extends State<_PillSlot> with TickerProviderStateMixin {
  late final AnimationController _in;
  late final AnimationController _out;

  @override
  void initState() {
    super.initState();
    final m = widget.motion;
    _in = AnimationController(vsync: this, duration: m.full ? m.scale(_kPopIn) : m.fade)..forward();
    _out = AnimationController(vsync: this, duration: m.full ? m.scale(_kShrinkOut) : m.fade);
    _maybeExit();
  }

  @override
  void didUpdateWidget(_PillSlot old) {
    super.didUpdateWidget(old);
    _maybeExit();
  }

  void _maybeExit() {
    if (!widget.entry.exiting || _out.isAnimating || _out.isCompleted) return;
    final id = widget.entry.id;
    final c = widget.controller;
    _out.forward().whenCompleteOrCancel(() => c.remove(id));
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final full = widget.motion.full;
    final pill = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey('island-swipe-${e.id}'),
        direction: DismissDirection.startToEnd,
        resizeDuration: null,
        movementDuration: widget.motion.scale(const Duration(milliseconds: 180)),
        onDismissed: (_) => widget.controller.remove(e.id),
        child: IslandPill(entry: e, onTap: () => widget.controller.dismiss(e.id), controller: widget.controller),
      ),
    );
    return IgnorePointer(
      ignoring: e.exiting,
      child: AnimatedBuilder(
        animation: Listenable.merge([_in, _out]),
        child: pill,
        builder: (context, child) {
          final i = _in.value;
          final o = _out.value;
          final opacity =
              Curves.easeOut.transform(math.min(1, i / 0.6)) * (1 - Curves.easeIn.transform(math.min(1, o / 0.7)));
          Widget w = Opacity(opacity: opacity.clamp(0.0, 1.0), child: child);
          if (!full) return w;
          final scale = _popScale.transform(i) * (1 - 0.35 * Curves.easeIn.transform(o));
          final grow = Curves.easeOutCubic.transform(math.min(1, i / 0.5));
          final collapse = 1 - Curves.easeInOut.transform(((o - 0.25) / 0.75).clamp(0.0, 1.0));
          w = Transform.scale(scale: scale, alignment: Alignment.centerRight, child: w);
          return Align(alignment: Alignment.topRight, heightFactor: math.min(grow, collapse), child: w);
        },
      ),
    );
  }
}

/// The colours of a pill: (background, text and icon, outline).
(Color, Color, Color?) islandColors(IslandKind kind, QuiccPalette p) => switch (kind) {
  IslandKind.info => (p.bgElevated, p.textPrimary, p.borderSoft),
  IslandKind.success => (QuiccColors.statusPaid, QuiccColors.brand900, null),
  IslandKind.warn => (QuiccColors.statusFiring, QuiccColors.brand900, null),
  IslandKind.error => (QuiccColors.statusVoided, QuiccColors.brand900, null),
};

/// One pill: icon, one line (two with a [IslandEntry.body]), and its
/// buttons. Tap = put away.
class IslandPill extends StatelessWidget {
  final IslandEntry entry;
  final VoidCallback onTap;
  final IslandController? controller;
  const IslandPill({super.key, required this.entry, required this.onTap, this.controller});

  IslandKind get kind => entry.kind;

  /// The pill's fill (tests and the golden check it).
  Color colorIn(BuildContext context) => islandColors(kind, context.palette).$1;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, outline) = islandColors(kind, context.palette);
    final hasActions = entry.actions.isNotEmpty;
    final body = entry.body;
    final text = body == null
        ? Text(
            entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: QuiccType.text(QuiccType.body, weight: FontWeight.w600, color: fg, height: 1.2),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: QuiccType.text(QuiccType.body, weight: FontWeight.w700, color: fg, height: 1.2),
              ),
              Text(
                body,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: QuiccType.text(QuiccType.label, color: fg, height: 1.2),
              ),
            ],
          );
    return Semantics(
      container: true,
      liveRegion: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: hasActions ? kIslandMaxWidthWithActions : kIslandMaxWidth),
        child: Material(
          key: ValueKey('island-pill-${entry.id}'),
          color: bg,
          elevation: 6,
          shadowColor: Colors.black,
          shape: StadiumBorder(side: outline == null ? BorderSide.none : BorderSide(color: outline)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 9, hasActions ? 8 : 18, 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.iconOrDefault, size: 20, color: fg),
                  const SizedBox(width: 10),
                  Flexible(child: text),
                  if (hasActions) const SizedBox(width: 6),
                  for (final a in entry.actions)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: fg,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        shape: const StadiumBorder(),
                      ),
                      onPressed: () {
                        controller?.dismiss(entry.id);
                        a.onPressed();
                      },
                      child: Text(
                        a.label,
                        style: QuiccType.text(QuiccType.label, weight: FontWeight.w800, color: fg),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
