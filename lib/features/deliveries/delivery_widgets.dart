import 'package:flutter/material.dart';

import '../../core/clock.dart';
import '../../core/delivery_models.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import '../maps/check_address_sheet.dart';
import '../maps/geo_format.dart';
import 'lava_glow.dart';

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

/// A delivery waiting on the left: kitchen #, customer, address, mi · min,
/// tip, CASH $x / PAID and how long since it was placed (amber near the
/// target, red past it). Cooking ones are greyed with "ready in ~m".
/// [highlight] = a soft pulsing yellow outline (someone asked you to look at
/// it, e.g. the driver button found it near the next run). [heldFor] (2.2.1)
/// = AUTO kept it for a driver on his way back: "Held for Abdul · ~6 min".
class UnassignedRow extends StatelessWidget {
  final StoredOrder order;
  final bool selectMode;
  final bool selected;
  final bool highlight;
  final int targetMinutes;
  final HeldFor? heldFor;

  /// Tap = select it (2.0.0); hold = open its details.
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const UnassignedRow({
    super.key,
    required this.order,
    required this.selectMode,
    required this.selected,
    this.highlight = false,
    required this.targetMinutes,
    this.heldFor,
    required this.onTap,
    this.onLongPress,
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
      // 2.0.1: raised off the column (lighter fill, an edge and a shadow)
      // so the rows don't blend together.
      color: selected ? QuiccColors.brand400.withValues(alpha: 0.14) : context.palette.bgElevated,
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.5 : 0.15),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        side: BorderSide(
          color: selected ? QuiccColors.brand400 : QuiccColors.brand400.withValues(alpha: 0.35),
          width: selected ? 2 : 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        onTap: onTap,
        onLongPress: onLongPress,
        child: ClockBuilder<bool>(
          // 2.0.0: a delivery whose time is up counts as ready even if
          // nobody pressed READY — it isn't dimmed any more.
          select: (now) => cooking && !order.timeUp(now),
          builder: (context, dim, _) => Opacity(
            opacity: dim ? 0.55 : 1,
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
                            style: QuiccType.number(
                              QuiccType.heading + 4,
                              weight: FontWeight.w700,
                              color: QuiccColors.brand400,
                            ),
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
                        // 2.0.1: the address leads (big), the name is small under it.
                        Text(
                          address == null || address.isEmpty ? 'No address' : address.oneLine,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700),
                        ),
                        Text(
                          o.customerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: QuiccType.text(QuiccType.label - 1, color: context.palette.textSecondary),
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
                            if (heldFor != null) HeldForTag(heldFor: heldFor!, key: ValueKey('held-${order.id}')),
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
                      cooking ? _ReadyIn(order: order) : _Age(order: order, targetMinutes: targetMinutes),
                    ],
                  ),
                ],
              ),
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

/// "Held for Abdul · ~6 min" (2.2.1): AUTO kept this delivery for a driver
/// on his way back — it is the other way from the runs going out now.
class HeldForTag extends StatelessWidget {
  final HeldFor heldFor;
  const HeldForTag({super.key, required this.heldFor});

  @override
  Widget build(BuildContext context) => ClockBuilder<String?>(
    select: heldFor.backIn,
    builder: (context, back, _) =>
        GeoTag('Held for ${heldFor.name}${back == null ? '' : ' · $back'}', color: QuiccColors.statusOpen),
  );
}

/// "ready in ~4 min" for a cooking delivery.
class _ReadyIn extends StatelessWidget {
  final StoredOrder order;
  const _ReadyIn({required this.order});

  @override
  Widget build(BuildContext context) {
    final eta = order.status.estimatedReadyAt;
    return ClockText((now) {
      final left = eta?.difference(now);
      if (left != null && left.inSeconds <= 0) return "time's up";
      return left == null
          ? 'cooking'
          : (left.inSeconds <= 30 ? 'ready any minute' : 'ready in ~${(left.inSeconds / 60).ceil()} min');
    }, style: QuiccType.text(QuiccType.label, weight: FontWeight.w600, color: QuiccColors.statusOpen));
  }
}

/// Minutes since the customer placed it, against the delivery target.
class _Age extends StatelessWidget {
  final StoredOrder order;
  final int targetMinutes;
  const _Age({required this.order, required this.targetMinutes});

