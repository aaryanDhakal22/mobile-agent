import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/quicc_colors.dart';
import 'driver_state.dart';

/// Non-blocking transient overlay. Watches the dequeue stream; when a name
/// fires, fades it in across the entire viewport, holds, and fades out â€” all
/// inside 1.5 seconds. Pointer events pass through, so the cashier can keep
/// working even mid-blink.
class DriverAnnouncer extends ConsumerStatefulWidget {
  const DriverAnnouncer({super.key});

  @override
  ConsumerState<DriverAnnouncer> createState() => _DriverAnnouncerState();
}

class _DriverAnnouncerState extends ConsumerState<DriverAnnouncer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  Timer? _holdTimer;
  String? _name;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  void _show(String name) {
    _holdTimer?.cancel();
    setState(() => _name = name);
    _anim.forward(from: 0);
    // 200 ms fade-in, 1100 ms hold at full opacity, 200 ms fade-out.
    // End-to-end = 1.5 s. Timer fires at the moment fade-out should begin.
    _holdTimer = Timer(const Duration(milliseconds: 1300), () async {
      await _anim.reverse();
      if (mounted) setState(() => _name = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<String>>(driverAnnouncementStreamProvider, (_, next) {
      next.whenData(_show);
    });

    if (_name == null) return const SizedBox.shrink();

    return IgnorePointer(
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _anim, curve: Curves.easeOut),
        child: Container(
          color: context.palette.bgCanvas.withValues(alpha: 0.82),
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'NEXT DRIVER',
                  style: TextStyle(
                    fontSize: 16,
                    letterSpacing: 6,
                    fontWeight: FontWeight.w600,
                    color: QuiccColors.brand400,
                  ),
                ),
                const SizedBox(height: 16),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _name!,
                    style: TextStyle(
                      fontSize: 220,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      color: context.palette.textPrimary,
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
