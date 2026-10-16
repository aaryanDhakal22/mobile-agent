import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../order_detail/order_detail_screen.dart';

/// Accepted orders in kitchen-number order, with prep timers and READY.
class KitchenPane extends ConsumerWidget {
  const KitchenPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kitchen = ref.watch(floorProvider.select((s) => s.kitchen));
    return RefreshIndicator(
      onRefresh: () => ref.read(floorProvider.notifier).refresh(),
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 0),
            sliver: SliverToBoxAdapter(
              child: PaneHeader(title: 'Kitchen', subtitle: kitchen.isEmpty ? null : '${kitchen.length} cooking'),
            ),
          ),
          if (kitchen.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.soup_kitchen_outlined,
                title: 'Nothing cooking',
                message: 'Accepted orders show here until they are marked ready.',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 420,
                  mainAxisExtent: 360,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => KitchenCard(key: ValueKey(kitchen[i].id), order: kitchen[i]),
                  childCount: kitchen.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class KitchenCard extends ConsumerStatefulWidget {
  final StoredOrder order;
  const KitchenCard({super.key, required this.order});

  @override
  ConsumerState<KitchenCard> createState() => _KitchenCardState();
}

class _KitchenCardState extends ConsumerState<KitchenCard> {
  bool _busy = false;
  bool _reprinting = false;

  Future<void> _ready() async {
    setState(() => _busy = true);
    try {
      await ref.read(floorProvider.notifier).ready(widget.order.id);
    } catch (e) {
      if (mounted) {
        toast(
          context,
          e is AgentException && e.isConflict ? 'Already moved on: ${e.message}' : 'Not marked ready: $e',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reprint() async {
    setState(() => _reprinting = true);
    try {
      await ref.read(floorProvider.notifier).reprint(widget.order.id);
      if (mounted) toast(context, 'Reprinted ${widget.order.displayNumber}');
    } catch (e) {
      if (mounted) {
        toast(
          context,
          e is AgentException && e.isPrinterFailure ? 'Printer problem — nothing reprinted.' : 'Reprint failed: $e',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _reprinting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final so = widget.order;
    final o = so.order;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => OrderDetailScreen(orderId: so.id, initial: so),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        so.displayNumber,
                        style: const TextStyle(
                          fontSize: 48,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          color: QuiccColors.brand400,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        FittedBox(fit: BoxFit.scaleDown, child: FulfillmentTag(o.fulfillment.type)),
                        const SizedBox(height: 6),
                        _PrepTimer(order: so),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                o.customerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ClipRect(
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: ItemLines(o.items, maxItems: 5, fontSize: 14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      onPressed: _reprinting ? null : _reprint,
                      child: _reprinting
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.print_outlined),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: QuiccColors.statusPaid,
                          foregroundColor: QuiccColors.brand900,
                        ),
                        onPressed: _busy ? null : _ready,
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text(_busy ? '…' : 'READY'),
                      ),
                    ),
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

/// "12:03 in · 7 min left" or "LATE 3 min".
class _PrepTimer extends StatelessWidget {
  final StoredOrder order;
  const _PrepTimer({required this.order});

  @override
  Widget build(BuildContext context) {
    final st = order.status;
    return Ticker(
      builder: (context, now) {
        final since = st.acceptedAt ?? st.printedDate;
        final eta = st.estimatedReadyAt;
        final elapsed = since == null ? null : now.difference(since);
        final left = eta?.difference(now);
        final late = left != null && left.isNegative;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (elapsed != null)
              Text(
                duration(elapsed),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: late ? QuiccColors.statusVoided : context.palette.textPrimary,
                ),
              ),
            if (left != null)
              Text(
                late ? 'LATE ${minutes(left)}' : '${minutes(left)} left · ${clock(eta)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: late ? FontWeight.w800 : FontWeight.w500,
                  color: late ? QuiccColors.statusVoided : context.palette.textSecondary,
                ),
              ),
          ],
        );
      },
    );
  }
}
