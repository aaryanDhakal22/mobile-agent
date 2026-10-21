import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../../../core/diag_models.dart';
import '../../../core/friendly_error.dart';
import '../../../core/local_log.dart';
import '../../../core/providers.dart';
import '../../../theme/quicc_colors.dart';
import '../setup_widgets.dart';

/// What to check when a printer didn't answer the test.
String printerAdvice(String errorCode) => switch (errorCode) {
  'unreachable' => 'Check the printer is on, and its network cable is plugged in at both ends.',
  'write_failed' => 'The printer answered but the print failed. Check paper and that the lid is closed.',
  'not_configured' => 'This printer is not set up on the Quicc website.',
  _ => 'Check the printer is on, has paper and its cable is plugged in.',
};

/// Prints a short TEST slip on every printer (never on another printer in
/// its place), then asks per printer whether a slip came out.
class TestPrintPanel extends ConsumerStatefulWidget {
  /// Called with printer id → "a slip came out".
  final ValueChanged<Map<String, bool>>? onResult;
  final void Function(GuideId)? onFix;
  const TestPrintPanel({super.key, this.onResult, this.onFix});

  @override
  ConsumerState<TestPrintPanel> createState() => _TestPrintPanelState();
}

class _TestPrintPanelState extends ConsumerState<TestPrintPanel> {
  bool _busy = false;
  List<PrinterTestResult>? _results;
  final Map<String, bool> _cameOut = {};
  FriendlyError? _error;
  bool _unsupported = false;

  Future<void> _run() async {
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _cameOut.clear();
    });
    try {
      final r = await client.testPrinters();
      if (!mounted) return;
      setState(() => _results = r);
      for (final x in r.where((x) => !x.ok)) {
        ref.read(localLogProvider).warn('setup', 'test print ${x.name}: ${x.errorCode} ${x.error}');
      }
      _report();
    } on AgentException catch (e) {
      if (!mounted) return;
      // An older Pi: 404 (agent < 2.0) or 405 (2.0.0's mux for a POST).
      if (e.isMissingRoute) {
        setState(() => _unsupported = true);
      } else {
        setState(() => _error = FriendlyError.from(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _report() {
    final r = _results ?? const [];
    widget.onResult?.call({for (final x in r) x.id: x.ok && (_cameOut[x.id] ?? true)});
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) {
      return const Center(
        child: Text(
          "This Pi can't do test prints (older version). The first real order will show if the printers work.",
          style: TextStyle(fontSize: 18),
          textAlign: TextAlign.center,
        ),
      );
    }
    final r = _results;
    return ListView(
      children: [
        Row(
          children: [
            BigButton(r == null ? 'PRINT TEST SLIPS' : 'PRINT AGAIN', icon: Icons.print, busy: _busy, onPressed: _run),
            if (_busy) ...[
              const SizedBox(width: 16),
              const Expanded(
                child: Text('Printing… a printer that is off can take 15 seconds', style: TextStyle(fontSize: 16)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Text(
            '${_error!.title}. ${_error!.whatToDo}',
            style: const TextStyle(fontSize: 17, color: QuiccColors.statusVoided),
          ),
        if (r != null && r.isEmpty)
          const Text(
            'No printers set up yet. Add them on the Quicc website (Store → Printers).',
            style: TextStyle(fontSize: 18),
          ),
        for (final x in r ?? const <PrinterTestResult>[])
          x.ok
              ? _CameOutRow(
                  name: x.name,
                  answer: _cameOut[x.id],
                  onAnswer: (v) {
                    setState(() => _cameOut[x.id] = v);
                    if (!v) ref.read(localLogProvider).warn('setup', 'test slip did not come out of ${x.name}');
                    _report();
                  },
                  onFix: widget.onFix == null ? null : () => widget.onFix!(GuideId.printer),
                )
              : CheckRow(
                  icon: Icons.print_disabled,
                  label: x.name,
                  detail: printerAdvice(x.errorCode),
                  ok: false,
                  actionLabel: widget.onFix == null ? null : 'FIX IT',
                  onAction: widget.onFix == null ? null : () => widget.onFix!(GuideId.printer),
                  failText: 'Not answering',
                ),
      ],
    );
  }
}

class _CameOutRow extends StatelessWidget {
  final String name;
  final bool? answer;
  final ValueChanged<bool> onAnswer;
  final VoidCallback? onFix;
  const _CameOutRow({required this.name, required this.answer, required this.onAnswer, this.onFix});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.print, size: 30, color: context.palette.textSecondary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
                  Text(
                    answer == false
                        ? 'Check paper and the lid. ${onFix == null ? '' : 'Tap FIX IT for help.'}'
                        : 'Did a TEST slip come out?',
                    style: TextStyle(fontSize: 15, color: context.palette.textSecondary),
                  ),
                ],
              ),
            ),
            if (answer == true)
              const Icon(Icons.check_circle, color: QuiccColors.statusPaid, size: 34)
            else if (answer == false && onFix != null)
              FilledButton.tonal(onPressed: onFix, child: const Text('FIX IT'))
            else ...[
              FilledButton(onPressed: () => onAnswer(true), child: const Text('YES')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => onAnswer(false), child: const Text('NO')),
            ],
          ],
        ),
      ),
    );
  }
}
