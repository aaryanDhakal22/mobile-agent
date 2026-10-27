import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'batch_texts.dart';

/// The open batch + "Close batch" (end of shift): closes it, opens the next,
/// resets kitchen numbers to 1100 and marks every driver available.
class BatchPane extends ConsumerStatefulWidget {
  const BatchPane({super.key});

  @override
  ConsumerState<BatchPane> createState() => _BatchPaneState();
}

class _BatchPaneState extends ConsumerState<BatchPane> {
  bool _busy = false;
  CloseBatchResult? _last;
  Object? _error;

  Future<void> _close() async {
    final ok = await confirmDialog(
      context,
      title: 'Close this batch?',
      message:
          'Kitchen numbers restart at 1100. Drivers who are out on a run go back to the queue; '
          'clocked-out drivers stay off. If any order is unfinished you\'ll be asked first — '
          'orders nobody accepted are then CANCELLED.',
      confirm: 'CLOSE BATCH',
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final floor = ref.read(floorProvider.notifier);
      // CLOSE ANYWAY only forces the orders that were on screen: the agent is
      // asked again first, and an order that came in while the list was open
      // (it would be cancelled unseen) shows the list again instead.
      Set<String>? shown;
      CloseBatchResult r;
      while (true) {
        try {
          r = await floor.closeBatch(force: false);
          break;
        } on BatchLeftoversException catch (e) {
          if (!mounted) return;
          final ids = e.leftovers.map((o) => o.id).toSet();
          if (shown != null && shown.containsAll(ids)) {
            r = await floor.closeBatch(force: true);
            break;
          }
          final newIds = shown == null ? const <String>{} : ids.difference(shown);
          if (!await _confirmLeftovers(e.leftovers, newIds: newIds) || !mounted) return;
          shown = ids;
        }
      }
      if (mounted) setState(() => _last = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// [newIds]: orders that weren't on the list the last time it was shown.
  Future<bool> _confirmLeftovers(List<StoredOrder> leftovers, {Set<String> newIds = const {}}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${leftovers.length} order${leftovers.length == 1 ? ' is' : 's are'} not finished'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (newIds.isNotEmpty) ...[
                Text(
                  '${newIds.length} new order${newIds.length == 1 ? ' came' : 's came'} in — check the list again.',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: QuiccColors.statusFiring),
                ),
                const SizedBox(height: 8),
              ],
              const Text(
                'Closing anyway finishes them automatically: orders in progress → ready '
                '(pickup / dine-in) or delivered (delivery). Orders nobody accepted are CANCELLED '
                '(never printed, no kitchen number). Drivers who were out go back to the queue.',
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final o in leftovers)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Text(
                          o.displayNumber,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: QuiccColors.brand400,
                          ),
                        ),
                        title: Text(
                          '${newIds.contains(o.id) ? 'NEW · ' : ''}'
                          '${o.order.customerName} · ${o.order.fulfillment.type.label}',
                        ),
                        trailing: StatePill(o.state),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('KEEP BATCH OPEN')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: QuiccColors.statusVoided),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('CLOSE ANYWAY'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final fs = ref.watch(floorProvider);
    final floor = fs.floor;
    final current = fs.currentBatchOrders;
    final unfinished = current.where((o) => !o.isFinished).length;

    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const PaneHeader(title: 'Batch'),
        if (_last != null) ...[
          Card(
            color: QuiccColors.statusPaid.withValues(alpha: 0.12),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: QuiccColors.statusPaid, size: 36),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Batch #${_last!.closed.id} closed'
                      '${_last!.closed.orderCount > 0 ? ' with ${_last!.closed.orderCount} orders' : ''}'
                      '${_last!.autoFinished.isEmpty ? '' : ' · ${_last!.autoFinished.length} auto-finished'}.'
                      ' New batch ${floor == null ? '' : '#${floor.batch.id} '}is open — kitchen numbers restart at 1100.'
                      ' Driver reports are printing on the receipt printer.',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(onPressed: () => setState(() => _last = null), icon: const Icon(Icons.close)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: floor == null
                ? const Text('Loading…')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Eyebrow('Open batch'),
                      const SizedBox(height: 8),
                      Text(
                        '#${floor.batch.id}',
                        style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800, color: QuiccColors.brand400),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 40,
                        runSpacing: 12,
                        children: [
                          _Stat('Opened', dateClock(floor.batch.openedAt)),
                          _Stat('Orders', '${current.length}'),
                          _Stat('Unfinished', '$unfinished'),
                          _Stat('Next kitchen #', floor.kitchenNext == 0 ? '—' : '${floor.kitchenNext}'),
                          _Stat('Drivers out', '${fs.driversOut.length}'),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 20),
        if (_error != null) ...[
          InlineError.from(_error!, lead: 'Batch not closed', area: 'batch'),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            SizedBox(
              height: 64,
              child: FilledButton.icon(
                onPressed: (_busy || floor == null) ? null : _close,
                icon: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3))
                    : const Icon(Icons.lock_clock_outlined),
                label: const Text('CLOSE BATCH'),
              ),
            ),
            const SizedBox(width: 8),
            const InfoButton(kCloseBatchInfo, size: 24),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Close the batch at the end of a shift. Unfinished orders are listed for confirmation first. '
          'Each driver\'s report prints when the batch closes.',
          style: TextStyle(color: context.palette.textMuted),
        ),
        const SizedBox(height: 28),
        _DriverReportsCard(key: ValueKey(_last?.closed.id ?? 0), initialBatch: _last?.closed.id),
      ],
    );
  }
}

