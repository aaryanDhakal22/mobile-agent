import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import '../maps/check_address_sheet.dart';
import '../maps/geo_format.dart';
import 'lava_glow.dart';

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
      padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.lg, vertical: QuiccSpace.md),
      decoration: BoxDecoration(
        color: QuiccColors.brand400,
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delivery_dining, color: QuiccColors.brand900),
          QuiccSpace.gapSm,
          Text(
            numbers.join('  '),
            style: QuiccType.number(QuiccType.heading, weight: FontWeight.w700, color: QuiccColors.brand900),
          ),
        ],
      ),
    ),
  );
}

/// Draggable on long-press (a tap stays a tap): [child] dims while it's
/// being dragged. [onDragStarted] lets the screen drop a highlight.
class DeliveryDraggable extends StatelessWidget {
  final DeliveryDrag data;
  final Widget child;
  final VoidCallback? onDragStarted;
  const DeliveryDraggable({super.key, required this.data, required this.child, this.onDragStarted});

  @override
  Widget build(BuildContext context) => LongPressDraggable<DeliveryDrag>(
    data: data,
    onDragStarted: onDragStarted,
    feedback: DragFeedback(numbers: data.numbers),
    childWhenDragging: Opacity(opacity: 0.3, child: child),
    child: child,
  );
}

