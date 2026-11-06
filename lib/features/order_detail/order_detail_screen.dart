import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_nav.dart';
import '../kitchen/ready_button.dart';
import '../common/island.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';
import '../arrived/accept_controls.dart';
import '../arrived/time_picker.dart';
import '../common/widgets.dart';
import '../kitchen/resend_kitchen.dart';
import '../maps/check_address_sheet.dart';
import '../maps/delivery_map.dart';
import 'future_actions.dart';
import 'not_delivered.dart';

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
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: QuiccColors.brand400),
            ),
            if (so.isPos) ...[const SizedBox(width: 10), const PosTag(size: 14)],
            const SizedBox(width: 16),
            StatePill(so.state, large: true),
            if (so.status.paid) ...[const SizedBox(width: 12), const PaidBadge(size: 14)],
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
                for (final r in o.removedItems)
                  Padding(padding: const EdgeInsets.only(bottom: 10), child: RemovedLine(r, fontSize: 18)),
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
                _Totals(so),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 4,
            child: ListView(
              padding: const EdgeInsets.all(28),
              children: [
                if (so.status.flag != null) ...[
                  OrderFlagLine(so.status.flag!, fontSize: 16),
                  const SizedBox(height: 14),
                ],
                if (so.status.posDriverNote != null) ...[
                  Row(
                    key: const ValueKey('pos-driver-note'),
                    children: [
                      const Icon(Icons.badge_outlined, color: QuiccColors.statusFiring),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          so.status.posDriverNote!,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                ],
                _Actions(order: so),
                const SizedBox(height: 24),
                const Eyebrow('Customer'),
                const SizedBox(height: 6),
                Text(o.customerName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                if (o.customer.phone.isNotEmpty) Text(o.customer.phone, style: const TextStyle(fontSize: 16)),
                if (o.customer.email.isNotEmpty)
                  Text(o.customer.email, style: TextStyle(color: context.palette.textSecondary)),
                if (so.isDelivery && so.geo?.needsCheck == true) ...[
                  const SizedBox(height: 18),
                  CheckAddressButton(order: so),
                ],
                if (so.isDelivery && o.fulfillment.address != null && !o.fulfillment.address!.isEmpty) ...[
                  const SizedBox(height: 18),
                  DeliveryMap(key: ValueKey('map-${so.id}'), order: so),
                ],
                if (o.fulfillment.address != null && !o.fulfillment.address!.isEmpty) ...[
                  const SizedBox(height: 18),
                  const Eyebrow('Delivery address'),
                  const SizedBox(height: 6),
                  for (final l in o.fulfillment.address!.lines) Text(l, style: const TextStyle(fontSize: 16)),
                  if (so.geo?.confirmedAddress != null && !so.geo!.confirmedAddress!.isEmpty)
                    Text(
                      'Confirmed: ${so.geo!.confirmedAddress!.oneLine}',
                      style: const TextStyle(color: QuiccColors.statusPaid, fontWeight: FontWeight.w600),
                    ),
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
                if (so.isPos)
                  _kv(context, 'POS check #', so.status.displayNumber?.toString() ?? '—')
                else
                  _kv(context, 'Kitchen #', so.status.kitchenNumber?.toString() ?? '—'),
                if (so.status.posCheckNumber != null) _kv(context, 'POS check #', '${so.status.posCheckNumber}'),
                _kv(context, 'Prep', so.status.prepMinutes == null ? '—' : '${so.status.prepMinutes} min'),
                _kv(context, 'Batch', so.status.batchId == 0 ? '—' : '#${so.status.batchId}'),
                // A cancelled order has no driver (1.7.1: NOT DELIVERED → CANCEL).
                if (so.status.driverName != null && so.state != OrderState.cancelled)
                  _kv(context, 'Driver', so.status.driverName!),
                if (so.status.scheduledLeadMinutes != null)
                  _kv(context, 'Lead', '${so.status.scheduledLeadMinutes} min before due'),
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
      ('Sent (POS)', st.sentAt),
      ('Arrived', st.arrivalDate),
      if (st.future || st.scheduledLeadMinutes != null) ('Due', so.dueAt),
      ('Rings again', st.ringAt),
      ('Accepted', st.acceptedAt),
      ('Printed', st.printedDate),
      ('Est. ready', st.estimatedReadyAt),
      ('Ready', st.readyAt),
      ('Out', st.outAt),
      ('Delivered', st.deliveredAt),
      ('Came back', st.notDelivered?.at),
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
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: QuiccColors.brand400),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.name,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: item.added ? QuiccColors.changeBlue : null,
                            ),
                          ),
                        ),
                        if (item.added) ...[
                          const SizedBox(width: 8),
                          const Text(
                            'ADDED',
                            key: ValueKey('detail-added'),
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: QuiccColors.changeBlue),
                          ),
                        ],
                      ],
                    ),
                    if (item.displaySize.isNotEmpty)
                      Text(item.displaySize, style: TextStyle(color: context.palette.textSecondary, fontSize: 15)),
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
  final StoredOrder so;
  const _Totals(this.so);

  @override
  Widget build(BuildContext context) {
    final o = so.order;
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
        // A cash payment is money still to collect, not money paid.
        for (final p in o.payments.where((p) => !p.isCash))
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Paid ${money(p.amountCents)} · ${p.method}${p.last4.isNotEmpty ? ' ••${p.last4}' : ''}',
              style: TextStyle(color: context.palette.textMuted),
            ),
          ),
        if (so.status.paid)
          const Align(alignment: Alignment.centerRight, child: PaidBadge(size: 14))
        else if (!so.isPaid)
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'CASH DUE ${money(so.cashDueCents)}',
              style: const TextStyle(color: QuiccColors.statusFiring, fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

/// State-dependent actions: accept (arrived), ready (accepted), reprint the
/// receipt, and resend to the kitchen (once it has a kitchen number).
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

  /// READY (2.0.0): instant, with the "#232 ready · UNDO" pill; the details
  /// close and Kitchen shows (owner: READY from the details goes back to
  /// Kitchen, where the ticket implodes). [callout] false = held.
  void _ready(StoredOrder so, bool callout) {
    readyNow(Island.maybeOf(context), ref.read(floorProvider.notifier), so, callout: callout);
    ref.read(homeNavProvider.notifier).go(HomeDestination.kitchen);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// MARK DELIVERED (2.0.0): no dialog — it goes to Unassigned on the
  /// Drivers tab at once, with an UNDO in the pill; 2.0.5: the details close.
  Future<void> _markDelivered(StoredOrder so) async {
    final island = Island.maybeOf(context);
    final floor = ref.read(floorProvider.notifier);
    final n = so.displayNumber.startsWith('#') ? so.displayNumber : '#${so.displayNumber}';
    setState(() => _busy = true);
    try {
      await floor.markDelivered(so.id);
      // 2.0.5 (owner): done here — back to where it was opened from, like READY.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      island?.show(
        '$n delivered · Unassigned',
        kind: IslandKind.success,
        duration: const Duration(seconds: 10),
        actions: [
          IslandAction('UNDO', () async {
            try {
              await floor.undeliver(so.id);
              island.show('$n back on Deliveries', kind: IslandKind.info);
            } catch (_) {
              island.show("Couldn't undo — $n stays delivered (Drivers → Unassigned)", kind: IslandKind.error);
            }
          }),
        ],
      );
    } catch (e) {
      if (mounted) toastError(context, e, lead: 'Not marked delivered', area: 'order');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final so = widget.order;
    final floor = ref.read(floorProvider.notifier);
    final batchId = ref.watch(floorProvider.select((s) => s.currentBatchId));
    final notDelivered = canMarkNotDelivered(so, batchId) && !ref.watch(notDeliveredUnsupportedProvider);
    final unassignedOff = ref.watch(unassignedUnsupportedProvider);
    final markDelivered = so.canMarkDelivered && batchId != null && so.status.batchId == batchId && !unassignedOff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (so.isCameBack) const _CameBackNote(),
        if (so.state == OrderState.arrived) AcceptControls(key: ValueKey('accept-${so.id}'), order: so),
        if (so.state == OrderState.scheduled) _LaterPanel(order: so),
        // 2.0.5: a future order still ringing can be made now / moved /
        // printed / cancelled from here too.
        if (so.state == OrderState.arrived && so.status.future) ...[
          const SizedBox(height: 12),
          _LaterPanel(order: so),
        ],
        if (so.state == OrderState.accepted) ReadyButton(enabled: !_busy, onReady: (callout) => _ready(so, callout)),
        if (so.state != OrderState.arrived && so.state != OrderState.scheduled) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: Tooltip(
                    message: kReprintReceiptLabel,
                    child: OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _do(() => floor.reprint(so.id), 'Receipt reprinted', 'Receipt not reprinted'),
                      icon: const Icon(Icons.print_outlined),
                      label: const _OneLine('REPRINT RECEIPT'),
                    ),
                  ),
                ),
              ),
              if (canResendToKitchen(so)) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: Tooltip(
                      message: kResendKitchenLabel,
                      child: OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => resendToKitchen(
                                context,
                                ref,
                                so,
                                area: 'order',
                                onBusy: (b) {
                                  if (mounted) setState(() => _busy = b);
                                },
                              ),
                        icon: const Icon(Icons.send_outlined),
                        label: const _OneLine('RESEND TO KITCHEN'),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
        // 2.0.0 (Pi 2.4.0): delivered with no driver, and back.
        if (markDelivered) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 56,
            child: OutlinedButton.icon(
              key: const ValueKey('mark-delivered'),
              onPressed: _busy ? null : () => _markDelivered(so),
              icon: const Icon(Icons.where_to_vote_outlined),
              label: const _OneLine('MARK DELIVERED'),
            ),
          ),
        ],
        if (so.isUnassigned && !unassignedOff) ...[
          const SizedBox(height: 10),
          const _UnassignedNote(),
          const SizedBox(height: 10),
          SizedBox(
            height: 56,
            child: OutlinedButton.icon(
              key: const ValueKey('back-to-deliveries'),
              onPressed: _busy ? null : () => _do(() => floor.undeliver(so.id), 'Back on Deliveries', 'Not moved back'),
              icon: const Icon(Icons.undo),
              label: const _OneLine('BACK TO DELIVERIES'),
            ),
          ),
        ],
        if (notDelivered) ...[
          const SizedBox(height: 10),
          NotDeliveredButton(
            order: so,
            busy: _busy,
            onBusy: (b) {
              if (mounted) setState(() => _busy = b);
            },
          ),
        ],
      ],
    );
  }
}

