import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../order_detail/order_detail_screen.dart';

/// Ticket column width and gap (compact tickets, ~6 across on the tablet).
const double kTicketWidth = 280;
const double kTicketGap = 12;

/// How late a ticket looks: green until [greenTill] minutes after the order
/// arrived, then amber, fully red at twice [greenTill].
Color lateColor(Duration sinceArrival, int greenTill) {
  final g = greenTill <= 0 ? kDefaultGreenTillMinutes : greenTill;
  final m = sinceArrival.inSeconds / 60.0;
  if (m <= g) return QuiccColors.statusPaid;
  final t = ((m - g) / g).clamp(0.0, 1.0);
  return t < 0.5
      ? Color.lerp(QuiccColors.statusPaid, QuiccColors.statusFiring, t * 2)!
      : Color.lerp(QuiccColors.statusFiring, QuiccColors.statusVoided, (t - 0.5) * 2)!;
}

/// Deals tickets (already sorted, most urgent first) into [columns] columns
/// left → right, so reading across the top row gives the most urgent ones.
List<List<T>> dealIntoColumns<T>(List<T> items, int columns) {
  final n = columns < 1 ? 1 : columns;
  final out = List.generate(n, (_) => <T>[]);
  for (var i = 0; i < items.length; i++) {
    out[i % n].add(items[i]);
  }
  return out;
}

/// Accepted orders as compact tickets, most urgent first, in masonry columns
/// (a ticket is as tall as its items — nothing is cut off).
class KitchenPane extends ConsumerWidget {
  const KitchenPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kitchen = ref.watch(floorProvider.select((s) => s.kitchenByUrgency));
    final greenTill = ref.watch(floorProvider.select((s) => s.floor?.greenTillMinutes ?? kDefaultGreenTillMinutes));
    return RefreshIndicator(
      onRefresh: () => ref.read(floorProvider.notifier).refresh(),
      child: LayoutBuilder(
        builder: (context, box) {
          const pad = 24.0;
          final cols = ((box.maxWidth - 2 * pad + kTicketGap) / (kTicketWidth + kTicketGap)).floor().clamp(1, 12);
          final columns = dealIntoColumns(kitchen, cols);
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(pad, 28, pad, 120), // room for the driver button
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PaneHeader(
                  title: 'Kitchen',
                  subtitle: kitchen.isEmpty ? null : '${kitchen.length} cooking · most urgent first',
                ),
                if (kitchen.isEmpty)
                  SizedBox(
                    height: (box.maxHeight - 200).clamp(200, 2000),
                    child: const EmptyState(
                      icon: Icons.soup_kitchen_outlined,
                      title: 'Nothing cooking',
                      message: 'Accepted orders show here until they are marked ready.',
                    ),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var c = 0; c < columns.length; c++) ...[
                        if (c > 0) const SizedBox(width: kTicketGap),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final so in columns[c])
                                Padding(
                                  padding: const EdgeInsets.only(bottom: kTicketGap),
                                  child: KitchenCard(key: ValueKey(so.id), order: so, greenTill: greenTill),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class KitchenCard extends ConsumerStatefulWidget {
  final StoredOrder order;
  final int greenTill;
  const KitchenCard({super.key, required this.order, this.greenTill = kDefaultGreenTillMinutes});

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
    final arrived = so.status.arrivalDate ?? o.receivedAt ?? so.status.acceptedAt;
    return Ticker(
      interval: const Duration(seconds: 5),
      builder: (context, now) {
        final since = arrived == null ? Duration.zero : now.difference(arrived);
        final tone = lateColor(since, widget.greenTill);
        final surface = context.palette.bgSurface;
        return Container(
          decoration: BoxDecoration(
            color: Color.alphaBlend(tone.withValues(alpha: 0.16), surface),
            borderRadius: BorderRadius.circular(QuiccRadius.md),
            border: Border(left: BorderSide(color: tone, width: 6)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(QuiccRadius.md),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => OrderDetailScreen(orderId: so.id, initial: so)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          so.displayNumber,
                          style: const TextStyle(
                            fontSize: 28,
                            height: 1,
                            fontWeight: FontWeight.w800,
                            color: QuiccColors.brand400,
                          ),
                        ),
                        const Spacer(),
                        FulfillmentTag(o.fulfillment.type, size: 11),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _TimerLine(order: so, since: since, tone: tone, now: now),
                    const SizedBox(height: 6),
                    Text(
                      o.customerName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    ItemLines(o.items, fontSize: 13),
                    if (o.notes.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '“${o.notes.trim()}”',
                        style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: QuiccColors.statusFiring),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(
                          width: 48,
                          height: 44,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 44)),
                            onPressed: _reprinting ? null : _reprint,
                            child: _reprinting
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.print_outlined, size: 20),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: FilledButton.icon(
                              // The theme's big-button padding would clip the
                              // label inside a 44 px ticket button.
                              style: FilledButton.styleFrom(
                                backgroundColor: QuiccColors.statusPaid,
                                foregroundColor: QuiccColors.brand900,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                minimumSize: const Size(0, 44),
                                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1),
                              ),
                              onPressed: _busy ? null : _ready,
                              icon: const Icon(Icons.check_circle_outline, size: 20),
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
          ),
        );
      },
    );
  }
}

/// "12:03 · 7 min left · 4:36 PM" — time since the order arrived (coloured
/// like the ticket), then the promised ready time.
class _TimerLine extends StatelessWidget {
  final StoredOrder order;
  final Duration since;
  final Color tone;
  final DateTime now;
  const _TimerLine({required this.order, required this.since, required this.tone, required this.now});

  @override
  Widget build(BuildContext context) {
    final eta = order.status.estimatedReadyAt;
    final left = eta?.difference(now);
    final late = left != null && left.isNegative;
    return Row(
      children: [
        Text(
          duration(since),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: tone,
          ),
        ),
        if (left != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              late ? 'LATE ${minutes(left)}' : '${minutes(left)} left · ${clock(eta)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: late ? FontWeight.w800 : FontWeight.w500,
                color: late ? QuiccColors.statusVoided : context.palette.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
