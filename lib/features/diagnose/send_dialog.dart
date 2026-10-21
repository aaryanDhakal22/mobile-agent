import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/local_log.dart';
import 'report.dart';
import 'texts.dart';

/// "Send diagnostics to the owner": an optional note, then a `manual` (or
/// [kind]) report. Shows "Sent to the owner" / "Saved — …" as a toast.
Future<void> showSendDiagnosticsDialog(
  BuildContext context,
  WidgetRef ref, {
  String kind = 'manual',
  Map<String, Object?>? checks,
}) async {
  final note = await showDialog<String>(context: context, builder: (_) => const _NoteDialog());
  if (note == null || !context.mounted) return;
  toast(context, ReportText.sending);
  final sender = ref.read(reportSenderProvider);
  ref.read(localLogProvider).add('report', 'manual send ($kind)');
  final r = await sender.buildReport(
    kind: kind,
    outcome: 'info',
    headline: note.isEmpty ? 'Diagnostics sent from the tablet' : note,
    note: note.isEmpty ? null : note,
    checks: checks,
  );
  final res = await sender.send(r);
  if (context.mounted) toast(context, res == ReportOutcome.sent ? ReportText.sent : ReportText.saved);
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog();

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(GuideText.sendDiag),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          maxLength: 500,
          maxLines: 3,
          minLines: 2,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontSize: 18),
          decoration: const InputDecoration(labelText: ReportText.notePrompt, hintText: ReportText.noteHint),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()), child: const Text(ReportText.send)),
      ],
    );
  }
}
