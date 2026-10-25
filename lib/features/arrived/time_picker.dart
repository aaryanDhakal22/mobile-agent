import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../theme/quicc_colors.dart';

/// The DoorDash-style time picker (1.5.0): three buttons — X, X+5 and X+10 —
/// with −5 / +5 steppers beside X+10 (never below X+10). X is the store's
/// default time for the order type and starts selected, so one CONFIRM tap
/// is enough.
class TimePickerMath {
  const TimePickerMath._();

  static const int step = 5;

  /// X, X+5, X+10.
  static List<int> presets(int base) => [base, base + step, base + 2 * step];

  /// The third button's lowest value.
  static int floor(int base) => base + 2 * step;

  /// −5 on the third button, floored at X+10.
  static int stepDown(int third, int base) => math.max(third - step, floor(base));

  /// +5 on the third button, capped at the Pi's limit (240).
  static int stepUp(int third) => math.min(third + step, DefaultTimes.maxMinutes);
}

/// X for [o]: the default pickup time for pickup / dine-in, the default
/// delivery time for a delivery.
int defaultMinutesFor(StoredOrder o, DefaultTimes times) => times.forType(o.order.fulfillment.type);

class TimePicker extends StatefulWidget {
  /// X.
  final int base;

  /// The selected minutes.
  final int value;
  final ValueChanged<int> onChanged;

  /// Colours for the lavender alert surface.
  final bool onBrand;
  final double fontSize;
  final bool enabled;

  const TimePicker({
    super.key,
    required this.base,
    required this.value,
    required this.onChanged,
    this.onBrand = false,
    this.fontSize = 22,
    this.enabled = true,
  });

  @override
  State<TimePicker> createState() => _TimePickerState();
}

class _TimePickerState extends State<TimePicker> {
  /// The third button's value (X+10 until stepped).
  late int _third = math.max(TimePickerMath.floor(widget.base), widget.value);

  @override
  void didUpdateWidget(TimePicker old) {
    super.didUpdateWidget(old);
    if (old.base != widget.base) _third = math.max(TimePickerMath.floor(widget.base), widget.value);
    if (widget.value > _third) _third = widget.value;
  }

  void _pickThird(int v) {
    setState(() => _third = v);
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final x = widget.base;
    final on = widget.enabled;
    final atFloor = _third <= TimePickerMath.floor(x);
    final atMax = _third >= DefaultTimes.maxMinutes;
    return Row(
      children: [
        Expanded(
          child: _TimeButton(
            key: const ValueKey('pick-x'),
            minutes: x,
            selected: widget.value == x,
            onBrand: widget.onBrand,
            fontSize: widget.fontSize,
            onTap: on ? () => widget.onChanged(x) : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _TimeButton(
            key: const ValueKey('pick-x5'),
            minutes: x + TimePickerMath.step,
            selected: widget.value == x + TimePickerMath.step,
            onBrand: widget.onBrand,
            fontSize: widget.fontSize,
            onTap: on ? () => widget.onChanged(x + TimePickerMath.step) : null,
          ),
        ),
        const SizedBox(width: 8),
        _StepButton(
          key: const ValueKey('pick-minus'),
          icon: Icons.remove,
          tooltip: '5 minutes less',
          onBrand: widget.onBrand,
          onTap: on && !atFloor ? () => _pickThird(TimePickerMath.stepDown(_third, x)) : null,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _TimeButton(
            key: const ValueKey('pick-x10'),
            minutes: _third,
            selected: widget.value == _third && widget.value >= TimePickerMath.floor(x),
            onBrand: widget.onBrand,
            fontSize: widget.fontSize,
            onTap: on ? () => widget.onChanged(_third) : null,
          ),
        ),
        const SizedBox(width: 4),
        _StepButton(
          key: const ValueKey('pick-plus'),
          icon: Icons.add,
          tooltip: '5 minutes more',
          onBrand: widget.onBrand,
          onTap: on && !atMax ? () => _pickThird(TimePickerMath.stepUp(_third)) : null,
        ),
      ],
    );
  }
}

class _TimeButton extends StatelessWidget {
  final int minutes;
  final bool selected;
  final bool onBrand;
  final double fontSize;
  final VoidCallback? onTap;

  const _TimeButton({
    super.key,
    required this.minutes,
    required this.selected,
    required this.onBrand,
    required this.fontSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final Color border;
    if (onBrand) {
      bg = selected ? QuiccColors.brand900 : Colors.transparent;
      fg = selected ? QuiccColors.brand50 : QuiccColors.brand900;
      border = QuiccColors.brand900;
    } else {
      bg = selected ? QuiccColors.brand400 : context.palette.bgElevated;
      fg = selected ? QuiccColors.brand900 : context.palette.textPrimary;
      border = selected ? QuiccColors.brand400 : context.palette.borderSoft;
    }
    return Semantics(
      selected: selected,
      button: true,
      label: '$minutes minutes',
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          side: BorderSide(color: border, width: 2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          onTap: onTap,
          child: SizedBox(
            height: 64,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$minutes',
                          style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800, color: fg),
                        ),
                        TextSpan(
                          text: ' min',
                          style: TextStyle(fontSize: fontSize * 0.6, fontWeight: FontWeight.w600, color: fg),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool onBrand;
  final VoidCallback? onTap;
  const _StepButton({super.key, required this.icon, required this.tooltip, required this.onBrand, this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = onBrand ? QuiccColors.brand900 : context.palette.textPrimary;
    final off = onTap == null;
    // No Tooltip: the picker also sits on the full-screen alert, above the
    // navigator (no Overlay there).
    return SizedBox(
      width: 52,
      height: 64,
      child: Semantics(
        label: tooltip,
        button: true,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(52, 64),
            foregroundColor: fg,
            side: BorderSide(color: fg.withValues(alpha: off ? 0.3 : 0.8), width: 2),
          ),
          onPressed: onTap,
          child: Icon(icon, size: 26),
        ),
      ),
    );
  }
}

/// Picks a new lead time for a scheduled future order (the Later strip and
/// the order detail): the same picker in a dialog. Resolves the minutes, or
/// null when cancelled.
Future<int?> showLeadTimeDialog(BuildContext context, {required int base, int? current, String? subtitle}) =>
    showDialog<int>(
      context: context,
      builder: (_) => _LeadDialog(base: base, current: current ?? base, subtitle: subtitle),
    );

class _LeadDialog extends StatefulWidget {
  final int base;
  final int current;
  final String? subtitle;
  const _LeadDialog({required this.base, required this.current, this.subtitle});

  @override
  State<_LeadDialog> createState() => _LeadDialogState();
}

class _LeadDialogState extends State<_LeadDialog> {
  late int _v = widget.current < widget.base ? widget.base : widget.current;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Start cooking how long before it is due?'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.subtitle != null) ...[
            Text(widget.subtitle!, style: TextStyle(color: context.palette.textSecondary, fontSize: 16)),
            const SizedBox(height: 14),
          ],
          TimePicker(base: widget.base, value: _v, onChanged: (v) => setState(() => _v = v)),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CANCEL')),
      FilledButton(
        key: const ValueKey('lead-confirm'),
        onPressed: () => Navigator.of(context).pop(_v),
        child: Text('CONFIRM · $_v MIN'),
      ),
    ],
  );
}