/// A delivery waiting on the left: kitchen #, customer, address, mi · min,
/// tip, CASH $x / PAID and how long since it was placed (amber near the
/// target, red past it). Cooking ones are greyed with "ready in ~m".
/// [highlight] = a soft pulsing yellow outline (someone asked you to look at
/// it, e.g. the driver button found it near the next run).
class UnassignedRow extends StatelessWidget {
  final StoredOrder order;
  final bool selectMode;
  final bool selected;
  final bool highlight;
  final int targetMinutes;
  final VoidCallback onTap;
  const UnassignedRow({
    super.key,
    required this.order,
    required this.selectMode,
    required this.selected,
    this.highlight = false,
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
    final card = Card(
      margin: EdgeInsets.zero,
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
            padding: const EdgeInsets.fromLTRB(QuiccSpace.md, QuiccSpace.md, QuiccSpace.md, QuiccSpace.md),
            child: Row(
              children: [
                if (selectMode)
                  Padding(
                    padding: const EdgeInsets.only(right: QuiccSpace.xs),
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
                          style: QuiccType.number(QuiccType.heading + 4, weight: FontWeight.w700, color: QuiccColors.brand400),
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
                        style: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
                      ),
                      Text(
                        address == null || address.isEmpty ? 'No address' : address.oneLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: QuiccSpace.sm,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (drive != null)
                            Text(drive, style: QuiccType.text(QuiccType.label, weight: FontWeight.w600)),
                          if (g != null && g.needsCheck)
                            CheckAddressTag(order: order)
                          else if (hint != null)
                            Text(
                              hint,
                              style: QuiccType.text(
                                QuiccType.caption,
                                color: context.palette.textMuted,
                              ).copyWith(fontStyle: FontStyle.italic),
                            ),
                          ...geoTags(g),
                        ],
                      ),
                    ],
                  ),
                ),
                QuiccSpace.gapSm,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      order.isPaid ? 'PAID' : 'CASH ${money(order.cashDueCents)}',
                      style: QuiccType.number(
                        QuiccType.label,
                        weight: FontWeight.w700,
                        color: order.isPaid ? context.palette.textMuted : QuiccColors.statusFiring,
                      ),
                    ),
                    if ((order.status.tipCents ?? o.money.tipCents) > 0)
                      Text(
                        'tip ${money(order.status.tipCents ?? o.money.tipCents)}',
                        style: QuiccType.number(
                          QuiccType.label,
                          weight: FontWeight.w500,
                          color: context.palette.textSecondary,
                        ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: QuiccSpace.sm),
      child: HighlightPulse(active: highlight, child: card),
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
    return Text(text, style: QuiccType.text(QuiccType.label, weight: FontWeight.w600, color: QuiccColors.statusOpen));
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
    final m = now.difference(placed).inMinutes.clamp(0, 1 << 30);
    final color = m >= targetMinutes
        ? QuiccColors.statusVoided
        : (m >= targetMinutes - 10 ? QuiccColors.statusFiring : context.palette.textMuted);
    return Text(
      '${m < 0 ? 0 : m} min',
      style: QuiccType.number(QuiccType.label, weight: FontWeight.w700, color: color),
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
      margin: const EdgeInsets.only(bottom: QuiccSpace.sm),
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
            padding: const EdgeInsets.fromLTRB(QuiccSpace.md, QuiccSpace.xs, 2, QuiccSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (selectMode)
                      Padding(
                        padding: const EdgeInsets.only(right: QuiccSpace.xs),
                        child: Icon(
                          selected ? Icons.check_box : Icons.check_box_outline_blank,
                          size: 20,
                          color: selected ? QuiccColors.brand400 : context.palette.textMuted,
                        ),
                      ),
                    Text(
                      order.displayNumber,
                      style: QuiccType.number(QuiccType.body + 2, weight: FontWeight.w700, color: QuiccColors.brand400),
                    ),
                    if (order.isPos) ...[QuiccSpace.gapSm, const PosTag(size: 9)],
                    QuiccSpace.gapMd,
                    Expanded(
                      child: Text(
                        streetOf(order),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
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
                  spacing: QuiccSpace.sm,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (tip > 0)
                      Text(
                        'tip ${money(tip)}',
                        style: QuiccType.number(QuiccType.caption, weight: FontWeight.w500, color: context.palette.textSecondary),
                      ),
                    if (drive != null)
                      Text(drive, style: QuiccType.text(QuiccType.caption, color: context.palette.textSecondary)),
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
    padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.sm, vertical: 3),
    decoration: BoxDecoration(color: QuiccColors.brand400, borderRadius: BorderRadius.circular(QuiccRadius.sm)),
    child: Text(
      'NEXT',
      style: QuiccType.text(
        QuiccType.caption,
        weight: FontWeight.w700,
        color: QuiccColors.brand900,
      ).copyWith(letterSpacing: 1.2),
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
      margin: const EdgeInsets.only(bottom: QuiccSpace.sm),
      child: Padding(
        padding: const EdgeInsets.all(QuiccSpace.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.delivery_dining, color: QuiccColors.brand400, size: 24),
                      QuiccSpace.gapSm,
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  Ticker(
                    builder: (context, now) {
                      final t = outAt;
                      if (t == null) return const SizedBox.shrink();
                      final d = now.isBefore(t) ? Duration.zero : now.difference(t);
                      return Text(
                        'out ${duration(d)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: QuiccType.number(
                          QuiccType.body,
                          weight: FontWeight.w700,
                          color: d.inMinutes >= 45 ? QuiccColors.statusVoided : context.palette.textSecondary,
                        ),
                      );
                    },
                  ),
                  QuiccSpace.gapSm,
                  if (orders.isEmpty)
                    Text('No orders on this run.', style: QuiccType.text(QuiccType.label, color: context.palette.textMuted))
                  else
                    Wrap(
                      spacing: QuiccSpace.sm,
                      runSpacing: QuiccSpace.sm,
                      children: [
                        for (final o in orders)
                          ActionChip(
                            label: Text(o.displayNumber, style: QuiccType.number(QuiccType.label, weight: FontWeight.w700)),
                            onPressed: () => onOpen(o),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            QuiccSpace.gapMd,
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: QuiccColors.statusPaid,
                  foregroundColor: QuiccColors.brand900,
                  padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.lg),
                ),
                onPressed: (busy || onReturned == null) ? null : onReturned,
                icon: busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.home_outlined),
                label: Text(onReturned == null ? 'Driver removed' : 'I HAVE RETURNED'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
