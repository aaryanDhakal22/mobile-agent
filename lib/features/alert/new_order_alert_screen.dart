import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alert_player.dart';
import '../../core/models.dart';
import '../../theme/quicc_colors.dart';
import '../order_detail/order_detail_screen.dart';

/// Full-screen DoorDash-style new-order alarm. Shown when the agent broadcasts
/// `order.arrived` over SSE. One tap anywhere stops the alarm and transitions
/// into the order detail where the cashier can confirm the print.
class NewOrderAlertScreen extends StatefulWidget {
  final StoredOrder order;
  const NewOrderAlertScreen({super.key, required this.order});

  @override
  State<NewOrderAlertScreen> createState() => _NewOrderAlertScreenState();
}

class _NewOrderAlertScreenState extends State<NewOrderAlertScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..repeat(reverse: true);
    AlertPlayer.start();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _pulse.dispose();
    AlertPlayer.stop();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _handleTap() {
    if (_dismissed) return;
    _dismissed = true;
    AlertPlayer.stop();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => OrderDetailScreen(order: widget.order, confirmable: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.order.order;
    final onBrand = QuiccColors.brand900;

    return Scaffold(
      backgroundColor: QuiccColors.brand400,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'NEW ORDER',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 6,
                        color: onBrand,
                      ),
                    ),
                    _ServiceBadge(type: req.serviceType, color: onBrand),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        FadeTransition(
                          opacity: Tween<double>(begin: 0.55, end: 1).animate(_pulse),
                          child: Text(
                            '#${req.orderNumber}',
                            style: TextStyle(
                              fontSize: 180,
                              fontWeight: FontWeight.w700,
                              height: 1,
                              color: onBrand,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          req.customerName,
                          style: TextStyle(
                            fontSize: 42,
                            fontWeight: FontWeight.w500,
                            color: onBrand,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '\$${req.orderTotal.toStringAsFixed(2)} · ${req.items.length} item${req.items.length == 1 ? '' : 's'}',
                          style: TextStyle(
                            fontSize: 28,
                            color: onBrand.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Center(
                  child: FadeTransition(
                    opacity: Tween<double>(begin: 0.4, end: 1).animate(_pulse),
                    child: Text(
                      'TAP ANYWHERE TO VIEW',
                      style: TextStyle(
                        fontSize: 18,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w500,
                        color: onBrand.withValues(alpha: 0.7),
                      ),
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

class _ServiceBadge extends StatelessWidget {
  final String type;
  final Color color;
  const _ServiceBadge({required this.type, required this.color});

  @override
  Widget build(BuildContext context) {
    if (type.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(QuiccRadius.md),
      ),
      child: Text(
        type.toUpperCase(),
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 2,
          color: color,
        ),
      ),
    );
  }
}