/// Delivered with no driver (2.0.0): where it waits.
class _UnassignedNote extends StatelessWidget {
  const _UnassignedNote();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('unassigned-note'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: QuiccColors.statusFiring.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(QuiccRadius.md),
      border: Border.all(color: QuiccColors.statusFiring.withValues(alpha: 0.6)),
    ),
    child: const Row(
      children: [
        Icon(Icons.person_off_outlined, color: QuiccColors.statusFiring),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Delivered with no driver. It waits on Drivers → Unassigned: select it there and tap the driver who took it.',
          ),
        ),
      ],
    ),
  );
}

/// A delivery that came back (1.7.1): where it is and how it goes out again.
class _CameBackNote extends StatelessWidget {
  const _CameBackNote();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('came-back-note'),
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: QuiccColors.statusFiring.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(QuiccRadius.md),
      border: Border.all(color: QuiccColors.statusFiring.withValues(alpha: 0.6)),
    ),
    child: const Row(
      children: [
        Icon(Icons.assignment_return_outlined, color: QuiccColors.statusFiring),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Came back with the driver. It waits on Deliveries under Came back — press and hold it there to send it to Waiting.',
          ),
        ),
      ],
    ),
  );
}

/// A waiting future order: when it is due, when it rings again, and its
/// actions (2.0.5, Pi 2.4.3) — MAKE NOW, CHANGE DUE TIME, PRINT NOW, CHANGE
/// LEAD TIME and CANCEL ORDER. An older Pi has only CHANGE LEAD TIME.
class _LaterPanel extends ConsumerStatefulWidget {
  final StoredOrder order;
  const _LaterPanel({required this.order});

