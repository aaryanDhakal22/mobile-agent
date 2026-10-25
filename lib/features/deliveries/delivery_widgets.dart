import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../maps/check_address_sheet.dart';
import '../maps/geo_format.dart';

/// What a drag on the Deliveries screen carries: the order ids, the driver
/// whose pool they came from (null = the unassigned column) and whether
/// they are AUTO suggestions (yellow — not in any pool yet).
class DeliveryDrag {
  final List<String> ids;
  final String? fromDriver;
  final bool suggestion;
  final List<String> numbers;
  const DeliveryDrag({required this.ids, this.fromDriver, this.suggestion = false, this.numbers = const []});
}

/// "#1104" (kitchen number) — the vendor id for an order without one.
String orderNumber(StoredOrder o) {
  final k = o.status.kitchenNumber ?? o.order.kitchenOrderNumber;
  return k != null ? '#$k' : o.displayNumber;
}

/// "1104 and 1106" style list of numbers.
String numbersList(List<String> n) {
  if (n.isEmpty) return '';
  if (n.length == 1) return n.first;
  return '${n.sublist(0, n.length - 1).join(', ')} and ${n.last}';
}

/// What sits under the finger while dragging: the kitchen numbers.
class DragFeedback extends StatelessWidget {
  final List<String> numbers;
  const DragFeedback({super.key, required this.numbers});

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: QuiccColors.brand400,
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delivery_dining, color: QuiccColors.brand900),
          const SizedBox(width: 8),
          Text(
            numbers.join('  '),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: QuiccColors.brand900),
          ),
        ],
      ),
    ),
  );
}

/// Draggable on long-press (a tap stays a tap): [child] dims while it's
/// being dragged.
class DeliveryDraggable extends StatelessWidget {
  final DeliveryDrag data;
  final Widget child;
  const DeliveryDraggable({super.key, required this.data, required this.child});

  @override
  Widget build(BuildContext context) => LongPressDraggable<DeliveryDrag>(
    data: data,
    feedback: DragFeedback(numbers: data.numbers),
    childWhenDragging: Opacity(opacity: 0.3, child: child),
    child: child,
  );
}

