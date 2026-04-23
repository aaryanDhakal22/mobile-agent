import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/pop_in.dart';
import '../../theme/quicc_colors.dart';
import 'driver_state.dart';

class DriversPane extends ConsumerWidget {
  const DriversPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(driverProvider);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: _RosterColumn(state: state),
          ),
          const SizedBox(width: 24),
          Expanded(
            flex: 2,
            child: _QueueColumn(queue: state.queue),
          ),
        ],
      ),
    );
  }
}

class _RosterColumn extends ConsumerWidget {
  final DriverState state;
  const _RosterColumn({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text(
              'Drivers',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            ),
            Text(
              '${state.onShift.length} on shift',
              style: TextStyle(color: context.palette.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Resets daily at 10:00 AM.',
          style: TextStyle(color: context.palette.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: ListView.separated(
            itemCount: kDriverRoster.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final name = kDriverRoster[i];
              final clockedInAt = state.onShift[name];
              return PopIn.stagger(
                index: i,
                child: _DriverTile(
                  name: name,
                  clockedInAt: clockedInAt,
                  onTap: () => ref.read(driverProvider.notifier).toggle(name),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DriverTile extends StatelessWidget {
  final String name;
  final DateTime? clockedInAt;
  final VoidCallback onTap;
  const _DriverTile({
    required this.name,
    required this.clockedInAt,
    required this.onTap,
  });

  bool get _onShift => clockedInAt != null;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: _onShift ? context.palette.bgElevated : context.palette.bgSurface,
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        border: Border.all(
          color: _onShift ? QuiccColors.brand400 : context.palette.borderSoft,
          width: _onShift ? 1.5 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(QuiccRadius.lg),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                _Avatar(letter: name[0], active: _onShift),
                const SizedBox(width: 16),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: _onShift ? FontWeight.w600 : FontWeight.w400,
                          color: _onShift
                              ? context.palette.textPrimary
                              : context.palette.textSecondary,
                        ),
                      ),
                      if (_onShift) ...[
                        const SizedBox(width: 10),
                        Text(
                          _formatClockIn(clockedInAt!),
                          style: TextStyle(
                            fontSize: 13,
                            color: context.palette.textMuted,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                _ShiftIndicator(active: _onShift),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatClockIn(DateTime t) {
  final hour12 = t.hour == 0 ? 12 : (t.hour > 12 ? t.hour - 12 : t.hour);
  final minute = t.minute.toString().padLeft(2, '0');
  final period = t.hour >= 12 ? 'pm' : 'am';
  return '$hour12:$minute $period';
}

class _Avatar extends StatelessWidget {
  final String letter;
  final bool active;
  const _Avatar({required this.letter, required this.active});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? QuiccColors.brand400 : context.palette.bgHover,
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 18,
          color: active ? QuiccColors.brand900 : context.palette.textMuted,
        ),
      ),
    );
  }
}

class _ShiftIndicator extends StatelessWidget {
  final bool active;
  const _ShiftIndicator({required this.active});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
      child: active
          ? Container(
              key: const ValueKey('on'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: QuiccColors.brand400.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: QuiccColors.brand400,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'ON SHIFT',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600,
                      color: QuiccColors.brand400,
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(
              key: ValueKey('off'),
              width: 0,
              height: 0,
            ),
    );
  }
}

class _QueueColumn extends StatelessWidget {
  final List<String> queue;
  const _QueueColumn({required this.queue});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: context.palette.bgSurface,
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        border: Border.all(color: context.palette.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'QUEUE',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 2,
                  color: context.palette.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '${queue.length}',
                style: TextStyle(
                  fontSize: 11,
                  color: context.palette.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: queue.isEmpty
                ? const _EmptyQueue()
                : ListView.separated(
                    itemCount: queue.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _QueueRow(
                      position: i + 1,
                      name: queue[i],
                      next: i == 0,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final int position;
  final String name;
  final bool next;
  const _QueueRow({
    required this.position,
    required this.name,
    required this.next,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: next ? QuiccColors.brand400.withValues(alpha: 0.10) : context.palette.bgElevated,
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        border: Border.all(
          color: next ? QuiccColors.brand400.withValues(alpha: 0.35) : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '$position',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: next ? QuiccColors.brand400 : context.palette.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontSize: 17,
                fontWeight: next ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (next)
            const Text(
              'NEXT',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w600,
                color: QuiccColors.brand400,
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Queue is empty',
        style: TextStyle(color: context.palette.textMuted),
      ),
    );
  }
}