  @override
  ConsumerState<_LaterPanel> createState() => _LaterPanelState();
}

class _LaterPanelState extends ConsumerState<_LaterPanel> {
  String? _busy;

  Future<void> _run(String what, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() => _busy = what);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _error(Object e, String lead) {
    if (!mounted) return;
    if (e is AgentException && e.code == kFutureActionsUnsupported) {
      toast(context, 'This Pi needs an update for that.', error: true);
      return;
    }
    toastError(context, e, lead: lead, area: 'order');
  }

  Future<void> _makeNow(StoredOrder so) async {
    final fs = ref.read(floorProvider);
    final due = so.dueAt;
    final minutes = await showMakeNowDialog(
      context,
      base: defaultMinutesFor(so, fs.settings.times),
      subtitle: due == null ? null : 'Due ${dayClock(due)}',
    );
    if (minutes == null || !mounted) return;
    final island = Island.maybeOf(context);
    await _run('make', () async {
      try {
        final o = await ref.read(floorProvider.notifier).makeNow(so.id, minutes);
        island?.show('${o.displayNumber} is cooking · $minutes min', kind: IslandKind.success);
        if (mounted) {
          ref.read(homeNavProvider.notifier).go(HomeDestination.kitchen);
          Navigator.of(context).popUntil((r) => r.isFirst);
        }
      } catch (e) {
        _error(e, 'Not made now');
      }
    });
  }