  @override
  Widget build(BuildContext context) {
    final placed = order.placedTime;
    if (placed == null) return const SizedBox.shrink();
    final muted = context.palette.textMuted;
    return ClockBuilder<int>(
      select: (now) => now.difference(placed).inMinutes.clamp(0, 1 << 30),
      builder: (context, m, _) {
        final color = m >= targetMinutes
            ? QuiccColors.statusVoided
            : (m >= targetMinutes - 10 ? QuiccColors.statusFiring : muted);
        return Text(
          '${m < 0 ? 0 : m} min',
          style: QuiccType.number(QuiccType.label, weight: FontWeight.w700, color: color),
        );
      },
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

  /// Tap = select it (2.0.0); hold = open its details; ✕ = back to Waiting.
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onRemove;
  const PoolStopChip({
    super.key,
    required this.order,
    this.yellow = false,
    required this.selectMode,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final g = order.geo;
    final drive = driveLabel(g) ?? geoHint(g);
    final tip = order.order.money.tipCents;
    final cooking = order.state != OrderState.ready && !order.timeUp(timeNow());
    final border = selected ? QuiccColors.brand400 : (yellow ? QuiccColors.statusFiring : context.palette.borderSoft);
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
          onLongPress: onLongPress,
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
                        tooltip: yellow ? 'Drop this suggestion' : 'Back to Waiting',
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
                        style: QuiccType.number(
                          QuiccType.caption,
                          weight: FontWeight.w500,
                          color: context.palette.textSecondary,
                        ),
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

/// One stop of a run that is out (1.7.1): a pin in the driver's map colour
/// and the street ("531 Stevenson Ln"), or the kitchen # without an address.
/// [onTap] null = not tappable (the Map legend).
class StopAddressLine extends StatelessWidget {
  final StoredOrder order;
  final Color color;
  final VoidCallback? onTap;
  const StopAddressLine({super.key, required this.order, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final a = order.order.fulfillment.address;
    final text = a == null || a.isEmpty ? orderNumber(order) : streetOf(order);
    final line = Padding(
      padding: const EdgeInsets.symmetric(vertical: QuiccSpace.xs),
      child: Row(
        children: [
          Icon(Icons.location_on, size: 20, color: color),
          QuiccSpace.gapXs,
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: QuiccType.text(QuiccType.label, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return line;
    return InkWell(borderRadius: BorderRadius.circular(QuiccRadius.sm), onTap: onTap, child: line);
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

/// A driver out on a run: name, time out, his stops in stop order — a pin in
/// his map colour and the street (1.7.1; tap = the order) — ↺ (2.0.2: bring
/// him back with the run) and I HAVE RETURNED.
class OutRunCard extends StatelessWidget {
  final String name;
  final DateTime? outAt;
  final List<StoredOrder> orders;

  /// null = the accent.
  final Color? color;
  final bool busy;
  final VoidCallback? onReturned;

  /// Bring him back with his run (null hides the button: removed driver or a
  /// Pi older than 2.4.1).
  final VoidCallback? onRecall;
  final void Function(StoredOrder) onOpen;
  const OutRunCard({
    super.key,
    required this.name,
    required this.outAt,
    required this.orders,
    this.color,
    required this.busy,
    required this.onReturned,
    this.onRecall,
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
                      Icon(Icons.delivery_dining, color: QuiccColors.brand400, size: 24),
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
                  if (outAt case final t?)
                    ClockText(
                      (now) => 'out ${duration(now.isBefore(t) ? Duration.zero : now.difference(t))}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      styleAt: (now) => QuiccType.number(
                        QuiccType.body,
                        weight: FontWeight.w700,
                        color: !now.isBefore(t) && now.difference(t).inMinutes >= 45
                            ? QuiccColors.statusVoided
                            : context.palette.textSecondary,
                      ),
                    ),
                  QuiccSpace.gapSm,
                  if (orders.isEmpty)
                    Text(
                      'No orders on this run.',
                      style: QuiccType.text(QuiccType.label, color: context.palette.textMuted),
                    )
                  else
                    for (final o in orders)
                      StopAddressLine(
                        key: ValueKey('out-stop-${o.id}'),
                        order: o,
                        color: color ?? QuiccColors.brand400,
                        onTap: () => onOpen(o),
                      ),
                ],
              ),
            ),
            QuiccSpace.gapMd,
            if (onRecall != null) ...[
              SizedBox(
                width: 56,
                height: 56,
                child: Tooltip(
                  message: 'Bring back with the run',
                  child: OutlinedButton(
                    key: const ValueKey('recall-driver'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      foregroundColor: context.palette.textPrimary,
                      side: BorderSide(color: context.palette.textSecondary, width: 1.5),
                    ),
                    onPressed: busy ? null : onRecall,
                    child: const Icon(Icons.replay, size: 28),
                  ),
                ),
              ),
              QuiccSpace.gapSm,
            ],
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
