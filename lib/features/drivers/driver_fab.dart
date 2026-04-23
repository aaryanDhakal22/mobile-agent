import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/quicc_colors.dart';
import 'driver_state.dart';

const Duration _undoHold = Duration(milliseconds: 2000);

/// The expandable driver FAB. Sits bottom-right of whichever tab hosts it.
///
/// Collapsed: small circular button with a truck icon + queue-length badge.
/// Tap â†’ expands into a column of driver buttons (in toggle-on insertion
/// order) above the FAB; the FAB itself relabels to **NEXT**.
/// Tap NEXT â†’ dequeue + blink the name.
/// Hold NEXT 2 s â†’ undo the last dequeue (depth 1). A circular ring animates
/// around the button while the cashier holds, with a haptic tick on fire.
/// Tap outside the expanded column â†’ collapse.
class DriverFab extends ConsumerStatefulWidget {
  const DriverFab({super.key});

  @override
  ConsumerState<DriverFab> createState() => _DriverFabState();
}

class _DriverFabState extends ConsumerState<DriverFab>
    with TickerProviderStateMixin {
  bool _expanded = false;
  // Eager init: `late final Foo = Foo()` gets initialized on first access,
  // which crashes if the widget is disposed without ever accessing it (e.g.
  // cashier tabs away before tapping the FAB). Constructing the controller
  // in initState runs on mount and guarantees it exists at dispose time.
  late final AnimationController _holdCtrl;
  Timer? _holdTimer;
  bool _holdFired = false;

  @override
  void initState() {
    super.initState();
    _holdCtrl = AnimationController(vsync: this, duration: _undoHold);
  }

  @override
  void dispose() {
    _holdCtrl.dispose();
    _holdTimer?.cancel();
    super.dispose();
  }

  void _expand() => setState(() => _expanded = true);
  void _collapse() => setState(() => _expanded = false);

  void _onNextTap() {
    // If the hold timer already fired (undo happened on this gesture), swallow
    // the release-tap so the cashier doesn't get an undo *and* a dequeue from
    // the same press. Clear unconditionally so a stale `true` from a previous
    // cycle never carries over into the next tap.
    final consumedByUndo = _holdFired;
    _holdFired = false;
    if (consumedByUndo) return;
    final name = ref.read(driverProvider.notifier).dequeue();
    if (name == null) {
      HapticFeedback.lightImpact();
    }
  }

  void _onHoldStart() {
    _holdFired = false;
    _holdCtrl.forward(from: 0);
    _holdTimer = Timer(_undoHold, () {
      _holdFired = true;
      final undone = ref.read(driverProvider.notifier).undo();
      if (undone) HapticFeedback.mediumImpact();
    });
  }

  void _onHoldEnd() {
    _holdTimer?.cancel();
    _holdCtrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(driverProvider);

    return Stack(
      children: [
        // Backdrop â€” invisible, but absorbs taps outside the FAB area so
        // tapping anywhere else collapses.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_expanded,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _collapse,
            ),
          ),
        ),
        Positioned(
          right: 24,
          bottom: 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Pills column â€” slides up + fades in on expand, reverses on
              // collapse. AnimatedSwitcher keyed by expanded-state so Flutter
              // runs the exit transition on the old subtree.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                reverseDuration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SizeTransition(
                    sizeFactor: anim,
                    axisAlignment: 1,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.2),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                ),
                child: _expanded
                    ? Padding(
                        key: const ValueKey('pills-open'),
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (state.onShift.isEmpty)
                              const _EmptyRosterHint()
                            else
                              for (final name in state.onShift.keys) ...[
                                _DriverPillButton(
                                  name: name,
                                  alreadyQueued:
                                      state.queue.contains(name),
                                  onTap: () {
                                    final added = ref
                                        .read(driverProvider.notifier)
                                        .enqueue(name);
                                    if (added) {
                                      HapticFeedback.selectionClick();
                                      _collapse();
                                    } else {
                                      // Duplicate â€” silent, keep FAB open
                                      // so they can pick a different driver.
                                      HapticFeedback.lightImpact();
                                    }
                                  },
                                ),
                                const SizedBox(height: 10),
                              ],
                          ],
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('pills-closed')),
              ),
              // Main FAB â€” swaps between collapsed icon and the NEXT button
              // with an elastic scale-up on entry.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                reverseDuration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => ScaleTransition(
                  scale: Tween<double>(begin: 0.7, end: 1).animate(anim),
                  alignment: Alignment.bottomRight,
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: _expanded
                    ? _NextButton(
                        key: const ValueKey('fab-next'),
                        queueLength: state.queue.length,
                        canUndo: state.lastDequeued != null,
                        holdAnimation: _holdCtrl,
                        onTap: _onNextTap,
                        onHoldStart: _onHoldStart,
                        onHoldEnd: _onHoldEnd,
                      )
                    : _CollapsedFab(
                        key: const ValueKey('fab-collapsed'),
                        queueLength: state.queue.length,
                        onTap: _expand,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CollapsedFab extends StatelessWidget {
  final int queueLength;
  final VoidCallback onTap;
  const _CollapsedFab({
    super.key,
    required this.queueLength,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            color: QuiccColors.brand400,
            elevation: 6,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: const SizedBox(
                width: 64,
                height: 64,
                child: Icon(
                  Icons.local_shipping_outlined,
                  color: QuiccColors.brand900,
                  size: 30,
                ),
              ),
            ),
          ),
          if (queueLength > 0)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: context.palette.bgCanvas,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: QuiccColors.brand400, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$queueLength',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: QuiccColors.brand400,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NextButton extends StatelessWidget {
  final int queueLength;
  final bool canUndo;
  final Animation<double> holdAnimation;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  const _NextButton({
    super.key,
    required this.queueLength,
    required this.canUndo,
    required this.holdAnimation,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  @override
  Widget build(BuildContext context) {
    const size = 104.0;
    const ringStroke = 9.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Material(
            color: QuiccColors.brand400,
            elevation: 6,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              onTapDown: canUndo ? (_) => onHoldStart() : null,
              onTapCancel: canUndo ? onHoldEnd : null,
              onTapUp: canUndo ? (_) => onHoldEnd() : null,
              child: SizedBox(
                width: size,
                height: size,
                child: const Center(
                  child: Text(
                    'NEXT',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 3,
                      color: QuiccColors.brand900,
                    ),
                  ),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: AnimatedBuilder(
              animation: holdAnimation,
              builder: (_, _) => SizedBox(
                width: size + ringStroke * 2,
                height: size + ringStroke * 2,
                child: CircularProgressIndicator(
                  value: holdAnimation.value,
                  strokeWidth: ringStroke,
                  strokeCap: StrokeCap.round,
                  backgroundColor: Colors.transparent,
                  valueColor: const AlwaysStoppedAnimation(QuiccColors.brand900),
                ),
              ),
            ),
          ),
          if (queueLength > 0)
            Positioned(
              top: -4,
              right: -4,
              child: Container(
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                padding: const EdgeInsets.symmetric(horizontal: 7),
                decoration: BoxDecoration(
                  color: context.palette.bgCanvas,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: QuiccColors.brand400, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$queueLength',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: QuiccColors.brand400,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DriverPillButton extends StatelessWidget {
  final String name;
  final bool alreadyQueued;
  final VoidCallback onTap;
  const _DriverPillButton({
    required this.name,
    required this.alreadyQueued,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: alreadyQueued ? 0.45 : 1,
      child: Material(
        color: context.palette.bgElevated,
        elevation: 4,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: const BoxDecoration(
                    color: QuiccColors.brand400,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    name[0],
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: QuiccColors.brand900,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: context.palette.textPrimary,
                  ),
                ),
                if (alreadyQueued) ...[
                  const SizedBox(width: 10),
                  Text(
                    'queued',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: context.palette.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyRosterHint extends StatelessWidget {
  const _EmptyRosterHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: context.palette.bgElevated,
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        border: Border.all(color: context.palette.borderSoft),
      ),
      child: Text(
        'No drivers on shift â€”\ntoggle some in',
        textAlign: TextAlign.right,
        style: TextStyle(color: context.palette.textSecondary, height: 1.3),
      ),
    );
  }
}