  Future<void> _changeDue(StoredOrder so) async {
    final next = await showDuePicker(
      context,
      current: so.dueAt ?? timeNow(),
      leadMinutes: so.status.scheduledLeadMinutes,
    );
    if (next == null || !mounted) return;
    await _run('due', () async {
      try {
        await ref.read(floorProvider.notifier).changeDue(so.id, next);
        if (mounted) toast(context, 'Due ${dayClock(next)}');
      } catch (e) {
        _error(e, 'Due time not changed');
      }
    });
  }

  Future<void> _printNow(StoredOrder so) async {
    final what = await showPrintNowDialog(context);
    if (what == null || !mounted) return;
    await _run('print', () async {
      try {
        final r = await ref
            .read(floorProvider.notifier)
            .printNow(so.id, kitchen: what.withKitchen, receipt: what.withReceipt);
        if (!mounted) return;
        final where = r.printed.isEmpty ? '' : ' — ${r.printed.join(', ')}';
        toast(
          context,
          '${what.label} printed$where${r.failed.isEmpty ? '' : '. Not printed: ${r.failed.join(', ')}'}',
          error: r.failed.isNotEmpty && r.printed.isEmpty,
        );
      } catch (e) {
        _error(e, 'Nothing printed');
      }
    });
  }

  Future<void> _cancel(StoredOrder so) async {
    if (!await confirmCancelFuture(context, so) || !mounted) return;
    final island = Island.maybeOf(context);
    await _run('cancel', () async {
      try {
        await ref.read(floorProvider.notifier).cancelFuture(so.id);
        island?.show('${so.displayNumber} cancelled', kind: IslandKind.info);
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      } catch (e) {
        _error(e, 'Not cancelled');
      }
    });
  }

