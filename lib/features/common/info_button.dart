import 'package:flutter/material.dart';

import '../../theme/quicc_colors.dart';

/// A short explanation behind a small (i): what something means and when to
/// touch it. The copy lives in info_texts.dart.
class InfoText {
  final String title;
  final String body;
  const InfoText(this.title, this.body);
}

/// The small (i) icon. Tapping it opens [info] in a dialog.
class InfoButton extends StatelessWidget {
  final InfoText info;
  final double size;
  const InfoButton(this.info, {super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'What is this?',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size + 20, height: size + 20),
      icon: Icon(Icons.info_outline, size: size, color: context.palette.textMuted),
      onPressed: () => showInfo(context, info),
    );
  }
}

Future<void> showInfo(BuildContext context, InfoText info) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Row(
      children: [
        const Icon(Icons.info_outline),
        const SizedBox(width: 10),
        Expanded(child: Text(info.title)),
      ],
    ),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Text(info.body, style: const TextStyle(fontSize: 17, height: 1.4)),
    ),
    actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('GOT IT'))],
  ),
);

/// A label followed by its (i), for card headers and setting rows.
class LabelWithInfo extends StatelessWidget {
  final Widget label;
  final InfoText info;
  const LabelWithInfo({super.key, required this.label, required this.info});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: label),
      const SizedBox(width: 2),
      InfoButton(info, size: 18),
    ],
  );
}
