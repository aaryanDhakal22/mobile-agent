import 'package:flutter/material.dart';

import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';

/// A Settings card: eyebrow title + (i), an optional plain-words line under
/// it, then [children].
class SettingsCard extends StatelessWidget {
  final String title;
  final InfoText info;
  final String? subtitle;
  final List<Widget> children;
  const SettingsCard({super.key, required this.title, required this.info, this.subtitle, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(QuiccSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: LabelWithInfo(label: Eyebrow(title), info: info),
              ),
              if (subtitle != null) ...[
                QuiccSpace.gapXs,
                Text(subtitle!, style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary)),
              ],
              QuiccSpace.gapMd,
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// A heading over a group of settings cards (store settings), with a short
/// line saying what the group is for.
class SettingsGroup extends StatelessWidget {
  final String title;
  final String? caption;
  final List<Widget> children;
  const SettingsGroup({super.key, required this.title, this.caption, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700)),
          if (caption != null) ...[
            QuiccSpace.gapXs,
            Text(caption!, style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary)),
          ],
          QuiccSpace.gapMd,
          ...children,
        ],
      ),
    );
  }
}

/// A setting that isn't there yet: greyed out, with when it is coming.
class ComingSoonRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String explanation;
  final String when;
  const ComingSoonRow({
    super.key,
    required this.icon,
    required this.title,
    required this.explanation,
    this.when = 'Coming with the next Pi update',
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Opacity(
      opacity: 0.55,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: QuiccSpace.sm),
        child: Row(
          children: [
            Icon(icon, color: palette.textMuted),
            QuiccSpace.gapMd,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
                  Text(explanation, style: QuiccType.text(QuiccType.caption, color: palette.textMuted)),
                ],
              ),
            ),
            QuiccSpace.gapMd,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.sm, vertical: QuiccSpace.xs),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(QuiccRadius.sm),
                border: Border.all(color: palette.borderSoft),
              ),
              child: Text(when, style: QuiccType.text(QuiccType.caption, color: palette.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}
