import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../maps/delivery_map.dart';

/// How long the "auto-accepted" banner stays.
const Duration kAutoAcceptBannerTime = Duration(seconds: 3);

/// "#1104 auto-accepted · 45 min" (2.2.0): when the Pi's auto-accept takes an
/// order, the tablet doesn't ring — it chimes (ring bridge, FloorState.chimes)
/// and shows this for [kAutoAcceptBannerTime] at the top, with a small map for
/// a delivery. Taps pass through; it never blocks the screen.
class AutoAcceptBanner extends ConsumerStatefulWidget {
  const AutoAcceptBanner({super.key});

  @override
  ConsumerState<AutoAcceptBanner> createState() => _AutoAcceptBannerState();
}

class _AutoAcceptBannerState extends ConsumerState<AutoAcceptBanner> {
  StoredOrder? _order;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _show(String? id) {
    final o = id == null ? null : ref.read(floorProvider).orders[id];
    if (o == null) return;
    _hide?.cancel();
    setState(() => _order = o);
    _hide = Timer(kAutoAcceptBannerTime, () {
      if (mounted) setState(() => _order = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(floorProvider.select((s) => s.autoAccepts), (prev, next) {
      if (next > (prev ?? 0)) _show(ref.read(floorProvider).autoAccepted);
    });
    final o = _order;
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, -0.4), end: Offset.zero).animate(a),
              child: child,
            ),
          ),
          child: o == null ? const SizedBox.shrink() : _Card(key: ValueKey(o.id), order: o),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final StoredOrder order;
  const _Card({super.key, required this.order});

  @override
  Widget build(BuildContext context) {
    final mins =
        order.status.prepMinutes ??
        order.status.estimatedReadyAt?.difference(order.status.acceptedAt ?? order.status.estimatedReadyAt!).inMinutes;
    final type = order.isDelivery ? 'Delivery' : 'Pickup';
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.only(top: QuiccSpace.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Material(
            key: const ValueKey('auto-accept-banner'),
            color: QuiccColors.brand400,
            elevation: 8,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(QuiccSpace.lg),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bolt, size: 36, color: QuiccColors.brand900),
                  QuiccSpace.gapMd,
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '#${order.displayNumber} auto-accepted${mins == null || mins <= 0 ? '' : ' · $mins min'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: QuiccType.text(QuiccType.title, weight: FontWeight.w700, color: QuiccColors.brand900),
                        ),
                        Text(
                          '$type · ${order.order.customer.displayName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: QuiccType.text(QuiccType.body, color: QuiccColors.brand900),
                        ),
                      ],
                    ),
                  ),
                  if (order.isDelivery) ...[
                    QuiccSpace.gapLg,
                    SizedBox(
                      width: 220,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: StaticDeliveryMap(order: order, height: 110, foreground: QuiccColors.brand900),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
