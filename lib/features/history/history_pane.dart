import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../order_detail/order_detail_screen.dart';

/// Orders of the current batch (live) or a kept closed batch.
class HistoryPane extends ConsumerStatefulWidget {
  const HistoryPane({super.key});

  @override
  ConsumerState<HistoryPane> createState() => _HistoryPaneState();
}

class _HistoryPaneState extends ConsumerState<HistoryPane> {
  int? _batchId; // null → current (open) batch

  @override
  Widget build(BuildContext context) {
    final currentId = ref.watch(floorProvider.select((s) => s.currentBatchId));
    final batches = ref.watch(batchesProvider);
    final showingCurrent = _batchId == null || _batchId == currentId;

    final AsyncValue<List<StoredOrder>> orders = showingCurrent
        ? AsyncValue.data(ref.watch(floorProvider.select((s) => s.currentBatchOrders)))
        : ref.watch(batchOrdersProvider(_batchId!));

    final options = batches.valueOrNull ?? const <Batch>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(
            title: 'History',
            subtitle: orders.valueOrNull == null ? null : '${orders.valueOrNull!.length} orders',
            trailing: SizedBox(
              width: 340,
              child: DropdownButtonFormField<int?>(
                key: ValueKey('batch-$currentId-${options.length}'),
                initialValue: showingCurrent ? null : _batchId,
                isExpanded: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.layers_outlined),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                items: [
                  DropdownMenuItem<int?>(
                    value: null,
                    child: Text('Current batch${currentId == null ? '' : ' #$currentId'}'),
                  ),
                  for (final b in options.where((b) => b.id != currentId))
                    DropdownMenuItem<int?>(
                      value: b.id,
                      child: Text('Batch #${b.id} · ${dateClock(b.openedAt)} · ${b.orderCount}'),
                    ),
                ],
                onChanged: (v) => setState(() => _batchId = v),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(batchesProvider);
                if (showingCurrent) {
                  await ref.read(floorProvider.notifier).refresh();
                } else {
                  ref.invalidate(batchOrdersProvider(_batchId!));
                }
              },
              child: orders.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ListView(
                  children: [
                    InlineError.from(
                      e,
                      lead: 'Could not load orders',
                      area: 'history',
                      onRetry: () => ref.invalidate(batchOrdersProvider(_batchId!)),
                    ),
                  ],
                ),
                data: (list) => list.isEmpty
                    ? ListView(
                        children: const [
                          SizedBox(height: 80),
                          EmptyState(icon: Icons.receipt_long_outlined, title: 'No orders in this batch'),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 32),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => HistoryRow(order: list[i]),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HistoryRow extends StatelessWidget {
  final StoredOrder order;
  const HistoryRow({super.key, required this.order});

  @override
  Widget build(BuildContext context) {
    final o = order.order;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => OrderDetailScreen(orderId: order.id, initial: order),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              SizedBox(
                width: 96,
                child: Text(
                  order.displayNumber,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: QuiccColors.brand400),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.customerName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (o.fulfillment.type != FulfillmentType.unknown) o.fulfillment.type.label,
                        '${o.itemCount} item${o.itemCount == 1 ? '' : 's'}',
                        clock(order.status.arrivalDate ?? o.receivedAt),
                        // Cancelled (e.g. NOT DELIVERED → CANCEL ORDER): no driver.
                        if (order.status.driverName != null && order.state != OrderState.cancelled)
                          'driver ${order.status.driverName}',
                        if (order.isCameBack) 'came back',
                      ].join(' · '),
                      style: TextStyle(color: context.palette.textSecondary),
                    ),
                  ],
                ),
              ),
              StatePill(order.state),
              const SizedBox(width: 16),
              SizedBox(
                width: 96,
                child: Text(
                  money(o.money.totalCents),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: context.palette.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
