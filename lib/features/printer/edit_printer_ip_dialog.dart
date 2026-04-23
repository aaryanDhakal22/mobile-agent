import 'package:flutter/material.dart';

import '../../theme/quicc_colors.dart';

/// Shows a modal dialog to edit the IP for [name]. Resolves to the new IP
/// string on save, or null if the cashier cancels / dismisses. Empty / unchanged
/// inputs short-circuit to null too, so the caller doesn't fire a pointless
/// PUT.
Future<String?> showEditPrinterIpDialog(
  BuildContext context, {
  required String name,
  required String currentIp,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _EditPrinterIpDialog(name: name, currentIp: currentIp),
  );
}

class _EditPrinterIpDialog extends StatefulWidget {
  final String name;
  final String currentIp;
  const _EditPrinterIpDialog({required this.name, required this.currentIp});

  @override
  State<_EditPrinterIpDialog> createState() => _EditPrinterIpDialogState();
}

class _EditPrinterIpDialogState extends State<_EditPrinterIpDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.currentIp);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final trimmed = _ctrl.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _error = 'IP cannot be empty');
      return;
    }
    if (trimmed == widget.currentIp) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: context.palette.bgSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(QuiccRadius.xl),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: QuiccColors.brand400.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(QuiccRadius.md),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.lan_outlined,
                      color: QuiccColors.brand400,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Set IP â€” ${widget.name}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Agent will probe the new address immediately.',
                          style: TextStyle(
                            color: context.palette.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _ctrl,
                autofocus: true,
                keyboardType: TextInputType.text,
                decoration: InputDecoration(
                  labelText: 'IP address',
                  hintText: '192.168.1.50',
                  errorText: _error,
                  prefixIcon: const Icon(Icons.print_outlined),
                ),
                onSubmitted: (_) => _submit(),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('CANCEL'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submit,
                    child: const Text('SAVE'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
