import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../arrived/accept_controls.dart';
import '../common/widgets.dart';
import '../drivers/dispatch_flash.dart';
import '../maps/delivery_map.dart';

/// Stacks, above every route: the driver name flash, the "still ringing"
/// banner, and on top the full-screen new-order alert (it wins over the name
/// flash). The sound and Android's full-screen notification are driven by the
/// ring bridge (core/ring_bridge.dart), which also runs with no screen.
class AlarmHost extends ConsumerWidget {
  final Widget child;
  const AlarmHost({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alarm = ref.watch(alarmProvider);
    final strip = alarm.ringing && !alarm.visible;
    return Stack(
      children: [
        // The "still ringing" strip pushes the app down rather than covering
        // it, so the rail's q (mode switch) stays reachable while it rings.
        // The child keeps one fixed position in the tree (a keyed Expanded
        // under the same wrapper) so the Navigator keeps its state when the
        // strip comes and goes.
        Positioned.fill(
          child: Column(
            children: [
              if (strip) const _RingingBanner(),
              Expanded(
                key: const ValueKey('alarm-host-child'),
                child: MediaQuery.removePadding(context: context, removeTop: strip, child: child),
              ),
            ],
          ),
        ),
        const Positioned.fill(child: DispatchFlash()),
        if (alarm.ringing && alarm.visible) const Positioned.fill(child: NewOrderAlert()),
      ],
    );
  }
}

/// Thin strip across the top while the alert is hidden but still ringing.
class _RingingBanner extends ConsumerWidget {
  const _RingingBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(floorProvider.select((s) => s.arrived.length));
    final loud = ref.watch(alarmProvider.select((a) => a.loud));
    return Material(
      color: loud ? QuiccColors.statusVoided : QuiccColors.statusFiring,
      child: InkWell(
        onTap: () => ref.read(alarmProvider.notifier).show(),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.xl, vertical: QuiccSpace.md),
            child: Row(
              children: [
                const Icon(Icons.notifications_active, color: QuiccColors.brand900),
                QuiccSpace.gapMd,
                Expanded(
                  child: Text(
                    '$n order${n == 1 ? '' : 's'} waiting to be accepted — tap to show',
                    style: QuiccType.text(QuiccType.body, weight: FontWeight.w700, color: QuiccColors.brand900),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen alarm. It cannot be tapped away: the sound stops only once
/// every arrived order is accepted. HIDE just takes it off the screen.
class NewOrderAlert extends ConsumerStatefulWidget {
  const NewOrderAlert({super.key});

  @override
  ConsumerState<NewOrderAlert> createState() => _NewOrderAlertState();
}

class _NewOrderAlertState extends ConsumerState<NewOrderAlert> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final arrived = ref.watch(floorProvider.select((s) => s.arrived));
    final loud = ref.watch(alarmProvider.select((a) => a.loud));
    if (arrived.isEmpty) return const SizedBox.shrink();
    final first = arrived.first;
    final o = first.order;
    const onBrand = QuiccColors.brand900;
    final bg = loud ? QuiccColors.statusFiring : QuiccColors.brand400;

    final address = o.fulfillment.address;
    final hasAddress = address != null && !address.isEmpty;

    return Material(
      color: bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, QuiccSpace.xl, 40, QuiccSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  // The title shrinks before the HIDE button is pushed off a
                  // narrow tablet.
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: FadeTransition(
                            opacity: Tween<double>(begin: 0.5, end: 1).animate(_pulse),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                loud ? 'Still waiting' : 'New order',
                                style: QuiccType.text(QuiccType.display, weight: FontWeight.w700, color: onBrand),
                              ),
                            ),
                          ),
                        ),
                        if (arrived.length > 1) ...[
                          QuiccSpace.gapXl,
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.md, vertical: QuiccSpace.xs + 2),
                            decoration: BoxDecoration(
                              color: onBrand,
                              borderRadius: BorderRadius.circular(QuiccRadius.md),
                            ),
                            child: Text(
                              '${arrived.length} waiting',
                              style: QuiccType.text(
                                QuiccType.body,
                                weight: FontWeight.w700,
                                color: QuiccColors.brand50,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  QuiccSpace.gapLg,
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: onBrand,
                      side: const BorderSide(color: onBrand, width: 2),
                      textStyle: QuiccType.text(QuiccType.label, weight: FontWeight.w600),
                    ),
                    onPressed: () => ref.read(alarmProvider.notifier).hide(),
                    icon: const Icon(Icons.visibility_off_outlined),
                    label: const Text('Hide (keeps ringing)'),
                  ),
                ],
              ),
              QuiccSpace.gapLg,
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Flexible(
                                  child: Text(
                                    o.customerName,
                                    overflow: TextOverflow.ellipsis,
                                    style: QuiccType.text(
                                      QuiccType.display,
                                      weight: FontWeight.w700,
                                      color: onBrand,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                                QuiccSpace.gapLg,
                                Padding(
                                  padding: const EdgeInsets.only(bottom: QuiccSpace.sm),
                                  child: FulfillmentTag(o.fulfillment.type, color: onBrand, size: QuiccType.label),
                                ),
                              ],
                            ),
                            QuiccSpace.gapXs,
                            Ticker(
                              builder: (context, now) {
                                final since = first.status.arrivalDate;
                                // A tablet clock a little behind the Pi's would show a negative wait.
                                final wait = since == null
                                    ? null
                                    : (now.difference(since).isNegative ? Duration.zero : now.difference(since));
                                final muted = onBrand.withValues(alpha: 0.8);
                                return Text.rich(
                                  TextSpan(
                                    style: QuiccType.text(QuiccType.heading, color: muted),
                                    children: [
                                      TextSpan(
                                        text: money(o.money.totalCents),
                                        style: QuiccType.number(QuiccType.heading, color: muted),
                                      ),
                                      TextSpan(
                                        text: [
                                          '',
                                          '${o.itemCount} item${o.itemCount == 1 ? '' : 's'}',
                                          if (o.sourceEventId.isNotEmpty) '#${o.sourceEventId}',
                                          if (first.status.future && first.dueAt != null) 'for ${clock(first.dueAt)}',
                                          if (wait != null) 'waiting ',
                                        ].join(' · '),
                                      ),
                                      if (wait != null)
                                        TextSpan(
                                          text: duration(wait),
                                          style: QuiccType.number(QuiccType.heading, color: muted),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            // 1.6.0: a read-only map right under the timer.
                            if (first.isDelivery && hasAddress) ...[
                              QuiccSpace.gapMd,
                              StaticDeliveryMap(
                                key: ValueKey('alert-map-${first.id}'),
                                order: first,
                                foreground: onBrand,
                              ),
                            ],
                            if (hasAddress) ...[
                              QuiccSpace.gapSm,
                              Text(
                                address.oneLine,
                                style: QuiccType.text(QuiccType.heading, weight: FontWeight.w500, color: onBrand),
                              ),
                            ],
                            QuiccSpace.gapLg,
                            ItemLines(o.items, maxItems: 10, fontSize: QuiccType.heading, color: onBrand),
                            if (o.notes.trim().isNotEmpty) ...[
                              QuiccSpace.gapMd,
                              Text(
                                'Note: ${o.notes.trim()}',
                                style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700, color: onBrand),
                              ),
                            ],
                            if (arrived.length > 1) ...[
                              QuiccSpace.gapXl,
                              Text(
                                'Also waiting',
                                style: QuiccType.text(
                                  QuiccType.label,
                                  weight: FontWeight.w600,
                                  color: onBrand.withValues(alpha: 0.7),
                                ),
                              ),
                              QuiccSpace.gapXs,
                              for (final other in arrived.skip(1).take(5))
                                Text(
                                  '${other.order.customerName} · ${other.order.fulfillment.type.label} · ${money(other.order.money.totalCents)}',
                                  style: QuiccType.text(QuiccType.body, color: onBrand),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: QuiccSpace.xxl),
                    Expanded(
                      flex: 4,
                      child: SingleChildScrollView(
                        child: AcceptControls(key: ValueKey(first.id), order: first, onBrand: true, chipFontSize: 24),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
