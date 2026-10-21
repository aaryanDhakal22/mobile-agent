import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../common/widgets.dart';
import '../../core/local_log.dart';
import '../../core/printer_models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import 'setup_widgets.dart';

/// Names offered as chips when adding a printer (the field stays editable).
const List<String> kPrinterNameSuggestions = ['Online', 'Pizza', 'Desi', 'Sub', 'Wings', 'Kitchen'];

/// "Found on the network": printers the Pi found that the store doesn't have
/// yet, each with ADD (name it → the Pi asks main to add it). Hidden on a Pi
/// without the routes (older version).
class FoundPrintersSection extends ConsumerStatefulWidget {
  /// The store has no printers yet: the first one added prints the receipts.
  final bool noPrintersYet;

  /// Called with the added printer's name, after main took it.
  final ValueChanged<String>? onAdded;

  const FoundPrintersSection({super.key, this.noPrintersYet = false, this.onAdded});

  @override
  ConsumerState<FoundPrintersSection> createState() => _FoundPrintersSectionState();
}

class _FoundPrintersSectionState extends ConsumerState<FoundPrintersSection> {
  FoundPrinters? _found;
  bool _unsupported = false;
  bool _failed = false;
  bool _scanning = false;
  bool _askedForScan = false;
  final Set<String> _adding = {};
  final Set<String> _added = {};
  Timer? _again;
  int _scanPolls = 0;

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() => _load());
  }

  @override
  void dispose() {
    _again?.cancel();
    super.dispose();
  }

  void _later(Duration d, {bool refresh = false}) {
    _again?.cancel();
    _again = Timer(d, () => _load(refresh: refresh));
  }

  Future<void> _load({bool refresh = false}) async {
    final client = ref.read(agentClientProvider);
    if (client == null || _unsupported) return;
    if (refresh) {
      _again?.cancel();
      _scanPolls = 0;
      setState(() => _scanning = true);
    }
    try {
      final f = await client.foundPrinters(refresh: refresh);
      if (!mounted) return;
      setState(() {
        _found = f;
        _failed = false;
        _scanning = f.scanning;
      });
      if (f.scanning && _scanPolls++ < 15) {
        _later(const Duration(seconds: 2));
      } else if (f.scannedAt == null && !f.scanning && !_askedForScan) {
        // The Pi hasn't looked yet: ask it to, once.
        _askedForScan = true;
        unawaited(_load(refresh: true));
      }
    } on AgentException catch (e) {
      if (!mounted) return;
      if (e.isMissingRoute) {
        _again?.cancel();
        setState(() => _unsupported = true);
        return;
      }
      setState(() {
        _failed = true;
        _scanning = false;
      });
    }
  }

  Future<void> _add(FoundPrinter p) async {
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    String? error;
    var name = '';
    while (true) {
      final picked = await printerNameDialog(context, ip: p.ip, initial: name, error: error);
      if (picked == null || !mounted) return;
      name = picked;
      setState(() => _adding.add(p.ip));
      try {
        final added = await client.addPrinter(name, p.ip, p.mac);
        if (!mounted) return;
        final shown = added.name.isEmpty ? name : added.name;
        ref.read(localLogProvider).add('setup', 'added printer $shown at ${p.ip} ${p.mac}');
        setState(() {
          _adding.remove(p.ip);
          _added.add(p.ip);
        });
        toast(context, 'Added $shown. The Pi gets it in a few seconds.');
        widget.onAdded?.call(shown);
        // The Pi learns the new roster once main pushes it.
        _later(const Duration(seconds: 4));
        return;
      } on AgentException catch (e) {
        if (!mounted) return;
        setState(() => _adding.remove(p.ip));
        ref.read(localLogProvider).warn('setup', 'add printer ${p.ip}: ${e.statusCode} ${e.code} ${e.message}');
        if (e.code == kPrinterNameTaken) {
          error = 'There is already a printer called "$name". Pick another name.';
          continue;
        }
        toastError(context, e, lead: 'Not added', area: 'setup');
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) return const SizedBox.shrink();
    final muted = TextStyle(fontSize: 16, color: context.palette.textSecondary);
    final f = _found;
    final rows = (f?.unknown ?? const <FoundPrinter>[]).where((p) => !_added.contains(p.ip)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        Row(
          children: [
            const Expanded(
              child: Text('Found on the network', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(
              onPressed: _scanning ? null : () => _load(refresh: true),
              icon: const Icon(Icons.refresh),
              label: const Text('SCAN AGAIN', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
        if (widget.noPrintersYet)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('The first printer you add prints the customer receipts.', style: muted),
          ),
        if (_scanning)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(width: 12),
                Text('Looking for printers…', style: muted),
              ],
            ),
          ),
        for (final p in rows)
          CheckRow(
            icon: Icons.print_outlined,
            label: 'Printer at ${p.ip}',
            detail: p.mac.isEmpty ? null : p.mac,
            ok: _adding.contains(p.ip) ? null : false,
            actionLabel: 'ADD',
            onAction: _adding.isEmpty ? () => _add(p) : null,
          ),
        if (!_scanning && f != null && rows.isEmpty)
          Text('No new printers found. Check new printers are on and plugged in.', style: muted),
        if (!_scanning && f == null && _failed) Text("Couldn't look for printers. Tap SCAN AGAIN.", style: muted),
      ],
    );
  }
}

/// Asks what to call the printer at [ip]: common station names as chips, a
/// required text field. Resolves the trimmed name, or null on CANCEL.
Future<String?> printerNameDialog(BuildContext context, {required String ip, String initial = '', String? error}) =>
    showDialog<String>(
      context: context,
      builder: (ctx) => _PrinterNameDialog(ip: ip, initial: initial, error: error),
    );

// Owns its controller (see textDialog: disposing it early breaks the exit
// animation).
class _PrinterNameDialog extends StatefulWidget {
  final String ip;
  final String initial;
  final String? error;
  const _PrinterNameDialog({required this.ip, required this.initial, this.error});

  @override
  State<_PrinterNameDialog> createState() => _PrinterNameDialogState();
}

class _PrinterNameDialogState extends State<_PrinterNameDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _done() {
    final v = _ctrl.text.trim();
    if (v.isNotEmpty) Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final current = _ctrl.text.trim().toLowerCase();
    return AlertDialog(
      title: const Text('Name this printer'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Printer at ${widget.ip}. Use the station it prints for.',
              style: TextStyle(fontSize: 16, color: context.palette.textSecondary),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in kPrinterNameSuggestions)
                  ChoiceChip(
                    label: Text(s, style: const TextStyle(fontSize: 16)),
                    selected: current == s.toLowerCase(),
                    onSelected: (_) => _ctrl.value = TextEditingValue(
                      text: s,
                      selection: TextSelection.collapsed(offset: s.length),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              autofocus: widget.error != null,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(hintText: 'Printer name', errorText: widget.error, errorMaxLines: 2),
              onSubmitted: (_) => _done(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CANCEL')),
        FilledButton(onPressed: _ctrl.text.trim().isEmpty ? null : _done, child: const Text('ADD')),
      ],
    );
  }
}
