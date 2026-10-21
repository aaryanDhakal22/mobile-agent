import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../arrived/accept_controls.dart';
import '../common/widgets.dart';

/// Full order: items (size / modifiers / notes), customer, address, kitchen
/// number, and the floor timeline. Follows live updates for orders in the
/// working set; [initial] covers orders from past batches.
class OrderDetailScreen extends ConsumerWidget {
  final String orderId;
  final StoredOrder initial;
  const OrderDetailScreen({super.key, required this.orderId, required this.initial});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(floorProvider.select((s) => s.orders[orderId]));
    final so = live ?? initial;
    final o = so.order;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: context.palette.bgSurface,
        toolbarHeight: 72,
        title: Row(
          children: [
            Text(
              so.displayNumber,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: QuiccColors.brand400),
            ),
            const SizedBox(width: 16),
            StatePill(so.state, large: true),
            const SizedBox(width: 16),
            FulfillmentTag(o.fulfillment.type, size: 15),
          ],
        ),
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 6,
            child: ListView(
              padding: const EdgeInsets.all(28),
              children: [
                const Eyebrow('Items'),
                const SizedBox(height: 10),
                for (final item in o.items) _ItemBlock(item),
                if (o.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Eyebrow('Order notes'),
                  const SizedBox(height: 6),
                  Text(
                    o.notes.trim(),
                    style: const TextStyle(fontSize: 17, color: QuiccColors.statusFiring, fontWeight: FontWeight.w600),
                  ),
                ],
                const SizedBox(height: 20),
                const Divider(),
                _Totals(o),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 4,
            child: ListView(
              padding: const EdgeInsets.all(28),
              children: [
                _Actions(order: so),
                const SizedBox(height: 24),
                const Eyebrow('Customer'),
                const SizedBox(height: 6),
                Text(o.customerName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                if (o.customer.phone.isNotEmpty) Text(o.customer.phone, style: const TextStyle(fontSize: 16)),
                if (o.customer.email.isNotEmpty)
                  Text(o.customer.email, style: TextStyle(color: context.palette.textSecondary)),
                if (o.fulfillment.address != null && !o.fulfillment.address!.isEmpty) ...[
                  const SizedBox(height: 18),
                  const Eyebrow('Delivery address'),
                  const SizedBox(height: 6),
                  for (final l in o.fulfillment.address!.lines) Text(l, style: const TextStyle(fontSize: 16)),
                  if (o.fulfillment.address!.notes.isNotEmpty)
                    Text(
                      o.fulfillment.address!.notes,
                      style: const TextStyle(color: QuiccColors.statusFiring, fontStyle: FontStyle.italic),
                    ),
                ],
                if (o.fulfillment.tableId.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const Eyebrow('Table'),
                  Text(o.fulfillment.tableId, style: const TextStyle(fontSize: 18)),
                ],
                const SizedBox(height: 18),
                const Eyebrow('Floor'),
                const SizedBox(height: 6),
                _kv(context, 'Kitchen #', so.status.kitchenNumber?.toString() ?? '—'),
                _kv(context, 'Prep', so.status.prepMinutes == null ? '—' : '${so.status.prepMinutes} min'),
                _kv(context, 'Batch', so.status.batchId == 0 ? '—' : '#${so.status.batchId}'),
                if (so.status.driverName != null) _kv(context, 'Driver', so.status.driverName!),
                if (o.sourceEventId.isNotEmpty) _kv(context, 'Vendor #', o.sourceEventId),
                const SizedBox(height: 18),
                const Eyebrow('Timeline'),
                const SizedBox(height: 6),
                ..._timeline(context, so),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _kv(BuildContext context, String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(k, style: TextStyle(color: context.palette.textMuted)),
        ),
        Expanded(child: Text(v, style: const TextStyle(fontSize: 16))),
      ],
    ),
  );

  static List<Widget> _timeline(BuildContext context, StoredOrder so) {
    final st = so.status;
    final rows = <(String, DateTime?)>[
      ('Placed', so.order.placedAt),
      ('Arrived', st.arrivalDate),
      ('Accepted', st.acceptedAt),
      ('Printed', st.printedDate),
      ('Est. ready', st.estimatedReadyAt),
      ('Ready', st.readyAt),
      ('Out', st.outAt),
      ('Delivered', st.deliveredAt),
      ('Cancelled', st.cancelledAt),
    ];
    return [
      for (final (label, t) in rows)
        if (t != null) _kv(context, label, dateClock(t)),
    ];
  }
}

class _ItemBlock extends StatelessWidget {
  final LineItem item;
  const _ItemBlock(this.item);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  '${item.quantity}×',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: QuiccColors.brand400),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    if (item.size.isNotEmpty)
                      Text(item.size, style: TextStyle(color: context.palette.textSecondary, fontSize: 15)),
                  ],
                ),
              ),
              Text(money(item.lineTotalCents), style: const TextStyle(fontSize: 16)),
            ],
          ),
          for (final c in item.children)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '+ ${itemTitle(c)}${c.notes.isNotEmpty ? '  (${c.notes})' : ''}',
                      style: TextStyle(color: context.palette.textSecondary, fontSize: 15),
                    ),
                  ),
                  if (c.lineTotalCents != 0)
                    Text(money(c.lineTotalCents), style: TextStyle(color: context.palette.textMuted)),
                ],
              ),
            ),
          if (item.notes.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 4),
              child: Text(
                '“${item.notes.trim()}”',
                style: const TextStyle(color: QuiccColors.statusFiring, fontStyle: FontStyle.italic, fontSize: 15),
              ),
            ),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  final OrderSnapshot o;
  const _Totals(this.o);

  @override
  Widget build(BuildContext context) {
    final m = o.money;
    Widget row(String k, int cents, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              k,
              style: TextStyle(
                fontSize: bold ? 20 : 15,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                color: bold ? null : context.palette.textSecondary,
              ),
            ),
          ),
          Text(
            money(cents),
            style: TextStyle(fontSize: bold ? 20 : 15, fontWeight: bold ? FontWeight.w700 : FontWeight.w400),
          ),
        ],
      ),
    );
    return Column(
      children: [
        row('Subtotal', m.subtotalCents),
        for (final f in m.fees) row(f.label.isNotEmpty ? f.label : f.type, f.amountCents),
        for (final d in m.discounts)
          row(d.label.isNotEmpty ? d.label : (d.code.isNotEmpty ? d.code : 'Discount'), -d.amountCents),
        row('Tax', m.taxCents),
        if (m.tipCents != 0) row('Tip', m.tipCents),
        row('Total', m.totalCents, bold: true),
        const SizedBox(height: 8),
        for (final p in o.payments)
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Paid ${money(p.amountCents)} · ${p.method}${p.last4.isNotEmpty ? ' ••${p.last4}' : ''}',
              style: TextStyle(color: context.palette.textMuted),
            ),
          ),
        if (o.payments.isEmpty)
          const Align(
            alignment: Alignment.centerRight,
            child: Text(
              'NOT PAID',
              style: TextStyle(color: QuiccColors.statusFiring, fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

/// State-dependent actions: accept (arrived), ready (accepted), reprint.
class _Actions extends ConsumerStatefulWidget {
  final StoredOrder order;
  const _Actions({required this.order});

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  bool _busy = false;

  Future<void> _do(Future<void> Function() op, String ok, String fail) async {
    setState(() => _busy = true);
    try {
      await op();
      if (mounted) toast(context, ok);
    } catch (e) {
      if (mounted) toastError(context, e, lead: fail, area: 'order');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final so = widget.order;
    final floor = ref.read(floorProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (so.state == OrderState.arrived) AcceptControls(key: ValueKey('accept-${so.id}'), order: so),
        if (so.state == OrderState.accepted)
          SizedBox(
            height: 60,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: QuiccColors.statusPaid,
                foregroundColor: QuiccColors.brand900,
              ),
              onPressed: _busy ? null : () => _do(() => floor.ready(so.id), 'Marked ready', 'Not marked ready'),
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('READY'),
            ),
          ),
        if (so.state != OrderState.arrived) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 56,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _do(() => floor.reprint(so.id), 'Reprinted', 'Not reprinted'),
              icon: const Icon(Icons.print_outlined),
              label: const Text('REPRINT'),
            ),
          ),
        ],
      ],
    );
  }
}
