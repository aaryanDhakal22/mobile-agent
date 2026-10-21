import 'package:flutter/material.dart';

import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';

/// A Settings card: eyebrow title + (i), optional subtitle, then [children].
class SettingsCard extends StatelessWidget {
  final String title;
  final InfoText info;
  final String? subtitle;
  final List<Widget> children;
  const SettingsCard({super.key, required this.title, required this.info, this.subtitle, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: LabelWithInfo(label: Eyebrow(title), info: info),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: TextStyle(color: context.palette.textSecondary)),
              ],
              const SizedBox(height: 14),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
