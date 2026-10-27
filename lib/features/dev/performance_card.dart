import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/clock.dart';
import '../../core/frame_stats.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../settings/settings_card.dart';

const InfoText kPerformanceInfo = InfoText(
  'Performance',
  'The overlay draws Flutter\'s two frame graphs over the whole app: the top one is the raster '
      'thread (painting), the bottom one the UI thread (building the screens). A bar above the green '
      'line is a frame that took too long — a stutter. Off again after a restart.\n\n'
      'The numbers under it are the last 5 minutes of frames on this tablet; diagnostics send them '
      'to the owner too (tablet.frames).',
);

/// Developer Config → Performance (1.9.0): the performance overlay switch and
/// the last 5 minutes of frame times.
class PerformanceCard extends ConsumerWidget {
  const PerformanceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(perfOverlayProvider);
    final stats = ref.watch(frameStatsProvider);
    return SettingsCard(
      title: 'Performance',
      info: kPerformanceInfo,
      subtitle: 'For checking that the screens run smoothly on this tablet.',
      children: [
        SwitchListTile(
          key: const ValueKey('perf-overlay'),
          contentPadding: EdgeInsets.zero,
          title: Text('Performance overlay', style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
          subtitle: Text(
            'Frame graphs over the app. Off again after a restart.',
            style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
          ),
          value: on,
          onChanged: (v) => ref.read(perfOverlayProvider.notifier).state = v,
        ),
        // Refreshed every 5 s while shown.
        ClockBuilder<int>(
          select: (now) => now.millisecondsSinceEpoch ~/ 5000,
          builder: (context, _, now) => Text(
            stats.line(now),
            key: const ValueKey('frame-stats'),
            style: QuiccType.number(QuiccType.label, color: context.palette.textSecondary),
          ),
        ),
      ],
    );
  }
}
