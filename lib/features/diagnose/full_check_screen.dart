import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/friendly_error.dart';
import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import 'checks.dart';
import 'diagnose_entry.dart';
import 'texts.dart';

/// Which guide fixes a failed check (null = none).
GuideId? guideForCheck(CheckResult r, CheckSnapshot s) {
  if (r.status != CheckStatus.fail) return null;
  return switch (r.id) {
    CheckId.tabletNetwork || CheckId.piDiscovered || CheckId.piPort => GuideId.piUnreachable,
    CheckId.piApi => s.piAnswers ? GuideId.piSwap : GuideId.piUnreachable,
    CheckId.tabletInternet || CheckId.mainFromTablet || CheckId.ordersFlow => GuideId.noOrders,
    CheckId.piToMain => s.piToMain == 'rejected' ? GuideId.piSwap : GuideId.noOrders,
    CheckId.piHealth => s.sdSuspect ? GuideId.piSwap : null,
    CheckId.printers => GuideId.printer,
  };
}

/// "Run a full check": every check as a plain sentence with ✓ / ✗, and FIX IT
/// where a guide can help.
class FullCheckScreen extends ConsumerStatefulWidget {
  const FullCheckScreen({super.key});

  @override
  ConsumerState<FullCheckScreen> createState() => _FullCheckScreenState();
}

class _FullCheckScreenState extends ConsumerState<FullCheckScreen> {
  CheckSnapshot? _snap;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_run);
  }

  Future<void> _run() async {
    if (_running || !mounted) return;
    setState(() => _running = true);
    try {
      final s = await ref.read(checksRunnerProvider).run(probePrinters: true);
      if (mounted) setState(() => _snap = s);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final s = _snap;
    return Scaffold(
      appBar: AppBar(
        title: const Text(GuideText.fullCheck),
        actions: [
          const InfoButton(GuideText.fullCheckInfo),
          TextButton.icon(
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.refresh),
            label: const Text('RUN AGAIN'),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: s == null
                ? null
                : () => showSendDiagnosticsDialog(context, ref, kind: 'full_check', checks: s.toReport()),
            icon: const Icon(Icons.send_outlined),
            label: const Text('SEND TO THE OWNER'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: s == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 5)),
                  const SizedBox(height: 20),
                  Text(GuideText.checking, style: TextStyle(fontSize: 22, color: palette.textSecondary)),
                ],
              ),
            )
          : Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  children: [for (final r in s.results.values) CheckRow(result: r, fix: guideForCheck(r, s))],
                ),
                if (_running) const LinearProgressIndicator(),
              ],
            ),
    );
  }
}

/// One status-board row: ✓ / ✗ / ?, the sentence, FIX IT.
class CheckRow extends StatelessWidget {
  final CheckResult result;
  final GuideId? fix;
  const CheckRow({super.key, required this.result, this.fix});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (icon, color) = switch (result.status) {
      CheckStatus.ok => (Icons.check_circle, QuiccColors.statusPaid),
      CheckStatus.fail => (Icons.cancel, QuiccColors.statusVoided),
      CheckStatus.unknown => (Icons.help_outline, palette.textMuted),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: color, size: 30),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              result.plain,
              style: TextStyle(
                fontSize: 19,
                fontWeight: result.failed ? FontWeight.w700 : FontWeight.w500,
                color: result.status == CheckStatus.unknown ? palette.textMuted : null,
              ),
            ),
          ),
          if (fix != null)
            FilledButton(
              onPressed: () => openGuide(context, fix!),
              style: FilledButton.styleFrom(minimumSize: const Size(120, 52)),
              child: const Text(GuideText.fixIt),
            ),
        ],
      ),
    );
  }
}
