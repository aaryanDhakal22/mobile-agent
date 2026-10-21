import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'setup_controller.dart';
import 'setup_texts.dart';
import 'steps/test_print_step.dart';
import 'steps/test_ring_step.dart';
import 'steps/tablet_checks_step.dart';

// Entry points into the setup wizard's pieces that other screens open
// (Settings / Help → re-run checks, test ring, test print, continue setup).

class _Standalone extends StatelessWidget {
  final String title;
  final InfoText info;
  final Widget body;
  const _Standalone({required this.title, required this.info, required this.body});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Row(children: [Text(title), InfoButton(info)]),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('DONE')),
        ),
      ],
    ),
    body: Padding(padding: const EdgeInsets.fromLTRB(32, 16, 32, 16), child: body),
  );
}

/// The tablet checks (notifications, full-screen alerts, battery, installs,
/// alarm volume) as a standalone screen.
class TabletChecksScreen extends StatelessWidget {
  const TabletChecksScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const _Standalone(title: 'Tablet checks', info: SetupInfo.checks, body: TabletChecksPanel());
}

/// "Did you hear it?" test ring as a standalone screen.
class TestRingScreen extends StatelessWidget {
  const TestRingScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const _Standalone(title: 'Test ring', info: SetupInfo.testRing, body: TestRingPanel());
}

/// Test print on every printer as a standalone screen.
class TestPrintScreen extends StatelessWidget {
  const TestPrintScreen({super.key});
  @override
  Widget build(BuildContext context) => _Standalone(
    title: 'Test print',
    info: SetupInfo.testPrint,
    body: TestPrintPanel(onFix: (g) => openGuideHook(context, g)),
  );
}

/// Settings card shown while the setup wizard was left unfinished
/// ("Setup isn't finished – CONTINUE"); renders nothing otherwise.
class ContinueSetupCard extends ConsumerWidget {
  const ContinueSetupCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(setupProvider);
    if (p == null || p.isDone || !p.finishedLater) return const SizedBox.shrink();
    return Card(
      color: QuiccColors.statusFiring.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.checklist, size: 34, color: QuiccColors.statusFiring),
            const SizedBox(width: 16),
            const Expanded(
              child: Text("Setup isn't finished", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ),
            FilledButton(
              onPressed: () => ref.read(setupProvider.notifier).resumeLater(),
              child: const Text('CONTINUE'),
            ),
          ],
        ),
      ),
    );
  }
}
