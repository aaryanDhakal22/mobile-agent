import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../../../core/diag_models.dart';
import '../../../core/providers.dart';
import '../../../theme/quicc_colors.dart';
import '../found_printers.dart';
import '../setup_flow.dart';
import '../setup_widgets.dart';

/// How long "Pi ready" keeps asking the Pi before showing what's missing.
const Duration kPiReadyWait = Duration(seconds: 30);

/// What the link restored, then the Pi's own checks (internet, connection
/// to Quicc, memory card, power) and each printer as it comes online. The Pi
/// may restart right after a link; a few failed polls are expected.
class PiReadyPanel extends ConsumerStatefulWidget {
  final LinkSummary? link;
  final ValueChanged<PiDiag?>? onChanged;
  const PiReadyPanel({super.key, this.link, this.onChanged});

  @override
  ConsumerState<PiReadyPanel> createState() => _PiReadyPanelState();
}

class _PiReadyPanelState extends ConsumerState<PiReadyPanel> {
  PiDiag? _d;
  bool _restarting = false;
  bool _unsupported = false;
  bool _waitedOut = false;
  Timer? _poll;
  late final DateTime _start;

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _read());
    scheduleMicrotask(_read);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// A printer was just added: look again quickly until the Pi has it.
  void _afterAdd(String _) {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _read());
    scheduleMicrotask(_read);
  }

  bool _complete(PiDiag d) => d.connectedToMain && d.printers.isNotEmpty && d.printersDown.isEmpty;

  Future<void> _read() async {
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    try {
      final d = await client.getDiag(timeout: const Duration(seconds: 4));
      if (!mounted) return;
      setState(() {
        _d = d;
        _restarting = false;
      });
      widget.onChanged?.call(d);
      if (_complete(d)) _poll?.cancel();
    } on AgentException catch (e) {
      if (!mounted) return;
      if (e.isNotFound) {
        _poll?.cancel();
        setState(() => _unsupported = true);
        widget.onChanged?.call(null);
        return;
      }
      setState(() => _restarting = e.isNetwork);
    }
    if (!_waitedOut && DateTime.now().difference(_start) > kPiReadyWait && mounted) {
      // Show what's missing, but keep looking (slower): a printer switched
      // on or added now still turns green.
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => _read());
      setState(() => _waitedOut = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final d = _d;
    final waiting = !_waitedOut && !_unsupported;
    // ✓ as soon as it's true; still checking while we wait; ✗ after.
    bool? state(bool good) => good ? true : (waiting ? null : false);

    // A Column (not a ListView) so the found-printers section keeps its state
    // when the restarting line above it comes and goes.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (link != null) _Restored(link: link),
          if (_restarting)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text('The Pi is restarting… (a few seconds)', style: TextStyle(fontSize: 17)),
            ),
          if (_unsupported)
            const CheckRow(
              icon: Icons.info_outline,
              label: "This Pi can't report its health",
              detail: 'It runs an older version. Everything else still works.',
              ok: true,
            )
          else ...[
            CheckRow(
              icon: Icons.public,
              label: 'Internet',
              ok: state(d?.mainReachable == true),
              failText: 'No internet',
            ),
            CheckRow(
              icon: Icons.cloud_done,
              label: 'Connected to Quicc',
              ok: state(d?.connectedToMain == true),
              failText: 'Not connected',
            ),
            CheckRow(
              icon: Icons.sd_card,
              label: 'Memory card',
              detail: d != null && d.health.fileStale ? "The Pi can't check it" : null,
              unknown: d != null && d.health.fileStale,
              ok: d == null ? null : !d.health.sdTrouble,
              failText: 'Errors found',
            ),
            CheckRow(
              icon: Icons.power,
              label: 'Power supply',
              unknown: d != null && d.health.fileStale,
              ok: d == null ? null : !d.health.powerTrouble,
              failText: 'Too weak',
            ),
            const SizedBox(height: 10),
            const Text('Printers', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (d != null && d.printers.isEmpty)
              CheckRow(
                icon: Icons.print_disabled,
                label: waiting ? 'Waiting for the printers…' : 'No printers set up yet',
                detail: waiting ? null : 'Add them on the Quicc website (Store → Printers)',
                ok: waiting ? null : false,
              ),
            for (final p in d?.printers ?? const <DiagPrinter>[])
              CheckRow(
                icon: Icons.print,
                label: p.name + (p.isReceipt ? ' (receipts)' : ''),
                ok: state(p.up),
                failText: 'Not answering',
              ),
            if (d != null)
              FoundPrintersSection(
                key: const ValueKey('found-printers'),
                noPrintersYet: d.printers.isEmpty,
                onAdded: _afterAdd,
              ),
          ],
        ],
      ),
    );
  }
}

class _Restored extends StatelessWidget {
  final LinkSummary link;
  const _Restored({required this.link});

  @override
  Widget build(BuildContext context) {
    final parts = [
      '${link.orders} open order${link.orders == 1 ? '' : 's'}',
      if (link.waiting > 0) '${link.waiting} waiting',
      '${link.drivers} driver${link.drivers == 1 ? '' : 's'}',
      if (link.kitchenNext != null) 'next kitchen # ${link.kitchenNext}',
    ];
    return Card(
      color: QuiccColors.statusPaid.withValues(alpha: 0.12),
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: QuiccColors.statusPaid, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    link.store.isEmpty ? 'The Pi is set up' : 'Linked to ${link.store}',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  Text('Brought back: ${parts.join(' · ')}', style: const TextStyle(fontSize: 17)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
