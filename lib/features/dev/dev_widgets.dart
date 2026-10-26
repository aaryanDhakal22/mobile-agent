import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import '../home/home_nav.dart';
import 'dev_gate.dart';
import 'dev_texts.dart';

/// A developer-mode pane: the header (with LOCK), a note that it relocks, then
/// [children] in a list with the pane padding.
class DevPane extends ConsumerWidget {
  final String title;
  final String subtitle;
  final List<Widget> children;
  const DevPane({super.key, required this.title, required this.subtitle, required this.children});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: QuiccSpace.paneInsets,
      children: [
        PaneHeader(
          title: title,
          subtitle: subtitle,
          trailing: OutlinedButton.icon(
            key: const ValueKey('dev-lock'),
            onPressed: () {
              ref.read(homeNavProvider.notifier).go(HomeDestination.kitchen);
              ref.read(devGateProvider.notifier).lock();
            },
            icon: const Icon(Icons.lock_outline),
            label: const Text('Lock'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
          child: Row(
            children: [
              Icon(Icons.developer_mode, size: 18, color: context.palette.textMuted),
              QuiccSpace.gapSm,
              Text(DevText.lockedNote, style: QuiccType.text(QuiccType.caption, color: context.palette.textMuted)),
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}

/// Label on the left, value on the right; [warn] / [bad] colour the value.
class KeyValueRow extends StatelessWidget {
  final String label;
  final String value;
  final bool warn;
  final bool bad;
  final bool mono;
  const KeyValueRow(this.label, this.value, {super.key, this.warn = false, this.bad = false, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final color = bad
        ? QuiccColors.statusVoided
        : warn
        ? QuiccColors.statusFiring
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: QuiccSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 200,
            child: Text(label, style: QuiccType.text(QuiccType.body, color: context.palette.textMuted)),
          ),
          Expanded(
            child: Text(
              value,
              style: mono
                  ? QuiccType.number(QuiccType.body, color: color)
                  : QuiccType.text(QuiccType.body, weight: FontWeight.w600, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small coloured dot.
class StatusDot extends StatelessWidget {
  final Color color;
  const StatusDot(this.color, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
