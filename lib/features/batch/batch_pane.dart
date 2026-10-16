import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';

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
  String? _error;

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
      CloseBatchResult r;
      try {
        r = await ref.read(floorProvider.notifier).closeBatch(force: false);
      } on BatchLeftoversException catch (e) {
        if (!mounted) return;
        final force = await _confirmLeftovers(e.leftovers);
        if (!force || !mounted) return;
        r = await ref.read(floorProvider.notifier).closeBatch(force: true);
      }
      if (mounted) setState(() => _last = r);
    } catch (e) {
      if (mounted) setState(() => _error = 'Batch not closed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmLeftovers(List<StoredOrder> leftovers) async {
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
                        title: Text('${o.order.customerName} · ${o.order.fulfillment.type.label}'),
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
                      ' New batch ${floor == null ? '' : '#${floor.batch.id} '}is open — kitchen numbers restart at 1100.',
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
        if (_error != null) ...[InlineError(_error!), const SizedBox(height: 12)],
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            height: 64,
            child: FilledButton.icon(
              onPressed: (_busy || floor == null) ? null : _close,
              icon: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3))
                  : const Icon(Icons.lock_clock_outlined),
              label: const Text('CLOSE BATCH'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Close the batch at the end of a shift. Unfinished orders are listed for confirmation first.',
          style: TextStyle(color: context.palette.textMuted),
        ),
      ],
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
