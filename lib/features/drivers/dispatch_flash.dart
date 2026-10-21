import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';

/// How long the driver's name stays up unless tapped away.
const Duration kDispatchFlashHold = Duration(seconds: 8);

/// Full-screen name flash when a driver is sent out (SSE `drivers.dispatched`,
/// or this tablet's own send-out): the driver's name huge, with the kitchen
/// numbers of their run, so the driver at the counter knows it's theirs.
/// Auto-dismisses after [kDispatchFlashHold] or on a tap. A newer dispatch
/// replaces the one on screen and restarts the timer.
///
/// Mounted by AlarmHost above every route but **below** the new-order alert,
/// which takes priority when both are up.
class DispatchFlash extends ConsumerStatefulWidget {
  const DispatchFlash({super.key});

  @override
  ConsumerState<DispatchFlash> createState() => _DispatchFlashState();
}

class _DispatchFlashState extends ConsumerState<DispatchFlash> with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  Timer? _hold;
  DriverDispatch? _shown;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    ref.listenManual<int>(floorProvider.select((s) => s.dispatches), (prev, next) {
      if (prev == null || next <= prev) return;
      final d = ref.read(floorProvider).dispatch;
      if (d != null) _show(d);
    });
  }

  @override
  void dispose() {
    _hold?.cancel();
    _fade.dispose();
    super.dispose();
  }

  void _show(DriverDispatch d) {
    _hold?.cancel();
    setState(() => _shown = d);
    _fade.forward();
    _hold = Timer(kDispatchFlashHold, _dismiss);
  }

  Future<void> _dismiss() async {
    _hold?.cancel();
    _hold = null;
    if (_shown == null) return;
    await _fade.reverse();
    // A newer dispatch may have started while fading out.
    if (mounted && _hold == null) setState(() => _shown = null);
  }

  @override
  Widget build(BuildContext context) {
    final d = _shown;
    if (d == null) return const SizedBox.shrink();
    final palette = context.palette;
    final numbers = d.numbers;

    return FadeTransition(
      opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _dismiss,
        child: Material(
          color: palette.bgCanvas.withValues(alpha: 0.96),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, box) {
                final h = box.maxHeight;
                final nameSize = math.min(220.0, h * 0.34);
                final numberSize = math.min(64.0, h * 0.09);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'OUT NOW',
                        style: TextStyle(
                          fontSize: 18,
                          letterSpacing: 6,
                          fontWeight: FontWeight.w700,
                          color: QuiccColors.brand400,
                        ),
                      ),
                      SizedBox(height: h * 0.03),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          d.driver.name.isEmpty ? 'Driver' : d.driver.name,
                          style: TextStyle(
                            fontSize: nameSize,
                            fontWeight: FontWeight.w800,
                            height: 1,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                      if (numbers.isNotEmpty) ...[
                        SizedBox(height: h * 0.05),
                        Flexible(
                          child: SingleChildScrollView(
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 16,
                              runSpacing: 12,
                              children: [
                                for (final n in numbers)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: QuiccColors.brand400.withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(QuiccRadius.lg),
                                      border: Border.all(color: QuiccColors.brand400, width: 2),
                                    ),
                                    child: Text(
                                      n,
                                      style: TextStyle(
                                        fontSize: numberSize,
                                        fontWeight: FontWeight.w800,
                                        color: QuiccColors.brand400,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      SizedBox(height: h * 0.04),
                      Text('Tap to close', style: TextStyle(color: palette.textMuted, fontSize: 16)),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
