import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';

/// The blue CHANGED alert (1.8.0, Pi 2.3.0): a cashier added or voided a
/// kitchen item on a check that is already on the tablet. A blue tint over
/// the whole app, a big card — "#158 CHANGED", the lines (+ added in blue,
/// − removed struck through in red) — and one OK. It sits above every route
/// (in [AlarmHost]) and waits behind a ringing new order: the new order
/// first, then the change. The chime (on show, then every 30 s until OK) is
/// the ring bridge's (core/ring_bridge.dart). Motion off: a still card.
class ChangeAlertHost extends ConsumerWidget {
  const ChangeAlertHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ringing = ref.watch(alarmProvider.select((a) => a.ringing));
    final pending = ref.watch(floorProvider.select((s) => s.pendingChanges));
    if (ringing || pending.isEmpty) return const SizedBox.shrink();
    return ChangeAlert(
      key: ValueKey('change-alert-${pending.first.status.posChange!.id}'),
      order: pending.first,
      more: pending.length - 1,
    );
  }
}

/// What the alert says under the title, by what the order was doing.
String changeSubtitle(PosChange c) => switch (c.kind) {
  'back_to_cooking' => 'It was ready — back to cooking',
  'ready' => 'It is already ready',
  'out' => c.driverName.isEmpty ? 'It is already out for delivery' : '${c.driverName} already left with it',
  _ => 'Changed at the POS while cooking',
};

class ChangeAlert extends ConsumerStatefulWidget {
  final StoredOrder order;

  /// Other changes waiting behind this one.
  final int more;
  const ChangeAlert({super.key, required this.order, this.more = 0});

  @override
  ConsumerState<ChangeAlert> createState() => _ChangeAlertState();
}

class _ChangeAlertState extends ConsumerState<ChangeAlert> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _ok() async {
    final c = widget.order.status.posChange;
    if (c == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(floorProvider.notifier).ackChange(widget.order.id, c.id);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't reach the Pi — try OK again");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final motion = Motion.of(context, ref);
    if (motion.full && !_pulse.isAnimating) {
      _pulse.duration = motion.scale(const Duration(milliseconds: 1200));
      _pulse.repeat(reverse: true);
    } else if (!motion.full && _pulse.isAnimating) {
      _pulse.stop();
    }
    final so = widget.order;
    final c = so.status.posChange!;
    final card = Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.fromLTRB(36, 28, 36, 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        border: Border.all(color: QuiccColors.changeBlue, width: 6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.change_circle, size: 52, color: QuiccColors.changeBlue),
              QuiccSpace.gapMd,
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '#${so.displayNumber} CHANGED',
                    key: const ValueKey('change-title'),
                    style: QuiccType.number(
                      QuiccType.display,
                      weight: FontWeight.w800,
                      color: QuiccColors.changeBlueDeep,
                      height: 1,
                    ),
                  ),
                ),
              ),
              if (widget.more > 0)
                Text(
                  '+${widget.more} more',
                  style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700, color: QuiccColors.changeBlue),
                ),
            ],
          ),
          QuiccSpace.gapSm,
          Text(
            [changeSubtitle(c), if (so.order.customerName != 'Guest') so.order.customerName].join(' · '),
            style: QuiccType.text(QuiccType.heading, weight: FontWeight.w600, color: const Color(0xFF334155)),
          ),
          const SizedBox(height: 18),
          for (final l in c.added) _Line(l, added: true),
          for (final l in c.removed) _Line(l, added: false),
          const SizedBox(height: 24),
          if (_error != null) ...[
            Text(
              _error!,
              style: QuiccType.text(QuiccType.body, weight: FontWeight.w600, color: QuiccColors.removedRed),
            ),
            QuiccSpace.gapSm,
          ],
          SizedBox(
            height: 84,
            child: FilledButton(
              key: const ValueKey('change-ok'),
              style: FilledButton.styleFrom(
                backgroundColor: QuiccColors.changeBlue,
                foregroundColor: Colors.white,
                textStyle: QuiccType.text(QuiccType.display, weight: FontWeight.w800, height: 1),
              ),
              onPressed: _busy ? null : _ok,
              child: Text(_busy ? '…' : 'OK'),
            ),
          ),
        ],
      ),
    );
    final glowing = motion.full
        ? AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) {
              final t = 0.5 + 0.5 * math.sin(math.pi * (_pulse.value - 0.5));
              return DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(QuiccRadius.lg),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF60A5FA).withValues(alpha: 0.55 + 0.45 * t),
                      blurRadius: 18 + 26 * t,
                      spreadRadius: 2 + 8 * t,
                    ),
                  ],
                ),
                child: child,
              );
            },
            child: card,
          )
        : card;
    return Material(
      key: const ValueKey('change-alert'),
      color: QuiccColors.changeBlueDeep.withValues(alpha: 0.86),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: glowing),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final ChangeLine line;
  final bool added;
  const _Line(this.line, {required this.added});

  @override
  Widget build(BuildContext context) {
    final color = added ? QuiccColors.changeBlue : QuiccColors.removedRed;
    final text = '${added ? '+' : '−'}${math.max(line.quantity, 1)} ${line.name}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: QuiccType.text(QuiccType.title, weight: FontWeight.w800, color: color).copyWith(
                decoration: added ? null : TextDecoration.lineThrough,
                decorationColor: color,
                decorationThickness: 2.5,
              ),
            ),
          ),
          if (!added)
            Text(
              'REMOVED',
              style: QuiccType.text(QuiccType.body, weight: FontWeight.w800, color: color),
            )
          else if (!line.kitchen)
            Text(
              'not for the kitchen',
              style: QuiccType.text(QuiccType.body, weight: FontWeight.w600, color: const Color(0xFF64748B)),
            ),
        ],
      ),
    );
  }
}
