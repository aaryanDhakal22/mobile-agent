import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../order_detail/order_detail_screen.dart';
import '../arrived/time_picker.dart';
import 'resend_kitchen.dart';

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
/// (a ticket is as tall as its items — nothing is cut off). Future orders
/// already scheduled wait greyed in the "Later" strip at the end.
class KitchenPane extends ConsumerWidget {
  const KitchenPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kitchen = ref.watch(floorProvider.select((s) => s.kitchenByUrgency));
    final later = ref.watch(floorProvider.select((s) => s.later));
    final greenTill = ref.watch(floorProvider.select((s) => s.floor?.greenTillMinutes ?? kDefaultGreenTillMinutes));
    final wave = ref.watch(floorProvider.select((s) => s.settings.features.paidWave));
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
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Nothing cooking right now.',
                      style: TextStyle(fontSize: 18, color: context.palette.textSecondary),
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
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.schedule, size: 18, color: context.palette.textMuted),
              const SizedBox(width: 8),
              Eyebrow('Later · ${orders.length}'),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'They ring again when it is time to cook. Tap one to change its lead time.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.palette.textMuted, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
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
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          due == null ? 'Later' : 'Due ${clock(due)}',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                        ),
                      ),
                      FulfillmentTag(so.order.fulfillment.type, size: 11),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [so.displayNumber, so.order.customerName].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    [if (ring != null) 'rings ${clock(ring)}', if (lead != null) '$lead min lead'].join(' · '),
                    style: TextStyle(color: context.palette.textSecondary, fontSize: 13),
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

/// The paid-not-ready wave (1.5.0): a slow, soft green sweep across a ticket
/// body. Static tint when the platform asks for no animations.
class PaidWave extends StatefulWidget {
  final Widget child;
  final BorderRadius borderRadius;
  const PaidWave({super.key, required this.child, this.borderRadius = BorderRadius.zero});

  /// One sweep, left to right.
  static const Duration period = Duration(milliseconds: 3600);

  @override
  State<PaidWave> createState() => _PaidWaveState();
}

class _PaidWaveState extends State<PaidWave> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: PaidWave.period)..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final band = QuiccColors.statusPaid.withValues(alpha: 0.30);
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRRect(
              borderRadius: widget.borderRadius,
              child: still
                  ? ColoredBox(color: QuiccColors.statusPaid.withValues(alpha: 0.10))
                  : AnimatedBuilder(
                      animation: _c,
                      builder: (context, _) => DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [band.withValues(alpha: 0), band, band.withValues(alpha: 0)],
                            stops: const [0.3, 0.5, 0.7],
                            transform: _Slide(Curves.easeInOut.transform(_c.value) * 2 - 1),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// Moves a gradient sideways by [t] × its width (−1 … 1).
class _Slide extends GradientTransform {
  final double t;
  const _Slide(this.t);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) => Matrix4.translationValues(bounds.width * t, 0, 0);
}

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

/// One ticket on the Kitchen board: a coloured header bar (green → red by
/// time since arrival) with the number, then a white body. A paid ticket
/// that isn't ready yet gets the slow wave ([paidWave] = the feature switch).
class KitchenCard extends ConsumerStatefulWidget {
  final StoredOrder order;
  final int greenTill;
  final bool paidWave;
  const KitchenCard({super.key, required this.order, this.greenTill = kDefaultGreenTillMinutes, this.paidWave = true});

  @override
  ConsumerState<KitchenCard> createState() => _KitchenCardState();
}

class _KitchenCardState extends ConsumerState<KitchenCard> {
  bool _busy = false;
  bool _reprinting = false;
  bool _resending = false;

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

  /// A 48×44 outlined icon button with a tooltip / screen-reader label.
  Widget _iconButton({required String label, required IconData icon, required bool busy, VoidCallback? onPressed}) {
    return Tooltip(
      message: label,
      child: SizedBox(
        width: 48,
        height: 44,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 44)),
          onPressed: busy ? null : onPressed,
          child: busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 20, semanticLabel: label),
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
    final radius = BorderRadius.circular(QuiccRadius.md);
    return Ticker(
      interval: const Duration(seconds: 5),
      builder: (context, now) {
        final since = arrived == null ? Duration.zero : now.difference(arrived);
        final tone = lateColor(since, widget.greenTill);
        final body = Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TimerLine(order: so, since: since, tone: tone, now: now),
              const SizedBox(height: 6),
              Text(
                o.customerName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              if (so.status.flag != null) ...[const SizedBox(height: 6), OrderFlagLine(so.status.flag!, fontSize: 12)],
              const SizedBox(height: 4),
              ItemLines(o.items, fontSize: 13),
              if (o.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '“${o.notes.trim()}”',
                  style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: kPaperNoteColor),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  _iconButton(
                    label: kReprintReceiptLabel,
                    icon: Icons.print_outlined,
                    busy: _reprinting,
                    onPressed: _reprint,
                  ),
                  const SizedBox(width: 6),
                  _iconButton(
                    label: kResendKitchenLabel,
                    icon: Icons.send_outlined,
                    busy: _resending,
                    onPressed: _resend,
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
        );
        return Theme(
          data: paperTheme(Theme.of(context)),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: radius,
              border: Border.all(color: tone, width: 2),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OrderDetailScreen(orderId: so.id, initial: so),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _CardBar(order: so, tone: tone),
                    if (wave) PaidWave(key: const ValueKey('paid-wave'), child: body) else body,
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

/// The ticket's header bar in the urgency colour: the number (the POS check
/// # with a POS tag for a POS order), PAID, and the order type.
class _CardBar extends StatelessWidget {
  final StoredOrder order;
  final Color tone;
  const _CardBar({required this.order, required this.tone});

  @override
  Widget build(BuildContext context) {
    final so = order;
    const ink = QuiccColors.brand900;
    final posCheck = so.status.posCheckNumber;
    return Container(
      key: const ValueKey('card-bar'),
      color: tone,
      padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
      // Each side shrinks rather than overflow on a narrow ticket.
      child: Row(
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
                      style: const TextStyle(fontSize: 26, height: 1, fontWeight: FontWeight.w800, color: ink),
                    ),
                    if (so.isPos) ...[const SizedBox(width: 8), const PosTag(color: ink)],
                    if (!so.isPos && posCheck != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        'POS #$posCheck',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ink.withValues(alpha: 0.75)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (so.status.paid) ...[const PaidBadge(), const SizedBox(width: 8)],
                  FulfillmentTag(so.order.fulfillment.type, size: 11, color: ink),
                ],
              ),
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
      children: [
        Text(
          duration(since),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
            // Darker than the bar so it reads on the white ticket.
            color: Color.lerp(tone, Colors.black, 0.35),
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
