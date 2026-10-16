import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/pop_in.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../order_detail/order_detail_screen.dart';
import 'accept_controls.dart';

/// Orders awaiting acceptance, oldest first.
class ArrivedPane extends ConsumerWidget {
  const ArrivedPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arrived = ref.watch(floorProvider.select((s) => s.arrived));
    final loaded = ref.watch(floorProvider.select((s) => s.loaded));
    final error = ref.watch(floorProvider.select((s) => s.error));

    return RefreshIndicator(
      onRefresh: () => ref.read(floorProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.all(32),
        children: [
          PaneHeader(title: 'Arrived', subtitle: arrived.isEmpty ? null : '${arrived.length} waiting · oldest first'),
          if (!loaded && error != null) InlineError("Can't reach the agent: $error"),
          if (!loaded && error == null)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (loaded && arrived.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: EmptyState(
                icon: Icons.inbox_outlined,
                title: 'No orders waiting',
                message: "New orders ring here the moment they land.",
              ),
            ),
          for (var i = 0; i < arrived.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: PopIn.stagger(
                key: ValueKey(arrived[i].id),
                index: i,
                child: ArrivedCard(order: arrived[i]),
              ),
            ),
        ],
      ),
    );
  }
}

class ArrivedCard extends ConsumerWidget {
  final StoredOrder order;
  const ArrivedCard({super.key, required this.order});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final o = order.order;
    final waiting = ref.watch(floorProvider.select((s) => s.waitingSeconds[order.id]));
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        side: BorderSide(
          color: waiting != null ? QuiccColors.statusVoided : QuiccColors.statusFiring.withValues(alpha: 0.5),
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: InkWell(
                borderRadius: BorderRadius.circular(QuiccRadius.md),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OrderDetailScreen(orderId: order.id, initial: order),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          order.displayNumber,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: QuiccColors.brand400,
                          ),
                        ),
                        const SizedBox(width: 16),
                        FulfillmentTag(o.fulfillment.type),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Ticker(
                            builder: (context, now) {
                              final since = order.status.arrivalDate;
                              if (since == null) return const SizedBox.shrink();
                              final d = now.difference(since);
                              return Text(
                                'waiting ${duration(d)}',
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: d.inMinutes >= 2 ? QuiccColors.statusVoided : context.palette.textSecondary,
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(o.customerName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                    if (o.fulfillment.address != null && !o.fulfillment.address!.isEmpty)
                      Text(o.fulfillment.address!.oneLine, style: TextStyle(color: context.palette.textSecondary)),
                    const SizedBox(height: 10),
                    ItemLines(o.items, maxItems: 6),
                    if (o.notes.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Note: ${o.notes.trim()}',
                        style: const TextStyle(color: QuiccColors.statusFiring, fontWeight: FontWeight.w600),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      '${money(o.money.totalCents)} · ${o.isPrepaid ? 'PAID' : 'NOT PAID'} · arrived ${clock(order.status.arrivalDate)}',
                      style: TextStyle(color: context.palette.textMuted),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(flex: 4, child: AcceptControls(order: order)),
          ],
        ),
      ),
    );
  }
}
