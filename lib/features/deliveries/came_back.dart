import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/clock.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import '../maps/geo_format.dart';
import 'delivery_widgets.dart';
import 'send_out.dart';

/// How long a came-back delivery is held to send it to Unassigned, at
/// animation speed 1× (Store settings → Sound & look scales it).
const Duration kCameBackHold = Duration(seconds: 1);

/// What a single tap on a came-back delivery says.
const String kCameBackTapHint = 'Press and hold to send to Unassigned';

/// "Came back · N" (1.7.1): deliveries the driver brought back that staff
/// chose to TRY AGAIN with. It sits under the Unassigned list in the left
/// column, below a rule, and only while there is one. The rows can't be
/// dragged or selected into a pool (and NEXT / AUTO leave them alone); a
/// press and hold sends one to Unassigned. Its own list scrolls, so the
/// regular deliveries above keep their room.
class CameBackSection extends StatelessWidget {
  final List<StoredOrder> orders;
  const CameBackSection({super.key, required this.orders});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      key: const ValueKey('came-back-section'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(key: const ValueKey('came-back-hr'), height: QuiccSpace.xl, thickness: 1, color: p.borderSoft),
        Padding(
          padding: const EdgeInsets.fromLTRB(QuiccSpace.sm, 0, QuiccSpace.sm, QuiccSpace.sm),
          child: Row(
            children: [
              const Icon(Icons.assignment_return_outlined, color: QuiccColors.statusFiring, size: 22),
              QuiccSpace.gapSm,
              Text('Came back · ${orders.length}', style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700)),
              QuiccSpace.gapMd,
              Expanded(
                child: Text(
                  'Hold one to send it to Unassigned',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: QuiccType.text(QuiccType.label, color: p.textMuted),
                ),
              ),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            key: const ValueKey('came-back-list'),
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
            children: [for (final o in orders) CameBackRow(key: ValueKey('came-back-${o.id}'), order: o)],
          ),
        ),
      ],
    );
  }
}

/// One came-back delivery: kitchen #, customer, street, how long it has been
/// back and CASH / PAID. Pressing fills a bar left to right; held to the end
/// (~1 s) the delivery goes to Unassigned, let go early and nothing happens.
/// A single tap only says how.
class CameBackRow extends ConsumerStatefulWidget {
  final StoredOrder order;
  const CameBackRow({super.key, required this.order});

  @override
  ConsumerState<CameBackRow> createState() => _CameBackRowState();
}

class _CameBackRowState extends ConsumerState<CameBackRow> with SingleTickerProviderStateMixin {
  late final AnimationController _hold;

  /// The hold reached the end: the release-tap that follows is not a tap.
  bool _fired = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _hold = AnimationController(vsync: this, duration: kCameBackHold)..addStatusListener(_onHoldStatus);
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  /// A toast beside the came-back list, not over it: the section sits at the
  /// bottom of the left column, where a toast would cover the row you are
  /// about to hold.
  void _say(String msg, {bool error = false}) {
    if (!mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    final box = context.findRenderObject();
    if (m == null || box is! RenderBox || !box.hasSize) return;
    final width = MediaQuery.sizeOf(context).width;
    var left = box.localToGlobal(Offset(box.size.width, 0)).dx + QuiccSpace.lg;
    // Too little room on the right (a narrow screen): the usual place.
    if (width - left - kSendOutToastInset < 240) left = QuiccSpace.xl;
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(left, 0, kSendOutToastInset, QuiccSpace.xl),
        backgroundColor: error ? QuiccColors.statusVoided : null,
        duration: const Duration(seconds: 3),
        content: Text(msg),
      ),
    );
  }

  void _onHoldStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || _fired) return;
    _fired = true;
    HapticFeedback.mediumImpact();
    _release();
  }

  void _down() {
    if (_busy) return;
    _fired = false;
    _hold.forward(from: 0);
  }

  /// Let go (or the press turned into a scroll) before the end: empty again.
  void _up() {
    if (!_fired) _hold.reset();
  }

  void _tap() {
    if (_fired || _busy) return;
    _say(kCameBackTapHint);
  }

  Future<void> _release() async {
    final n = orderNumber(widget.order);
    setState(() => _busy = true);
    try {
      await ref.read(floorProvider.notifier).releaseCameBack(widget.order.id);
      _say('$n is back in Unassigned');
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'not_came_back') => '$n is already back in Unassigned.',
        AgentException(code: kNotDeliveredUnsupported) => 'This Pi needs an update',
        _ => null,
      };
      msg == null
          ? toastError(context, e, lead: 'Not moved', area: 'deliveries', rightInset: kSendOutToastInset)
          : _say(msg, error: true);
    } finally {
      if (mounted) {
        // [_fired] stays set: the finger may still be down, and its release
        // must not read as a tap. The next press clears it.
        _hold.reset();
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // A functional hold, not decoration: it keeps its fill with Motion off,
    // at the chosen animation speed.
    _hold.duration = Motion.of(context, ref).scale(kCameBackHold);
    final so = widget.order;
    final o = so.order;
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: QuiccSpace.sm),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.lg),
          side: BorderSide(color: QuiccColors.statusFiring.withValues(alpha: 0.5)),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _down(),
          onTapUp: (_) => _up(),
          onTapCancel: _up,
          onTap: _tap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(QuiccSpace.md, QuiccSpace.md, QuiccSpace.md, QuiccSpace.sm),
                child: Row(
                  children: [
                    SizedBox(
                      width: 70,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          so.displayNumber,
                          style: QuiccType.number(
                            QuiccType.heading + 4,
                            weight: FontWeight.w700,
                            color: QuiccColors.brand400,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            o.customerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
                          ),
                          Text(
                            streetOf(so),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: QuiccType.text(QuiccType.label, color: p.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    QuiccSpace.gapSm,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          so.isPaid ? 'PAID' : 'CASH ${money(so.cashDueCents)}',
                          style: QuiccType.number(
                            QuiccType.label,
                            weight: FontWeight.w700,
                            color: so.isPaid ? p.textMuted : QuiccColors.statusFiring,
                          ),
                        ),
                        if (_busy)
                          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          ClockText((now) {
                            final at = so.status.notDelivered?.at;
                            return at == null ? 'came back' : 'back ${minutes(now.difference(at))}';
                          }, style: QuiccType.text(QuiccType.label, weight: FontWeight.w600, color: p.textMuted)),
                      ],
                    ),
                  ],
                ),
              ),
              // The hold's progress, left to right.
              SizedBox(
                height: 6,
                child: AnimatedBuilder(
                  animation: _hold,
                  builder: (context, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      key: ValueKey('came-back-progress-${so.id}'),
                      widthFactor: _hold.value,
                      heightFactor: 1,
                      child: const ColoredBox(color: QuiccColors.brand400),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
