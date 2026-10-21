import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/sse.dart';

/// How long the agent may be unreachable before the banner shows (a short
/// blip — the Pi restarting, Wi-Fi roaming — shouldn't alarm anyone).
const Duration kPiUnreachableAfter = Duration(seconds: 20);

/// A big red bar across the top while the tablet can't reach the Pi, with
/// what to do about it. New orders can't ring here while it shows.
class PiUnreachableBanner extends ConsumerStatefulWidget {
  const PiUnreachableBanner({super.key});

  @override
  ConsumerState<PiUnreachableBanner> createState() => _PiUnreachableBannerState();
}

class _PiUnreachableBannerState extends ConsumerState<PiUnreachableBanner> {
  /// Seconds without the Pi, counted by [_tick] (null while connected).
  int? _downFor;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _track(ref.read(floorProvider).connection);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _track(SseStatus st) {
    if (st == SseStatus.connected) {
      _downFor = null;
      _tick?.cancel();
      _tick = null;
      return;
    }
    _downFor ??= 0;
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _downFor = (_downFor ?? 0) + 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SseStatus>(floorProvider.select((s) => s.connection), (_, st) => setState(() => _track(st)));
    final down = _downFor;
    if (down == null || down < kPiUnreachableAfter.inSeconds) return const SizedBox.shrink();
    final mins = down ~/ 60;
    return Material(
      color: const Color(0xFFC62828),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 34),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mins >= 1 ? "Can't reach the Pi — $mins min" : "Can't reach the Pi",
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'New orders will NOT ring here. 1) Check the tablet Wi-Fi. '
                      '2) Check the Pi has power and its network cable. '
                      '3) Unplug the Pi, wait 10 s, plug it back in (2 min to start). '
                      '4) Still red? Call the owner.',
                      style: TextStyle(color: Colors.white, fontSize: 15, height: 1.3),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => ref.read(floorProvider.notifier).resume(),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('RETRY NOW'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
