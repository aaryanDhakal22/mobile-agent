import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/motion.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_type.dart';
import 'rail_modes.dart';

/// The `q` at the top of the rail (1.6.0). Tap: kitchen ↔ store (from
/// developer mode: back to kitchen). Long press, in any mode: developer mode,
/// behind the developer PIN. It turns over once per mode change, and wears
/// the mode's colours: lavender (kitchen), pale (store), dark (developer).
class QButton extends StatefulWidget {
  final RailMode mode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Motion motion;

  /// A small dot on the corner: a Quibase update is waiting (Store → Updates).
  final bool dot;

  const QButton({
    super.key,
    required this.mode,
    required this.onTap,
    required this.onLongPress,
    this.motion = const Motion(full: true, speed: 1),
    this.dot = false,
  });

  @override
  State<QButton> createState() => _QButtonState();
}

class _QButtonState extends State<QButton> with SingleTickerProviderStateMixin {
  late final AnimationController _press;
  double _turns = 0;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
      reverseDuration: const Duration(milliseconds: 200),
    );
  }

  @override
  void didUpdateWidget(QButton old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) _turns += widget.mode.index > old.mode.index ? 1 : -1;
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (widget.mode) {
      RailMode.kitchen => (QuiccColors.brand400, QuiccColors.brand900, null),
      RailMode.store => (QuiccColors.brand100, QuiccColors.brand800, QuiccColors.brand400),
      RailMode.dev => (QuiccColors.brand900, QuiccColors.brand400, QuiccColors.brand400),
    };
    final spin = widget.motion.full ? widget.motion.scale(const Duration(milliseconds: 520)) : Duration.zero;
    final q = Semantics(
      button: true,
      label: switch (widget.mode) {
        RailMode.kitchen => 'Kitchen mode. Tap for store mode, hold for developer mode',
        RailMode.store => 'Store mode. Tap for kitchen mode, hold for developer mode',
        RailMode.dev => 'Developer mode. Tap to leave',
      },
      child: GestureDetector(
        key: const ValueKey('q-button'),
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press.forward(),
        onTapUp: (_) {
          _press.reverse();
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        onTapCancel: () => _press.reverse(),
        onLongPressStart: (_) => _press.forward(),
        onLongPress: () {
          _press.reverse();
          HapticFeedback.heavyImpact();
          widget.onLongPress();
        },
        onLongPressCancel: () => _press.reverse(),
        child: AnimatedBuilder(
          animation: _press,
          builder: (_, child) => Transform.scale(scale: 1.0 - (_press.value * 0.08), child: child),
          child: AnimatedRotation(
            turns: _turns,
            duration: spin,
            curve: Curves.easeOutBack,
            child: AnimatedContainer(
              duration: widget.motion.full
                  ? widget.motion.scale(const Duration(milliseconds: 260))
                  : widget.motion.fade,
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(QuiccRadius.md),
                border: border == null ? null : Border.all(color: border, width: 2),
              ),
              alignment: Alignment.center,
              child: Text(
                'q',
                style: QuiccType.text(QuiccType.title, weight: FontWeight.w700, color: fg, height: 1),
              ),
            ),
          ),
        ),
      ),
    );
    if (!widget.dot) return q;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        q,
        Positioned(
          key: const ValueKey('q-update-dot'),
          top: -3,
          right: -3,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: QuiccColors.statusFiring,
              shape: BoxShape.circle,
              border: Border.all(color: context.palette.bgSurface, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}