  Future<void> _changeLead(StoredOrder so) async {
    final fs = ref.read(floorProvider);
    final due = so.dueAt;
    final lead = so.status.scheduledLeadMinutes;
    final next = await showLeadTimeDialog(
      context,
      base: futureLeadFor(so, fs.settings.times, fs.floor?.deliveryTargetMinutes ?? 0),
      current: lead,
      subtitle: due == null ? null : 'Due ${dayClock(due)}',
    );
    if (next == null || next == lead || !mounted) return;
    try {
      await ref.read(floorProvider.notifier).schedule(so.id, next);
      if (mounted) toast(context, 'Lead time $next min');
    } catch (e) {
      if (mounted) toastError(context, e, lead: 'Lead time not changed', area: 'order');
    }
  }

  Widget _button(String key, String label, IconData icon, VoidCallback onPressed, {bool filled = false, Color? color}) {
    final busy = _busy == key;
    final child = busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3))
        : Icon(icon);
    final text = _OneLine(label);
    return SizedBox(
      height: 56,
      child: filled
          ? FilledButton.icon(
              key: ValueKey('future-$key'),
              onPressed: _busy == null ? onPressed : null,
              icon: child,
              label: text,
            )
          : OutlinedButton.icon(
              key: ValueKey('future-$key'),
              style: color == null
                  ? null
                  : OutlinedButton.styleFrom(
                      foregroundColor: color,
                      side: BorderSide(color: color, width: 1.5),
                    ),
              onPressed: _busy == null ? onPressed : null,
              icon: child,
              label: text,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final so = widget.order;
    final due = so.dueAt;
    final lead = so.status.scheduledLeadMinutes;
    final ring = so.state != OrderState.scheduled
        ? null
        : so.status.ringAt ?? (due != null && lead != null ? due.subtract(Duration(minutes: lead)) : null);
    final actionsOff = ref.watch(futureActionsUnsupportedProvider);
    final moved = so.status.dueMovedFrom;
    return Container(
      key: const ValueKey('later-panel'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.palette.bgElevated,
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        border: Border.all(color: context.palette.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Later order'),
          const SizedBox(height: 6),
          Text(
            due == null ? 'Waiting for its time' : 'Due ${dayClock(due)}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          if (moved != null)
            Text(
              'Moved here — the customer asked for ${dayClock(moved)}.',
              key: const ValueKey('due-moved'),
              style: TextStyle(color: context.palette.textSecondary),
            ),
          if (ring != null)
            Text(
              'Rings again at ${clock(ring)}${lead == null ? '' : ' ($lead min before)'}. '
              '${so.status.earlyKitchen || so.status.earlyReceipt ? 'The early ${[if (so.status.earlyKitchen) 'kitchen tickets', if (so.status.earlyReceipt) 'receipt'].join(' and ')} printed; the kitchen tickets print again then.' : 'Nothing has printed yet.'}',
              style: TextStyle(color: context.palette.textSecondary),
            ),
          const SizedBox(height: 12),
          if (!actionsOff) ...[
            _button('make-now', 'MAKE NOW', Icons.local_fire_department, () => _makeNow(so), filled: true),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _button('due', 'CHANGE DUE TIME', Icons.event, () => _changeDue(so))),
                const SizedBox(width: 10),
                Expanded(child: _button('print', 'PRINT NOW', Icons.print_outlined, () => _printNow(so))),
              ],
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              if (so.state == OrderState.scheduled)
                Expanded(child: _button('lead', 'CHANGE LEAD TIME', Icons.schedule, () => _changeLead(so))),
              if (so.state == OrderState.scheduled && !actionsOff) const SizedBox(width: 10),
              if (!actionsOff)
                Expanded(
                  child: _button(
                    'cancel',
                    'CANCEL ORDER',
                    Icons.cancel_outlined,
                    () => _cancel(so),
                    color: QuiccColors.statusVoided,
                  ),
                ),
            ],
          ),
          if (actionsOff) ...[
            const SizedBox(height: 8),
            Text(
              'This Pi needs an update to make it now, move it, print it or cancel it.',
              style: TextStyle(color: context.palette.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// A button label that shrinks instead of wrapping on a narrow screen.
class _OneLine extends StatelessWidget {
  final String text;
  const _OneLine(this.text);

  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1));
}
