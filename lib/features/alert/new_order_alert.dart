import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../arrived/accept_controls.dart';
import '../common/widgets.dart';
import '../drivers/dispatch_flash.dart';

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
    return Stack(
      children: [
        Positioned.fill(child: child),
        const Positioned.fill(child: DispatchFlash()),
        if (alarm.ringing && !alarm.visible) const Positioned(top: 0, left: 0, right: 0, child: _RingingBanner()),
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
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.notifications_active, color: QuiccColors.brand900),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '$n ORDER${n == 1 ? '' : 'S'} WAITING TO BE ACCEPTED — TAP TO SHOW',
                    style: const TextStyle(
                      color: QuiccColors.brand900,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
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

    return Material(
      color: bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 28, 40, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  FadeTransition(
                    opacity: Tween<double>(begin: 0.5, end: 1).animate(_pulse),
                    child: Text(
                      loud ? 'STILL WAITING' : 'NEW ORDER',
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 6,
                        color: onBrand,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  if (arrived.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(color: onBrand, borderRadius: BorderRadius.circular(QuiccRadius.md)),
                      child: Text(
                        '${arrived.length} WAITING',
                        style: const TextStyle(
                          color: QuiccColors.brand50,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  const Spacer(),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: onBrand,
                      side: const BorderSide(color: onBrand, width: 2),
                    ),
                    onPressed: () => ref.read(alarmProvider.notifier).hide(),
                    icon: const Icon(Icons.visibility_off_outlined),
                    label: const Text('HIDE (KEEPS RINGING)'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
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
                                    style: const TextStyle(
                                      fontSize: 44,
                                      fontWeight: FontWeight.w700,
                                      color: onBrand,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: FulfillmentTag(o.fulfillment.type, color: onBrand, size: 18),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Ticker(
                              builder: (context, now) {
                                final since = first.status.arrivalDate;
                                return Text(
                                  [
                                    money(o.money.totalCents),
                                    '${o.itemCount} item${o.itemCount == 1 ? '' : 's'}',
                                    if (o.sourceEventId.isNotEmpty) '#${o.sourceEventId}',
                                    if (since != null) 'waiting ${duration(now.difference(since))}',
                                  ].join(' · '),
                                  style: TextStyle(fontSize: 22, color: onBrand.withValues(alpha: 0.8)),
                                );
                              },
                            ),
                            if (o.fulfillment.address != null && !o.fulfillment.address!.isEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                o.fulfillment.address!.oneLine,
                                style: const TextStyle(fontSize: 18, color: onBrand),
                              ),
                            ],
                            const SizedBox(height: 18),
                            ItemLines(o.items, maxItems: 10, fontSize: 19, color: onBrand),
                            if (o.notes.trim().isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                'Note: ${o.notes.trim()}',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: onBrand),
                              ),
                            ],
                            if (arrived.length > 1) ...[
                              const SizedBox(height: 22),
                              Text(
                                'ALSO WAITING',
                                style: TextStyle(
                                  letterSpacing: 2,
                                  fontWeight: FontWeight.w600,
                                  color: onBrand.withValues(alpha: 0.7),
                                ),
                              ),
                              const SizedBox(height: 6),
                              for (final other in arrived.skip(1).take(5))
                                Text(
                                  '${other.order.customerName} · ${other.order.fulfillment.type.label} · ${money(other.order.money.totalCents)}',
                                  style: const TextStyle(fontSize: 17, color: onBrand),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 32),
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
