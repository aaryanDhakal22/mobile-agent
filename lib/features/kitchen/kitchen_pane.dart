import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import '../deliveries/lava_glow.dart';
import '../maps/geo_format.dart';
import '../order_detail/order_detail_screen.dart';
import '../arrived/time_picker.dart';
import 'resend_kitchen.dart';

/// The narrowest ticket column and the gap between tickets. 1.6.0: fewer,
/// larger tickets — 3 columns on the 1280×800 tablet, about 6 on screen.
const double kTicketWidth = 340;
const double kTicketGap = QuiccSpace.lg;

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

/// A ticket's heading (1.9.0): a delivery (online or POS) shows its street
/// ("4108 Old Court"), so the cook and the driver see where it goes; a
/// pickup — or a delivery without a house number — the customer's name.
String ticketHeading(StoredOrder so) =>
    (so.isDelivery ? ticketStreet(so.order.fulfillment.address) : null) ?? so.order.customerName;

/// Accepted orders as compact tickets, most urgent first, in masonry columns
/// (a ticket is as tall as its items — nothing is cut off). Future orders
/// already scheduled wait greyed in the "Later" strip at the end.
class KitchenPane extends ConsumerWidget {
  const KitchenPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var kitchen = ref.watch(floorProvider.select((s) => s.kitchenByUrgency));
    final later = ref.watch(floorProvider.select((s) => s.later));
    final greenTill = ref.watch(floorProvider.select((s) => s.floor?.greenTillMinutes ?? kDefaultGreenTillMinutes));
    final wave = ref.watch(floorProvider.select((s) => s.settings.features.paidWave));
    // 1.7.1: customers waiting on a paid ticket go first (most urgent order
    // kept within each part).
    if (wave) kitchen = [...kitchen.where((o) => o.paidNotReady), ...kitchen.where((o) => !o.paidNotReady)];
    return RefreshIndicator(
      onRefresh: () => ref.read(floorProvider.notifier).refresh(),
      child: LayoutBuilder(
        builder: (context, box) {
          const pad = QuiccSpace.pane;
          final cols = ((box.maxWidth - 2 * pad + kTicketGap) / (kTicketWidth + kTicketGap)).floor().clamp(1, 12);
          final columns = dealIntoColumns(kitchen, cols);
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(pad, pad, pad, 120), // room for the driver button
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PaneHeader(
                  title: 'Kitchen',
                  subtitle: kitchen.isEmpty ? null : '${kitchen.length} cooking · most urgent first',
                ),
                if (kitchen.isEmpty && later.isEmpty)
                  SizedBox(
                    height: (box.maxHeight - 200).clamp(200, 2000),
                    child: const EmptyState(
                      icon: Icons.soup_kitchen_outlined,
                      title: 'Nothing cooking',
                      message: 'Accepted orders show here until they are marked ready.',
                    ),
                  )
                else if (kitchen.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: QuiccSpace.xl),
                    child: Text(
                      'Nothing cooking right now.',
                      style: QuiccType.text(QuiccType.heading, color: context.palette.textSecondary),
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
                                  child: KitchenCard(
                                    key: ValueKey(so.id),
                                    order: so,
                                    greenTill: greenTill,
                                    paidWave: wave,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                if (later.isNotEmpty) LaterStrip(orders: later),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Future orders already scheduled, greyed at the end of Kitchen: when each
/// is due and when it rings again. Tap one to change its lead time.
class LaterStrip extends ConsumerWidget {
  final List<StoredOrder> orders;
  const LaterStrip({super.key, required this.orders});

  Future<void> _edit(BuildContext context, WidgetRef ref, StoredOrder so) async {
    final times = ref.read(floorProvider).settings.times;
    final due = so.dueAt;
    final lead = await showLeadTimeDialog(
      context,
      base: defaultMinutesFor(so, times),
      current: so.status.scheduledLeadMinutes,
      subtitle: due == null ? null : '${so.order.customerName} · due ${clock(due)}',
    );
    if (lead == null || !context.mounted || lead == so.status.scheduledLeadMinutes) return;
    try {
      await ref.read(floorProvider.notifier).schedule(so.id, lead);
      if (context.mounted) {
        toast(
          context,
          due == null ? 'Lead time $lead min' : 'Rings again at ${clock(due.subtract(Duration(minutes: lead)))}',
        );
      }
    } catch (e) {
      if (context.mounted) toastError(context, e, lead: 'Lead time not changed', area: 'kitchen');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      key: const ValueKey('later-strip'),
      padding: const EdgeInsets.only(top: QuiccSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.schedule, size: 18, color: context.palette.textMuted),
              QuiccSpace.gapSm,
              Eyebrow('Later · ${orders.length}'),
              QuiccSpace.gapMd,
              Expanded(
                child: Text(
                  'They ring again when it is time to cook. Tap one to change its lead time.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: QuiccType.text(QuiccType.caption, color: context.palette.textMuted),
                ),
              ),
            ],
          ),
          QuiccSpace.gapSm,
          Wrap(
            spacing: kTicketGap,
            runSpacing: kTicketGap,
            children: [for (final so in orders) _LaterTile(order: so, onTap: () => _edit(context, ref, so))],
          ),
        ],
      ),
    );
  }
}

class _LaterTile extends StatelessWidget {
  final StoredOrder order;
  final VoidCallback onTap;
  const _LaterTile({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final so = order;
    final due = so.dueAt;
    final ring =
        so.status.ringAt ??
        (due != null && so.status.scheduledLeadMinutes != null
            ? due.subtract(Duration(minutes: so.status.scheduledLeadMinutes!))
            : null);
    final lead = so.status.scheduledLeadMinutes;
    return Opacity(
      opacity: 0.6,
      child: SizedBox(
        width: kTicketWidth,
        child: Material(
          color: context.palette.bgElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(QuiccRadius.md),
            side: BorderSide(color: context.palette.borderSoft),
          ),
          child: InkWell(
            key: ValueKey('later-${so.id}'),
            borderRadius: BorderRadius.circular(QuiccRadius.md),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.md, vertical: QuiccSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          due == null ? 'Later' : 'Due ${clock(due)}',
                          style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700),
                        ),
                      ),
                      FulfillmentTag(so.order.fulfillment.type, size: QuiccType.caption),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [so.displayNumber, ticketHeading(so)].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
                  ),
                  Text(
                    [if (ring != null) 'rings ${clock(ring)}', if (lead != null) '$lead min lead'].join(' · '),
                    style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Customer waiting" (1.7.1, replaces the 1.5.0 green wave): a paid ticket
/// that isn't ready gets a red lava bar, a red halo breathing round the
/// card and "CUSTOMER WAITING · N min" — brighter and faster after
/// [kWaitingEscalate]. Motion off: a solid red bar and a thick red outline.
const Duration kWaitingEscalate = Duration(minutes: 5);

/// One lava loop at speed 1 (the halo breathes [_breaths] times per loop:
/// ~1 s), and the faster escalated loop (~0.6 s breaths).
const Duration kWaitingLava = Duration(seconds: 12);
const Duration kWaitingLavaHot = Duration(seconds: 6);
const int _breaths = 12, _breathsHot = 10;

/// The waiting bar's reds: the base, and the blobs drifting over it.
const Color kWaitingRed = Color(0xFFB91C1C);
const Color kWaitingRedHot = Color(0xFFDC2626);
const Color _blobRed = Color(0xFFF87171);
const Color _blobRedHot = Color(0xFFFFA28A);

/// The red halo round a waiting ticket: breathes outward, never below half.
class _WaitingHalo extends AnimatedWidget {
  final bool hot;
  final BorderRadius radius;
  final Widget child;
  const _WaitingHalo({
    super.key,
    required Animation<double> animation,
    required this.hot,
    required this.radius,
    required this.child,
  }) : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value;
    final breath = 0.5 + 0.5 * (0.5 + 0.5 * math.sin(2 * math.pi * (hot ? _breathsHot : _breaths) * t));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: (hot ? kWaitingRedHot : kWaitingRed).withValues(alpha: (hot ? 0.95 : 0.75) * breath),
            blurRadius: 6 + (hot ? 16 : 10) * breath,
            spreadRadius: (hot ? 3 : 1.5) * breath,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// What the bar shows for a waiting ticket.
typedef _Waiting = ({int minutes, bool hot, Animation<double>? lava});

/// The kitchen ticket's paper look: a white body with dark text in either
/// theme (the urgency colour lives in the header bar).
ThemeData paperTheme(ThemeData base) {
  const p = QuiccPalette.light;
  return base.copyWith(
    brightness: Brightness.light,
    extensions: const [p],
    textTheme: base.textTheme.apply(bodyColor: p.textPrimary, displayColor: p.textPrimary),
    iconTheme: base.iconTheme.copyWith(color: p.textPrimary),
    colorScheme: base.colorScheme.copyWith(
      brightness: Brightness.light,
      primary: QuiccColors.brand600,
      onSurface: p.textPrimary,
      outline: p.borderSoft,
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: QuiccColors.brand700,
        side: const BorderSide(color: QuiccColors.brand200, width: 1.5),
      ),
    ),
  );
}

/// Order notes on the white ticket: a darker amber than the dark theme's.
const Color kPaperNoteColor = Color(0xFFB45309);

/// Item lines on a ticket (1.6.0: a step above body, read from the line).
const double kTicketItemSize = 18;

/// READY / Reprint / Resend height on a ticket.
const double kTicketButtonHeight = 52;

/// One ticket on the Kitchen board: a coloured header bar (green → red by
/// time since arrival) with the number, then a white body. A paid ticket
/// that isn't ready yet shows "customer waiting" — the red lava bar and
/// halo ([paidWave] = the feature switch; see [kWaitingEscalate]).
class KitchenCard extends ConsumerStatefulWidget {
  final StoredOrder order;
  final int greenTill;
  final bool paidWave;
  const KitchenCard({super.key, required this.order, this.greenTill = kDefaultGreenTillMinutes, this.paidWave = true});

  @override
  ConsumerState<KitchenCard> createState() => _KitchenCardState();
}

class _KitchenCardState extends ConsumerState<KitchenCard> with SingleTickerProviderStateMixin {
  bool _busy = false;
  bool _reprinting = false;
  bool _resending = false;

  /// The one ticker of a waiting ticket: drives the lava and the halo (muted
  /// offstage by TickerMode; stopped when not waiting or Motion is off).
  late final AnimationController _wave = AnimationController(vsync: this, duration: kWaitingLava);

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  void _syncWave(bool animate, Duration period) {
    if (!animate) {
      if (_wave.isAnimating) _wave.stop();
      return;
    }
    if (_wave.duration != period) {
      _wave.duration = period;
      if (_wave.isAnimating) _wave.repeat();
    }
    // From a frame where the blobs are well spread: full from the start.
    if (!_wave.isAnimating) {
      if (_wave.value == 0) _wave.value = 0.18;
      _wave.repeat();
    }
  }

  Future<void> _ready() async {
    setState(() => _busy = true);
    try {
      await ref.read(floorProvider.notifier).ready(widget.order.id);
    } catch (e) {
      if (mounted) {
        if (e is AgentException && e.isConflict) {
          toast(context, 'Already moved on — the screen will refresh.', error: true);
        } else {
          toastError(context, e, lead: 'Not marked ready', area: 'kitchen');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reprint() async {
    setState(() => _reprinting = true);
    try {
      await ref.read(floorProvider.notifier).reprint(widget.order.id);
      if (mounted) toast(context, 'Receipt reprinted — ${widget.order.displayNumber}');
    } catch (e) {
      if (mounted) toastError(context, e, lead: 'Not reprinted', area: 'kitchen');
    } finally {
      if (mounted) setState(() => _reprinting = false);
    }
  }

  Future<void> _resend() => resendToKitchen(
    context,
    ref,
    widget.order,
    onBusy: (b) {
      if (mounted) setState(() => _resending = b);
    },
  );

  /// A 56×52 outlined icon button with a tooltip / screen-reader label.
  Widget _iconButton({required String label, required IconData icon, required bool busy, VoidCallback? onPressed}) {
    return Tooltip(
      message: label,
      child: SizedBox(
        width: 56,
        height: kTicketButtonHeight,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(56, kTicketButtonHeight)),
          onPressed: busy ? null : onPressed,
          child: busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 24, semanticLabel: label),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final so = widget.order;
    final o = so.order;
    final arrived = so.status.sentAt ?? so.status.arrivalDate ?? o.receivedAt ?? so.status.acceptedAt;
    final wave = widget.paidWave && so.paidNotReady;
    final motion = Motion.of(context, ref);
    final radius = BorderRadius.circular(QuiccRadius.md);
    return Ticker(
      interval: const Duration(seconds: 5),
      builder: (context, now) {
        // Clamped: a tablet clock a little behind the Pi's would count below zero.
        final raw = arrived == null ? Duration.zero : now.difference(arrived);
        final since = raw.isNegative ? Duration.zero : raw;
        final tone = lateColor(since, widget.greenTill);
        final waitStart = so.waitingSince;
        final waitedRaw = waitStart == null ? Duration.zero : now.difference(waitStart);
        final waited = waitedRaw.isNegative ? Duration.zero : waitedRaw;
        final hot = wave && waited >= kWaitingEscalate;
        _syncWave(wave && motion.full, motion.scale(hot ? kWaitingLavaHot : kWaitingLava));
        // 1.8.0: changed at the POS (pending, or OK'd < 10 min ago).
        final changed = so.changedTag(now);
        final _Waiting? waiting = wave
            ? (minutes: waited.inMinutes, hot: hot, lava: motion.full ? _wave : null)
            : null;
        final body = Padding(
          padding: const EdgeInsets.fromLTRB(QuiccSpace.lg, QuiccSpace.md, QuiccSpace.lg, QuiccSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TimerLine(order: so, since: since, tone: tone, now: now),
              QuiccSpace.gapSm,
              Text(
                ticketHeading(so),
                key: const ValueKey('ticket-heading'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700),
              ),
              if (so.status.flag != null) ...[
                QuiccSpace.gapSm,
                OrderFlagLine(so.status.flag!, fontSize: QuiccType.label),
              ],
              if (changed) ...[QuiccSpace.gapSm, ChangedTag(change: so.status.posChange!)],
              QuiccSpace.gapSm,
              ItemLines(o.items, fontSize: kTicketItemSize, removed: o.removedItems),
              if (o.notes.trim().isNotEmpty) ...[
                QuiccSpace.gapSm,
                Text(
                  '“${o.notes.trim()}”',
                  style: QuiccType.text(
                    QuiccType.body,
                    weight: FontWeight.w500,
                    color: kPaperNoteColor,
                  ).copyWith(fontStyle: FontStyle.italic),
                ),
              ],
              QuiccSpace.gapMd,
              Row(
                children: [
                  _iconButton(
                    label: kReprintReceiptLabel,
                    icon: Icons.print_outlined,
                    busy: _reprinting,
                    onPressed: _reprint,
                  ),
                  QuiccSpace.gapSm,
                  _iconButton(
                    label: kResendKitchenLabel,
                    icon: Icons.send_outlined,
                    busy: _resending,
                    onPressed: _resend,
                  ),
                  QuiccSpace.gapSm,
                  Expanded(
                    child: SizedBox(
                      height: kTicketButtonHeight,
                      child: FilledButton.icon(
                        // The theme's big-button padding would clip the
                        // label inside a ticket-height button.
                        style: FilledButton.styleFrom(
                          backgroundColor: QuiccColors.statusPaid,
                          foregroundColor: QuiccColors.brand900,
                          padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.md),
                          minimumSize: const Size(0, kTicketButtonHeight),
                          textStyle: QuiccType.text(QuiccType.heading, weight: FontWeight.w700, height: 1),
                        ),
                        onPressed: _busy ? null : _ready,
                        icon: const Icon(Icons.check_circle_outline, size: 24),
                        label: Text(_busy ? '…' : 'READY'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
        final outline = changed
            ? Border.all(color: QuiccColors.changeBlue, width: 4)
            : !wave
            ? Border.all(color: tone, width: 2)
            // Motion off: the thick red outline stands in for the halo.
            : Border.all(color: hot ? kWaitingRedHot : kWaitingRed, width: motion.full ? 2 : 4);
        final card = Theme(
          data: paperTheme(Theme.of(context)),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: radius,
              border: outline,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey('ticket-open-${so.id}'),
                // The whole ticket opens the order details (the chevron in
                // the bar says so).
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OrderDetailScreen(orderId: so.id, initial: so),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _CardBar(order: so, tone: tone, waiting: waiting),
                    body,
                  ],
                ),
              ),
            ),
          ),
        );
        if (changed && !(wave && motion.full)) {
          // A still blue glow (no pulse) so the cook finds the changed ticket.
          return DecoratedBox(
            key: const ValueKey('changed-glow'),
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [BoxShadow(color: QuiccColors.changeBlue.withValues(alpha: 0.7), blurRadius: 16, spreadRadius: 3)],
            ),
            child: card,
          );
        }
        if (!wave) return card;
        if (!motion.full) return KeyedSubtree(key: const ValueKey('paid-wave'), child: card);
        return _WaitingHalo(key: const ValueKey('paid-wave'), animation: _wave, hot: hot, radius: radius, child: card);
      },
    );
  }
}

/// The CHANGED tag on a ticket the POS changed (1.8.0): what changed, in
/// blue, until it is ready (or 10 min after OK).
class ChangedTag extends StatelessWidget {
  final PosChange change;
  const ChangedTag({super.key, required this.change});

  @override
  Widget build(BuildContext context) {
    final parts = [
      for (final l in change.added) '+${l.quantity} ${l.name}',
      for (final l in change.removed) '−${l.quantity} ${l.name}',
    ];
    return Container(
      key: const ValueKey('changed-tag'),
      padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.sm, vertical: 4),
      decoration: BoxDecoration(color: QuiccColors.changeBlue, borderRadius: BorderRadius.circular(QuiccRadius.sm)),
      child: Text(
        ['CHANGED', ...parts].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: QuiccType.text(QuiccType.label, weight: FontWeight.w800, color: Colors.white),
      ),
    );
  }
}

/// The ticket's header bar in the urgency colour: the number (the POS check
/// # with a POS tag for a POS order), PAID, and the order type.
class _CardBar extends StatelessWidget {
  final StoredOrder order;
  final Color tone;

  /// A paid ticket that isn't ready (1.7.1): red lava (or solid red with
  /// Motion off) and "CUSTOMER WAITING · N min".
  final _Waiting? waiting;
  const _CardBar({required this.order, required this.tone, this.waiting});

  @override
  Widget build(BuildContext context) {
    final so = order;
    final w = waiting;
    final ink = w == null ? QuiccColors.brand900 : Colors.white;
    final posCheck = so.status.posCheckNumber;
    // Each side shrinks rather than overflow on a narrow ticket.
    final row = Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    so.displayNumber,
                    style: QuiccType.number(QuiccType.display, weight: FontWeight.w700, color: ink, height: 1),
                  ),
                  if (so.isPos) ...[QuiccSpace.gapSm, PosTag(color: ink)],
                  if (!so.isPos && posCheck != null) ...[
                    QuiccSpace.gapSm,
                    Text(
                      'POS #$posCheck',
                      style: QuiccType.number(
                        QuiccType.label,
                        weight: FontWeight.w700,
                        color: ink.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        QuiccSpace.gapSm,
        // Pinned right (not sharing the free space with the number), and
        // shrinks on a very narrow ticket.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kTicketWidth * 0.55),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (so.status.paid) ...[const PaidBadge(), QuiccSpace.gapSm],
                FulfillmentTag(so.order.fulfillment.type, size: QuiccType.label, color: ink, counter: so.isCounter),
              ],
            ),
          ),
        ),
        // Tap anywhere on the ticket → the order details.
        Icon(
          Icons.chevron_right,
          key: const ValueKey('ticket-details'),
          size: 32,
          color: ink.withValues(alpha: 0.7),
          semanticLabel: 'Open order details',
        ),
      ],
    );
    const pad = EdgeInsets.fromLTRB(QuiccSpace.lg, QuiccSpace.sm, QuiccSpace.xs, QuiccSpace.sm);
    if (w == null) return Container(key: const ValueKey('card-bar'), color: tone, padding: pad, child: row);
    final lava = w.lava;
    return Container(
      key: const ValueKey('card-bar'),
      color: w.hot ? kWaitingRedHot : kWaitingRed,
      child: Stack(
        children: [
          if (lava != null)
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: const ValueKey('waiting-lava'),
                    painter: LavaPainter(
                      progress: lava,
                      color: w.hot ? _blobRedHot : _blobRed,
                      bleed: const EdgeInsets.symmetric(horizontal: 56, vertical: QuiccSpace.md),
                      blobScale: 1.8,
                      maxOpacity: w.hot ? 0.95 : 0.8,
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: pad,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                row,
                Text(
                  'CUSTOMER WAITING · ${w.minutes} min',
                  key: const ValueKey('customer-waiting'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: QuiccType.text(
                    QuiccType.body,
                    weight: FontWeight.w700,
                    color: Colors.white,
                  ).copyWith(letterSpacing: 0.6),
                ),
              ],
            ),
          ),
        ],
      ),
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
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          duration(since),
          key: const ValueKey('ticket-timer'),
          style: QuiccType.number(
            QuiccType.title,
            weight: FontWeight.w700,
            // Darker than the bar so it reads on the white ticket.
            color: Color.lerp(tone, Colors.black, 0.35),
            height: 1.1,
          ),
        ),
        if (left != null) ...[
          QuiccSpace.gapMd,
          Expanded(
            child: Text(
              late ? 'LATE ${minutes(left)}' : '${minutes(left)} left · ${clock(eta)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: QuiccType.text(
                late ? QuiccType.heading : QuiccType.body,
                weight: late ? FontWeight.w700 : FontWeight.w500,
                color: late ? QuiccColors.statusVoided : context.palette.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
