import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/island.dart';
import '../common/squish.dart';
import 'ready_undo.dart';

/// How long READY is held for "no callout" (2.0.0, owner: about 1 s).
const Duration kReadyHold = Duration(seconds: 1);

/// The darker fill that sweeps across READY while it is held.
const Color kReadyHoldFill = Color(0xFF2E7D4F);

/// READY on a kitchen ticket and on order details (2.0.0):
///
///  * a tap = READY, and the store hub calls the order out (fires when the
///    finger lifts);
///  * held [kReadyHold] = READY with no callout (for an order that sat
///    forgotten — calling it out would only confuse the customers): a darker
///    fill sweeps left → right while it is held, then the label reads
///    "NO CALLOUT" with a short buzz, and it fires without waiting for the
///    finger.
///
/// [onReady] gets `callout`. The button squishes like the other big ones.
class ReadyButton extends StatefulWidget {
  final void Function(bool callout) onReady;
  final double height;
  final bool enabled;
  final TextStyle? textStyle;
  const ReadyButton({super.key, required this.onReady, this.height = 60, this.enabled = true, this.textStyle});

  @override
  State<ReadyButton> createState() => _ReadyButtonState();
}

class _ReadyButtonState extends State<ReadyButton> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(vsync: this, duration: kReadyHold)
    ..addStatusListener(_held);

  /// The hold fired: the finger lifting afterwards does nothing.
  bool _fired = false;

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _held(AnimationStatus s) {
    if (s != AnimationStatus.completed || _fired) return;
    _fired = true;
    HapticFeedback.mediumImpact();
    widget.onReady(false);
  }

  void _down(TapDownDetails _) {
    if (!widget.enabled) return;
    _fired = false;
    _hold.forward(from: 0);
  }

  void _up(TapUpDetails _) {
    if (!widget.enabled) return;
    if (!_fired) {
      _fired = true;
      _hold.stop();
      _hold.value = 0;
      widget.onReady(true);
    }
  }

  void _cancel() {
    if (_fired) return;
    _hold.stop();
    _hold.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final style =
        widget.textStyle ??
        QuiccType.text(QuiccType.heading, weight: FontWeight.w700, height: 1, color: QuiccColors.brand900);
    return Squish(
      enabled: widget.enabled,
      child: Semantics(
        button: true,
        label: 'READY. Hold for no callout.',
        child: GestureDetector(
          key: const ValueKey('ready-button'),
          behavior: HitTestBehavior.opaque,
          onTapDown: _down,
          onTapUp: _up,
          onTapCancel: _cancel,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.5,
            child: SizedBox(
              height: widget.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(QuiccRadius.md),
                child: AnimatedBuilder(
                  animation: _hold,
                  builder: (context, _) {
                    final full = _hold.value >= 1;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: QuiccColors.statusPaid),
                        FractionallySizedBox(
                          key: const ValueKey('ready-hold-fill'),
                          alignment: Alignment.centerLeft,
                          widthFactor: _hold.value,
                          child: const ColoredBox(color: kReadyHoldFill),
                        ),
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.md),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    full ? Icons.volume_off : Icons.check_circle_outline,
                                    size: 24,
                                    color: full ? Colors.white : QuiccColors.brand900,
                                  ),
                                  QuiccSpace.gapSm,
                                  Text(
                                    full ? 'NO CALLOUT' : 'READY',
                                    style: full ? style.copyWith(color: Colors.white) : style,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// READY, now (2.0.0): the ticket leaves Kitchen at once with the "#232
/// ready · UNDO" pill while the Pi is told in the background
/// ([FloorController.ready]); if it doesn't land the ticket comes back and
/// the pill says so. [island] and the floor are read by the caller before
/// the ticket leaves the screen.
void readyNow(IslandController? island, FloorController floor, StoredOrder so, {required bool callout}) {
  showReadyUndo(island, floor, so);
  floor.ready(so.id, callout: callout).catchError((Object e) {
    final n = so.displayNumber.startsWith('#') ? so.displayNumber : '#${so.displayNumber}';
    island?.show(readyFailedText(e, n), kind: IslandKind.error);
  });
}

/// A READY that didn't land, in plain words (the ticket is back).
String readyFailedText(Object e, String n) {
  if (e is AgentException) {
    if (e.isConflict) return '$n already moved on — the screen will refresh';
    if (e.isNetwork) return "Can't reach the Pi — $n is back on Kitchen";
  }
  return 'Not marked ready — $n is back on Kitchen';
}
