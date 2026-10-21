import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';

/// Snackbars from the button stay left of it.
const double _toastInset = 160;

/// Hold the big button this long to undo the last return.
const Duration kUndoHold = Duration(milliseconds: 2000);

/// The floating driver button (bottom-right on every pane but Settings) —
/// the old app's queue button, backed by the agent's driver queue:
///
///   collapsed  truck + badge = drivers out on a run
///   tap        opens a pill per driver who is OUT; the big button shows who
///              is NEXT in the queue
///   tap a pill "I have returned": their run is delivered and they go to the
///              back of the queue
///   hold big   2 s → undo the last return (they're out again; the agent
///              allows it for 10 minutes)
///   tap outside closes
///
/// Must fill its parent (Positioned.fill): the invisible backdrop catches
/// outside taps.
class DriverFab extends ConsumerStatefulWidget {
  const DriverFab({super.key});

  @override
  ConsumerState<DriverFab> createState() => _DriverFabState();
}

class _DriverFabState extends ConsumerState<DriverFab> with TickerProviderStateMixin {
  bool _expanded = false;
  String? _busyId;
  late final AnimationController _holdCtrl;
  Timer? _holdTimer;
  bool _holdFired = false;

  @override
  void initState() {
    super.initState();
    _holdCtrl = AnimationController(vsync: this, duration: kUndoHold);
  }

  @override
  void dispose() {
    _holdCtrl.dispose();
    _holdTimer?.cancel();
    super.dispose();
  }

  void _expand() => setState(() => _expanded = true);
  void _collapse() => setState(() => _expanded = false);

