import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../diagnose/diagnose_entry.dart';
import '../diagnose/full_check_screen.dart';
import '../diagnose/texts.dart';
import '../settings/settings_card.dart';
import '../setup/setup_entry.dart';
import 'dev_texts.dart';
import 'dev_widgets.dart';

/// Developer mode → Tests: the full check, the tablet checks, test ring,
/// test print and sending diagnostics — each with what it does in a line.
class DevTestsScreen extends ConsumerWidget {
  const DevTestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    return DevPane(
      title: DevText.testsTitle,
      subtitle: DevText.testsSubtitle,
      children: [
        SettingsCard(
          title: 'Checks and tests',
          info: kTestsInfo,
          subtitle: 'Safe at any time — nothing here changes an order.',
          children: [
            _TestRow(
              key: const ValueKey('test-full'),
              icon: Icons.fact_check_outlined,
              label: GuideText.fullCheck,
              line: DevText.fullCheckLine,
              action: 'RUN',
              primary: true,
              onTap: () => push(const FullCheckScreen()),
            ),
            _TestRow(
              key: const ValueKey('test-tablet'),
              icon: Icons.tablet_android,
              label: GuideText.tabletChecks,
              line: DevText.tabletChecksLine,
              action: 'CHECK',
              onTap: () => push(const TabletChecksScreen()),
            ),
            _TestRow(
              key: const ValueKey('test-ring'),
              icon: Icons.notifications_active_outlined,
              label: GuideText.testRing,
              line: DevText.testRingLine,
              action: 'RING',
              onTap: () => push(const TestRingScreen()),
            ),
            _TestRow(
              key: const ValueKey('test-print'),
              icon: Icons.print_outlined,
              label: GuideText.testPrint,
              line: DevText.testPrintLine,
              action: 'PRINT',
              onTap: () => push(const TestPrintScreen()),
            ),
            _TestRow(
              key: const ValueKey('test-send'),
              icon: Icons.send_outlined,
              label: GuideText.sendDiag,
              line: DevText.sendLine,
              action: 'SEND',
              onTap: () => showSendDiagnosticsDialog(context, ref),
            ),
          ],
        ),
      ],
    );
  }
}

class _TestRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String line;
  final String action;
  final bool primary;
  final VoidCallback onTap;
  const _TestRow({
    super.key,
    required this.icon,
    required this.label,
    required this.line,
    required this.action,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: QuiccSpace.sm),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: QuiccColors.brand400.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(QuiccRadius.md),
            ),
            child: Icon(icon, color: QuiccColors.brand400),
          ),
          QuiccSpace.gapLg,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
                Text(line, style: QuiccType.text(QuiccType.label, color: palette.textSecondary)),
              ],
            ),
          ),
          QuiccSpace.gapLg,
          SizedBox(
            width: 120,
            height: 52,
            child: primary
                ? FilledButton(onPressed: onTap, child: Text(action))
                : OutlinedButton(onPressed: onTap, child: Text(action)),
          ),
        ],
      ),
    );
  }
}