/// A delivery waiting on the left: kitchen #, customer, address, mi · min,
/// tip, CASH $x / PAID and how long since it was placed (amber near the
/// target, red past it). Cooking ones are greyed with "ready in ~m".
class UnassignedRow extends StatelessWidget {
  final StoredOrder order;
  final bool selectMode;
  final bool selected;
  final int targetMinutes;
  final VoidCallback onTap;
  const UnassignedRow({
    super.key,
    required this.order,
    required this.selectMode,
    required this.selected,
    required this.targetMinutes,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final o = order.order;
    final g = order.geo;
    final cooking = order.state != OrderState.ready;
    final drive = driveLabel(g);
    final hint = drive == null ? geoHint(g) : null;
    final address = o.fulfillment.address;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? QuiccColors.brand400.withValues(alpha: 0.14) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        side: BorderSide(color: selected ? QuiccColors.brand400 : Colors.transparent, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        onTap: onTap,
        child: Opacity(
          opacity: cooking ? 0.55 : 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
            child: Row(
              children: [
                if (selectMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      selected ? Icons.check_box : Icons.check_box_outline_blank,
                      color: selected ? QuiccColors.brand400 : context.palette.textMuted,
                    ),
                  ),
                SizedBox(
                  width: 70,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          order.displayNumber,
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: QuiccColors.brand400),
                        ),
                      ),
                      if (order.isPos) const PosTag(size: 10),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        o.customerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        address == null || address.isEmpty ? 'No address' : address.oneLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: context.palette.textSecondary),
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 6,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (drive != null)
                            Text(drive, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                          if (g != null && g.needsCheck)
                            CheckAddressTag(order: order)
                          else if (hint != null)
                            Text(
                              hint,
                              style: TextStyle(
                                color: context.palette.textMuted,
                                fontStyle: FontStyle.italic,
                                fontSize: 13,
                              ),
                            ),
                          ...geoTags(g),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      order.isPaid ? 'PAID' : 'CASH ${money(order.cashDueCents)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: order.isPaid ? context.palette.textMuted : QuiccColors.statusFiring,
                      ),
                    ),
                    if ((order.status.tipCents ?? o.money.tipCents) > 0)
                      Text(
                        'tip ${money(order.status.tipCents ?? o.money.tipCents)}',
                        style: TextStyle(color: context.palette.textSecondary),
                      ),
                    Ticker(
                      interval: const Duration(seconds: 15),
                      builder: (context, now) => cooking
                          ? _ReadyIn(order: order, now: now)
                          : _Age(order: order, now: now, targetMinutes: targetMinutes),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "ready in ~4 min" for a cooking delivery.
class _ReadyIn extends StatelessWidget {
  final StoredOrder order;
  final DateTime now;
  const _ReadyIn({required this.order, required this.now});

  @override
  Widget build(BuildContext context) {
    final eta = order.status.estimatedReadyAt;
    final left = eta?.difference(now);
    final text = left == null
        ? 'cooking'
        : (left.inSeconds <= 30 ? 'ready any minute' : 'ready in ~${(left.inSeconds / 60).ceil()} min');
    return Text(text, style: const TextStyle(color: QuiccColors.statusOpen, fontWeight: FontWeight.w600));
  }
}

/// Minutes since the customer placed it, against the delivery target.
class _Age extends StatelessWidget {
  final StoredOrder order;
  final DateTime now;
  final int targetMinutes;
  const _Age({required this.order, required this.now, required this.targetMinutes});

  @override
  Widget build(BuildContext context) {
    final placed = order.placedTime;
    if (placed == null) return const SizedBox.shrink();
    final m = now.difference(placed).inMinutes;
    final color = m >= targetMinutes
        ? QuiccColors.statusVoided
        : (m >= targetMinutes - 10 ? QuiccColors.statusFiring : context.palette.textMuted);
    return Text(
      '${m < 0 ? 0 : m} min',
      style: TextStyle(color: color, fontWeight: FontWeight.w700),
    );
  }
}

/// One stop in a driver's box: kitchen #, street, ✕ on the first line; tip,
/// mi · min and tags under it. [yellow] = an AUTO suggestion (amber glowing
/// border, text unchanged).
class PoolStopChip extends StatelessWidget {
  final StoredOrder order;
  final bool yellow;
  final bool selectMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  const PoolStopChip({
    super.key,
    required this.order,
    this.yellow = false,
    required this.selectMode,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final g = order.geo;
    final drive = driveLabel(g) ?? geoHint(g);
    final tip = order.order.money.tipCents;
    final cooking = order.state != OrderState.ready;
    final border = selected
        ? QuiccColors.brand400
        : (yellow ? QuiccColors.statusFiring : context.palette.borderSoft);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: selected ? QuiccColors.brand400.withValues(alpha: 0.14) : context.palette.bgElevated,
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        border: Border.all(color: border, width: yellow || selected ? 2 : 1),
        boxShadow: yellow
            ? [BoxShadow(color: QuiccColors.statusFiring.withValues(alpha: 0.55), blurRadius: 10, spreadRadius: 1)]
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (selectMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          selected ? Icons.check_box : Icons.check_box_outline_blank,
                          size: 20,
                          color: selected ? QuiccColors.brand400 : context.palette.textMuted,
                        ),
                      ),
                    Text(
                      order.displayNumber,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: QuiccColors.brand400),
                    ),
                    if (order.isPos) ...[const SizedBox(width: 6), const PosTag(size: 9)],
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        streetOf(order),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      height: 32,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 20,
                        tooltip: yellow ? 'Drop this suggestion' : 'Back to unassigned',
                        icon: Icon(Icons.close, color: context.palette.textMuted),
                        onPressed: onRemove,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (tip > 0)
                      Text('tip ${money(tip)}', style: TextStyle(color: context.palette.textSecondary, fontSize: 13)),
                    if (drive != null)
                      Text(drive, style: TextStyle(color: context.palette.textSecondary, fontSize: 13)),
                    if (cooking) const GeoTag('cooking', color: QuiccColors.statusOpen),
                    ...geoTags(g),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Slides an AUTO suggestion in from the left (once per preview) — a cheap
/// translate + fade, smooth on a low-end tablet.
class SlideIn extends StatelessWidget {
  final int index;
  final Widget child;
  const SlideIn({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Duration(milliseconds: 380 + 70 * (index > 6 ? 6 : index)),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(-140 * (1 - t), 0), child: child),
    ),
    child: child,
  );
}

/// "NEXT" on the first available driver's box.
class NextBadge extends StatelessWidget {
  const NextBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: QuiccColors.brand400, borderRadius: BorderRadius.circular(QuiccRadius.sm)),
    child: const Text(
      'NEXT',
      style: TextStyle(color: QuiccColors.brand900, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1.2),
    ),
  );
}

/// A driver out on a run: name, time out, their kitchen numbers (tap = the
/// order) and I HAVE RETURNED.
class OutRunCard extends StatelessWidget {
  final String name;
  final DateTime? outAt;
  final List<StoredOrder> orders;
  final bool busy;
  final VoidCallback? onReturned;
  final void Function(StoredOrder) onOpen;
  const OutRunCard({
    super.key,
    required this.name,
    required this.outAt,
    required this.orders,
    required this.busy,
    required this.onReturned,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.delivery_dining, color: QuiccColors.brand400, size: 24),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  Ticker(
                    builder: (context, now) {
                      final t = outAt;
                      if (t == null) return const SizedBox.shrink();
                      final d = now.difference(t);
                      return Text(
                        'out ${duration(d)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: d.inMinutes >= 45 ? QuiccColors.statusVoided : context.palette.textSecondary,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  if (orders.isEmpty)
                    Text('No orders on this run.', style: TextStyle(color: context.palette.textMuted))
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final o in orders)
                          ActionChip(
                            label: Text(o.displayNumber, style: const TextStyle(fontWeight: FontWeight.w700)),
                            onPressed: () => onOpen(o),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: QuiccColors.statusPaid,
                  foregroundColor: QuiccColors.brand900,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                onPressed: (busy || onReturned == null) ? null : onReturned,
                icon: busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.home_outlined),
                label: Text(onReturned == null ? 'DRIVER REMOVED' : 'I HAVE RETURNED'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