/// Per-driver reports for a batch (open or a kept closed one): deliveries,
/// cash owed, tips after tip tax, owed to the store — and a reprint button.
class _DriverReportsCard extends ConsumerStatefulWidget {
  final int? initialBatch;
  const _DriverReportsCard({super.key, this.initialBatch});

  @override
  ConsumerState<_DriverReportsCard> createState() => _DriverReportsCardState();
}

class _DriverReportsCardState extends ConsumerState<_DriverReportsCard> {
  List<Batch> _batches = const [];
  int _batch = 0; // 0 = open batch
  Future<List<DriverReport>>? _reports;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _batch = widget.initialBatch ?? 0;
    _load(first: true);
  }

  /// [first]: from initState, where setState isn't allowed yet.
  void _load({bool first = false}) {
    final c = ref.read(agentClientProvider);
    if (c == null) return;
    c
        .listBatches()
        .then((b) {
          if (mounted) setState(() => _batches = b);
        })
        .catchError((Object _) {});
    final reports = c.driverReports(_batch);
    if (first) {
      _reports = reports;
    } else {
      setState(() => _reports = reports);
    }
  }

  Future<void> _print() async {
    final c = ref.read(agentClientProvider);
    if (c == null) return;
    setState(() => _printing = true);
    try {
      final r = await c.printDriverReports(_batch);
      if (!mounted) return;
      if (r.printed.isEmpty && r.failed.isEmpty) {
        toast(context, 'No drivers in this batch');
      } else {
        toast(
          context,
          'Printed ${r.printed.length} report${r.printed.length == 1 ? '' : 's'}'
          '${r.failed.isEmpty ? '' : ' — NOT printed: ${r.failed.join(', ')}'}',
          error: r.failed.isNotEmpty,
        );
      }
    } catch (e) {
      if (mounted) toastError(context, e, lead: 'Not printed', area: 'batch');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tipTax = ref.watch(floorProvider.select((s) => s.floor?.tipTaxPercent ?? 6));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                LabelWithInfo(label: const Eyebrow('Driver reports'), info: driverReportInfo(tipTax)),
                const Spacer(),
                IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final b in _batches)
                  ChoiceChip(
                    label: Text(b.closedAt == null ? 'Batch #${b.id} (open)' : 'Batch #${b.id}'),
                    selected: _batch == b.id || (_batch == 0 && b.closedAt == null),
                    onSelected: (_) {
                      _batch = b.closedAt == null ? 0 : b.id;
                      _load();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FutureBuilder<List<DriverReport>>(
              future: _reports,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const Text('Loading…');
                if (snap.hasError) {
                  return InlineError.from(snap.error!, lead: 'Reports not loaded', area: 'batch', onRetry: _load);
                }
                final reps = snap.data ?? const [];
                if (reps.isEmpty) {
                  return Text('No drivers worked this batch.', style: TextStyle(color: p.textMuted));
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final r in reps) _ReportRow(r)],
                );
              },
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: _printing ? null : _print,
                  icon: _printing
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.print_outlined),
                  label: const Text('PRINT DRIVER REPORTS'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportRow extends StatelessWidget {
  final DriverReport r;
  const _ReportRow(this.r);

  @override
  Widget build(BuildContext context) {
    final owes = r.owedCents >= 0;
    final pos = r.pos;
    // Pi 2.2.3: the POS cross-check's remarks, small and muted.
    final remarks = [
      ...r.notes,
      for (final l in r.lines)
        if (l.note.isNotEmpty) '#${l.displayNumber ?? l.kitchenNumber ?? '?'} ${l.note}',
    ];
    final row = Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(r.driverName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        Expanded(flex: 2, child: _Stat('Deliveries', '${r.deliveries}')),
        Expanded(flex: 2, child: _Stat('Cash owed', money(r.cashCents))),
        Expanded(flex: 2, child: _Stat('Tips (A/T)', money(r.tipAfterTaxCents))),
        Expanded(flex: 3, child: _Stat(owes ? 'Owed to store' : 'Store owes driver', money(r.owedCents.abs()))),
      ],
    );
    final unchecked = pos == null || pos.checked
        ? null
        : 'POS not checked${pos.note.isEmpty ? '' : ' — ${pos.note}'}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: unchecked == null && remarks.isEmpty
          ? row
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row,
                if (unchecked != null)
                  Text(unchecked, style: const TextStyle(fontSize: 14, color: QuiccColors.statusFiring)),
                if (remarks.isNotEmpty)
                  Text(remarks.join(' · '), style: TextStyle(fontSize: 14, color: context.palette.textMuted)),
              ],
            ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat(this.label, this.value);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Eyebrow(label),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
    ],
  );
}