  Future<void> _returned(Driver d) async {
    if (_busyId != null) return;
    setState(() => _busyId = d.id);
    try {
      await ref.read(floorProvider.notifier).driverReturned(d.id);
      HapticFeedback.selectionClick();
      if (mounted) {
        toast(context, '${d.name} is back — end of the queue (hold the big button to undo)', rightInset: _toastInset);
        _collapse();
      }
    } catch (e) {
      HapticFeedback.lightImpact();
      if (mounted) {
        toast(
          context,
          e is AgentException && e.isConflict ? '${d.name} is not out on a run' : 'Not saved: $e',
          error: true,
          rightInset: _toastInset,
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  void _onNextTap() {
    // Swallow the release-tap of a press that already triggered undo.
    final consumedByUndo = _holdFired;
    _holdFired = false;
    if (consumedByUndo) return;
    _collapse();
  }

  void _onHoldStart() {
    _holdFired = false;
    _holdCtrl.forward(from: 0);
    _holdTimer = Timer(kUndoHold, () async {
      _holdFired = true;
      final last = ref.read(lastReturnProvider);
      if (last == null || !last.undoable) return;
      final name = ref.read(floorProvider).drivers.where((d) => d.id == last.driverId).firstOrNull?.name ?? 'Driver';
      try {
        await ref.read(floorProvider.notifier).undoReturn(last.driverId);
        HapticFeedback.mediumImpact();
        if (mounted) toast(context, 'Undone — $name is out again', rightInset: _toastInset);
      } catch (e) {
        if (mounted) {
          toast(
            context,
            'Could not undo: ${e is AgentException ? e.message : e}',
            error: true,
            rightInset: _toastInset,
          );
        }
      }
    });
  }

  void _onHoldEnd() {
    _holdTimer?.cancel();
    _holdCtrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final out = ref.watch(floorProvider.select((s) => s.driversOut));
    final next = ref.watch(floorProvider.select((s) => s.nextDriver));
    final last = ref.watch(lastReturnProvider);
    final canUndo = last != null && last.undoable;

    return Stack(
      children: [
        // Invisible backdrop: catches taps outside the button to collapse.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_expanded,
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _collapse),
          ),
        ),
        Positioned(
          right: 24,
          bottom: 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
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
                      position: Tween<Offset>(begin: const Offset(0, 0.2), end: Offset.zero).animate(anim),
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
                            if (out.isEmpty)
                              const _Hint('No drivers out right now')
                            else
                              for (final d in out) ...[
                                _DriverPill(
                                  driver: d,
                                  orders: ref.watch(floorProvider.select((s) => s.outWith(d.id).length)),
                                  busy: _busyId == d.id,
                                  onTap: () => _returned(d),
                                ),
                                const SizedBox(height: 10),
                              ],
                          ],
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('pills-closed')),
              ),
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
                        outCount: out.length,
                        nextName: next?.name,
                        canUndo: canUndo,
                        holdAnimation: _holdCtrl,
                        onTap: _onNextTap,
                        onHoldStart: _onHoldStart,
                        onHoldEnd: _onHoldEnd,
                      )
                    : _RoundButton(
                        key: const ValueKey('fab-collapsed'),
                        size: 64,
                        badgeOffset: 2,
                        badgeSize: 22,
                        badgeFont: 11,
                        count: out.length,
                        onTap: _expand,
                        semantics: 'Drivers out: ${out.length}',
                        child: const Icon(Icons.local_shipping_outlined, color: QuiccColors.brand900, size: 30),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Lavender circle button + optional count badge in the top-right.
class _RoundButton extends StatelessWidget {
  final double size;
  final double badgeOffset;
  final double badgeSize;
  final double badgeFont;
  final int count;
  final Widget child;
  final List<Widget> overlays;
  final VoidCallback onTap;
  final GestureTapDownCallback? onTapDown;
  final GestureTapUpCallback? onTapUp;
  final VoidCallback? onTapCancel;
  final String semantics;

  const _RoundButton({
    super.key,
    required this.size,
    required this.badgeOffset,
    required this.badgeSize,
    required this.badgeFont,
    required this.count,
    required this.child,
    required this.onTap,
    required this.semantics,
    this.overlays = const [],
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantics,
      child: SizedBox(
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
                onTapDown: onTapDown,
                onTapUp: onTapUp,
                onTapCancel: onTapCancel,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Center(child: child),
                ),
              ),
            ),
            ...overlays,
            if (count > 0)
              Positioned(
                top: -badgeOffset,
                right: -badgeOffset,
                child: Container(
                  constraints: BoxConstraints(minWidth: badgeSize, minHeight: badgeSize),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: context.palette.bgCanvas,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: QuiccColors.brand400, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$count',
                    style: TextStyle(fontSize: badgeFont, fontWeight: FontWeight.w700, color: QuiccColors.brand400),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The open state's big button: who's NEXT; hold 2 s to undo the last return.
class _NextButton extends StatelessWidget {
  final int outCount;
  final String? nextName;
  final bool canUndo;
  final Animation<double> holdAnimation;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  const _NextButton({
    super.key,
    required this.outCount,
    required this.nextName,
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
    return _RoundButton(
      size: size,
      badgeOffset: 4,
      badgeSize: 26,
      badgeFont: 12,
      count: outCount,
      onTap: onTap,
      semantics: 'Next driver: ${nextName ?? 'none'}${canUndo ? '. Hold to undo the last return' : ''}',
      // Hold-to-undo only armed when there is something to undo.
      onTapDown: canUndo ? (_) => onHoldStart() : null,
      onTapUp: canUndo ? (_) => onHoldEnd() : null,
      onTapCancel: canUndo ? onHoldEnd : null,
      overlays: [
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
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'NEXT',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
                color: QuiccColors.brand900,
              ),
            ),
            Text(
              nextName ?? '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: QuiccColors.brand900),
            ),
          ],
        ),
      ),
    );
  }
}

/// One driver who is out: tap = "I have returned".
class _DriverPill extends StatelessWidget {
  final Driver driver;
  final int orders;
  final bool busy;
  final VoidCallback onTap;
  const _DriverPill({required this.driver, required this.orders, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.bgElevated,
      elevation: 4,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: const BoxDecoration(color: QuiccColors.brand400, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(
                  driver.name.isEmpty ? '?' : driver.name.characters.first.toUpperCase(),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: QuiccColors.brand900),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                driver.name,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: p.textPrimary),
              ),
              const SizedBox(width: 10),
              Text(
                busy ? 'saving…' : '$orders order${orders == 1 ? '' : 's'} · tap when back',
                style: TextStyle(fontSize: 12, color: p.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: p.bgElevated,
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        border: Border.all(color: p.borderSoft),
      ),
      child: Text(
        text,
        textAlign: TextAlign.right,
        style: TextStyle(color: p.textSecondary, height: 1.3),
      ),
    );
  }
}
