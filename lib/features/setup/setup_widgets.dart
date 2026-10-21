import 'package:flutter/material.dart';

import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';

/// One wizard step's content: big title (+ its (i)), a sentence, the body,
/// and the main button at the bottom right.
class StepLayout extends StatelessWidget {
  final String title;
  final String? subtitle;
  final InfoText? info;
  final Widget body;
  final Widget? primary;
  final Widget? secondary;

  const StepLayout({
    super.key,
    required this.title,
    this.subtitle,
    this.info,
    required this.body,
    this.primary,
    this.secondary,
  });

  /// Below this height (the keyboard is up on a landscape tablet: ~340 of
  /// ~640 dp left) the step drops its subtitle and tightens the spacing so
  /// the fields being typed stay visible.
  static const double compactBelow = 450;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, box) => _build(context, compact: box.maxHeight < compactBelow));

  Widget _build(BuildContext context, {required bool compact}) {
    return Padding(
      padding: compact ? const EdgeInsets.fromLTRB(40, 8, 40, 8) : const EdgeInsets.fromLTRB(40, 24, 40, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(title, style: TextStyle(fontSize: compact ? 24 : 32, fontWeight: FontWeight.w700)),
              ),
              if (info != null) ...[const SizedBox(width: 4), InfoButton(info!, size: 24)],
            ],
          ),
          if (subtitle != null && !compact) ...[
            const SizedBox(height: 8),
            Text(subtitle!, style: TextStyle(fontSize: 18, color: context.palette.textSecondary, height: 1.35)),
          ],
          SizedBox(height: compact ? 8 : 20),
          Expanded(child: body),
          if (primary != null || secondary != null) ...[
            SizedBox(height: compact ? 8 : 16),
            Row(children: [?secondary, const Spacer(), ?primary]),
          ],
        ],
      ),
    );
  }
}

/// The big filled button wizard steps use.
class BigButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;
  const BigButton(this.label, {super.key, this.icon, this.onPressed, this.busy = false});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 64,
    child: FilledButton.icon(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 0.5),
      ),
      icon: busy
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3))
          : Icon(icon ?? Icons.arrow_forward, size: 26),
      label: Text(label),
    ),
  );
}

/// A row in a checklist: icon, label (+ (i)), and on the right a ✓ or an
/// action button.
class CheckRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? detail;
  final InfoText? info;

  /// null = still checking.
  final bool? ok;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Shown instead of a red ✗ when not ok (e.g. "Not answering").
  final String? failText;

  /// Couldn't be checked (e.g. an older Pi): a grey dash, neither ✓ nor ✗.
  final bool unknown;

  const CheckRow({
    super.key,
    required this.icon,
    required this.label,
    this.detail,
    this.info,
    this.ok,
    this.actionLabel,
    this.onAction,
    this.failText,
    this.unknown = false,
  });

  @override
  Widget build(BuildContext context) {
    final Widget trailing;
    if (unknown) {
      trailing = Icon(Icons.remove_circle_outline, color: context.palette.textMuted, size: 34);
    } else if (ok == null) {
      trailing = const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3));
    } else if (ok!) {
      trailing = const Icon(Icons.check_circle, color: QuiccColors.statusPaid, size: 34);
    } else if (actionLabel != null) {
      trailing = SizedBox(
        height: 52,
        child: FilledButton.tonal(
          onPressed: onAction,
          style: FilledButton.styleFrom(textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          child: Text(actionLabel!),
        ),
      );
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failText != null)
            Text(
              failText!,
              style: const TextStyle(color: QuiccColors.statusVoided, fontWeight: FontWeight.w600),
            ),
          const SizedBox(width: 8),
          const Icon(Icons.cancel, color: QuiccColors.statusVoided, size: 34),
        ],
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 30, color: context.palette.textSecondary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(label, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
                      ),
                      if (info != null) InfoButton(info!, size: 18),
                    ],
                  ),
                  if (detail != null)
                    Text(detail!, style: TextStyle(fontSize: 15, color: context.palette.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      ),
    );
  }
}
