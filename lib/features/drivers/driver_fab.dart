import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/auto_preview.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import '../deliveries/delivery_widgets.dart';
import '../deliveries/send_out.dart';
import '../home/home_nav.dart';
import '../home/idle_kitchen.dart';
import '../maps/geo_format.dart';
import 'drivers_texts.dart';
import 'next_rules.dart';

/// Snackbars from the button stay left of it.
const double _toastInset = kSendOutToastInset;

/// Hold the round button this long to undo the last return.
const Duration kUndoHold = Duration(milliseconds: 2000);

/// An auto-assign pop (2.2.1) closes again after this long without a touch
/// (the pool stays).
const Duration kFobPopIdle = Duration(seconds: 30);

/// How often a pop waiting behind the ring or a dialog looks again.
const Duration _popRetry = Duration(seconds: 1);

/// Widest the open card gets.
const double _cardWidth = 420;

/// Tickets listed on the NEXT card before "+N more".
const int _maxTickets = 5;

/// The floating driver button (bottom-right on every pane but Settings) —
/// the drivers' own space; the kitchen never needs it.
///
///   collapsed   truck + "N out" badge = drivers out on a run
///   tap         opens the card:
///     NEXT      the next driver in the queue, his tickets (kitchen #, street,
///               ready / cooking) and one SEND OUT. When there is something to
///               plan first ([planNext]) the button opens Deliveries (or
///               Drivers, when nobody can go) instead.
///     OUT       a pill per driver who is out; tap = "I have returned" (run
///               delivered, back of the queue)
///   round       tap closes; hold 2 s = undo the last return (the agent allows
///               it for 10 minutes)
///   tap outside closes
///   pops     (2.2.1) when the Pi's auto-assign pooled deliveries for the
///            NEXT driver ([fobPopProvider]): opens on the NEXT card with the
///            chime — never over the full-screen ring or a dialog (it waits)
///            — and closes again after [kFobPopIdle] without a touch
///
/// Must fill its parent (Positioned.fill): the invisible backdrop catches
/// outside taps.
class DriverFab extends ConsumerStatefulWidget {
  const DriverFab({super.key});

  @override
  ConsumerState<DriverFab> createState() => _DriverFabState();
}

class _DriverFabState extends ConsumerState<DriverFab> with TickerProviderStateMixin {
  bool _expanded = false;
  String? _busyId;
  bool _sending = false;
  late final AnimationController _holdCtrl;
  Timer? _holdTimer;
  bool _holdFired = false;

  /// Opened by an auto-assign pop (closes itself after [kFobPopIdle]).
  bool _popped = false;
  Timer? _idle;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    _holdCtrl = AnimationController(vsync: this, duration: kUndoHold);
    ref.listenManual(fobPopProvider, (_, next) {
      if (next != null) _tryPop();
    });
    ref.listenManual(alarmProvider, (_, _) => _tryPop());
    // The idle return to Kitchen (1.7.1) folds it away.
    ref.listenManual(fobCollapseProvider, (_, _) => _collapse());
    // One waiting from before this button was built (another screen).
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryPop());
  }

  @override
  void dispose() {
    _holdCtrl.dispose();
    _holdTimer?.cancel();
    _idle?.cancel();
    _retry?.cancel();
    super.dispose();
  }

  void _expand() => setState(() => _expanded = true);
  void _collapse() {
    _popped = false;
    _idle?.cancel();
    if (mounted) setState(() => _expanded = false);
  }

  /// Opens on the NEXT card for a pending auto-assign — unless the
  /// full-screen ring is up or a dialog / screen sits on top: then it looks
  /// again shortly.
  void _tryPop() {
    if (!mounted || ref.read(fobPopProvider) == null) return;
    final alarm = ref.read(alarmProvider);
    final route = ModalRoute.of(context);
    if ((alarm.ringing && alarm.visible) || (route != null && !route.isCurrent)) {
      _retry ??= Timer(_popRetry, () {
        _retry = null;
        _tryPop();
      });
      return;
    }
    ref.read(fobPopProvider.notifier).state = null;
    ref.read(floorProvider.notifier).chime();
    setState(() {
      _expanded = true;
      _popped = true;
    });
    _armIdle();
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(kFobPopIdle, () {
      if (mounted && _popped) _collapse();
    });
  }

  Future<void> _returned(Driver d) async {
    if (_busyId != null) return;
    setState(() => _busyId = d.id);
    try {
      await ref.read(floorProvider.notifier).driverReturned(d.id);
      HapticFeedback.selectionClick();
      if (mounted) {
        toast(context, '${d.name} is back — end of the queue (hold the round button to undo)', rightInset: _toastInset);
        // Auto-assign may have just given the next driver his run: stay
        // open on NEXT then.
        if (!_popped && ref.read(fobPopProvider) == null) _collapse();
      }
    } catch (e) {
      HapticFeedback.lightImpact();
      if (mounted) {
        if (e is AgentException && e.isConflict) {
          toast(context, '${d.name} is not out on a run', error: true, rightInset: _toastInset);
        } else {
          toastError(context, e, lead: 'Not saved', area: 'drivers', rightInset: _toastInset);
        }
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// The NEXT card's big button: send the next driver out — or, when the
  /// rules say something needs planning first, open that screen.
  Future<void> _onNext() async {
    if (_sending) return;
    final c = ProviderScope.containerOf(context, listen: false);
    final plan = planNext(c.read(floorProvider), c.read(autoPreviewProvider));
    final nav = c.read(homeNavProvider.notifier);
    switch (plan.go) {
      case NextGo.drivers:
        nav.go(HomeDestination.drivers);
        _collapse();
        return;
      case NextGo.deliveries:
        nav.go(HomeDestination.deliveries);
        _collapse();
        return;
      case NextGo.sendOut:
        break;
    }
    final d = plan.driver!;
    setState(() => _sending = true);
    try {
      final near = await nearbyCheck(c, d, plan.stops);
      if (mounted) setState(() => _sending = false);
      if (!mounted) return;
      if (near.redirect) {
        c.read(deliveryHighlightProvider.notifier).show(near.orderIds);
        nav.go(HomeDestination.deliveries);
        _collapse();
        if (near.reason.isNotEmpty) toast(context, '${near.reason} Plan it first, then SEND OUT.');
        return;
      }
      final sent = await sendOutDriver(
        context,
        d,
        toastInset: _toastInset,
        onSending: () => mounted ? setState(() => _sending = true) : null,
      );
      if (sent) _collapse();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _onRoundTap() {
    // Swallow the release-tap of a press that already triggered undo.
    final consumedByUndo = _holdFired;
    _holdFired = false;
    if (consumedByUndo) return;
    _collapse();
  }

  void _onHoldStart() {
    _holdFired = false;
    _holdCtrl.forward(from: 0);
    _holdTimer = Timer(kUndoHold, () async {
      _holdFired = true;
      final last = ref.read(lastReturnProvider);
      if (last == null || !last.undoable) return;
      final name = ref.read(floorProvider).drivers.where((d) => d.id == last.driverId).firstOrNull?.name ?? 'Driver';
      try {
        await ref.read(floorProvider.notifier).undoReturn(last.driverId);
        HapticFeedback.mediumImpact();
        if (mounted) toast(context, 'Undone — $name is out again', rightInset: _toastInset);
      } catch (e) {
        if (mounted) {
          toastError(context, e, lead: 'Could not undo', area: 'drivers', rightInset: _toastInset);
        }
      }
    });
  }

  void _onHoldEnd() {
    _holdTimer?.cancel();
    _holdCtrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final m = Motion.of(context, ref);
    final out = ref.watch(floorProvider.select((s) => s.driversOut));
    final last = ref.watch(lastReturnProvider);
    final canUndo = last != null && last.undoable;
    // Only built while open: the plan reads the whole floor.
    final plan = _expanded ? planNext(ref.watch(floorProvider), ref.watch(autoPreviewProvider)) : null;
    Duration d(int ms) => m.full ? m.scale(Duration(milliseconds: ms)) : m.fade;

    return Listener(
      // Any touch keeps an auto-assign pop open.
      onPointerDown: (_) {
        if (_popped) _armIdle();
      },
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          // Invisible backdrop: catches taps outside the button to collapse.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_expanded,
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _collapse),
            ),
          ),
          Positioned(
            right: QuiccSpace.xl,
            bottom: QuiccSpace.xl,
            top: QuiccSpace.xl,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: AnimatedSwitcher(
                    duration: d(280),
                    reverseDuration: d(180),
                    switchInCurve: m.full ? Curves.easeOutBack : Curves.linear,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.bottomRight,
                      children: [...previous, ?current],
                    ),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: m.full
                          ? SlideTransition(
                              position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(anim),
                              child: child,
                            )
                          : child,
                    ),
                    child: _expanded
                        ? SingleChildScrollView(
                            key: const ValueKey('fab-open'),
                            reverse: true,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  _NextCard(plan: plan!, sending: _sending, onPressed: _onNext),
                                  QuiccSpace.gapLg,
                                  if (out.isEmpty)
                                    const _Hint('No drivers out right now')
                                  else
                                    for (final d in out) ...[
                                      _DriverPill(
                                        driver: d,
                                        orders: ref.watch(floorProvider.select((s) => s.outWith(d.id).length)),
                                        busy: _busyId == d.id,
                                        onTap: () => _returned(d),
                                      ),
                                      if (d != out.last) QuiccSpace.gapSm,
                                    ],
                                ],
                              ),
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('fab-closed')),
                  ),
                ),
                AnimatedSwitcher(
                  duration: d(300),
                  reverseDuration: d(180),
                  switchInCurve: m.full ? Curves.easeOutBack : Curves.linear,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: Tween<double>(begin: m.full ? 0.7 : 1, end: 1).animate(anim),
                    alignment: Alignment.bottomRight,
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: _expanded
                      ? _CloseUndoButton(
                          key: const ValueKey('fab-round'),
                          canUndo: canUndo,
                          holdAnimation: _holdCtrl,
                          onTap: _onRoundTap,
                          onHoldStart: _onHoldStart,
                          onHoldEnd: _onHoldEnd,
                        )
                      : _RoundButton(
                          key: const ValueKey('fab-collapsed'),
                          size: 64,
                          outCount: out.length,
                          onTap: _expand,
                          semantics: out.isEmpty
                              ? 'Driver button. No drivers out'
                              : 'Driver button. ${out.length} driver${out.length == 1 ? '' : 's'} out',
                          child: const Icon(Icons.local_shipping_outlined, color: QuiccColors.brand900, size: 30),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Lavender circle button; [outCount] > 0 adds the "N out" badge on its
/// top-right (drivers out on a run — not the queue, not orders).
class _RoundButton extends StatelessWidget {
  final double size;
  final int outCount;
  final Widget child;
  final List<Widget> overlays;
  final VoidCallback onTap;
  final GestureTapDownCallback? onTapDown;
  final GestureTapUpCallback? onTapUp;
  final VoidCallback? onTapCancel;
  final String semantics;

  const _RoundButton({
    super.key,
    required this.size,
    required this.child,
    required this.onTap,
    required this.semantics,
    this.outCount = 0,
    this.overlays = const [],
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Material(
              color: QuiccColors.brand400,
              elevation: 6,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                onTapDown: onTapDown,
                onTapUp: onTapUp,
                onTapCancel: onTapCancel,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Center(child: child),
                ),
              ),
            ),
            ...overlays,
            if (outCount > 0)
              Positioned(
                top: -6,
                right: -10,
                child: IgnorePointer(
                  child: Container(
                    key: const ValueKey('fab-out-badge'),
                    padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.sm, vertical: 2),
                    decoration: BoxDecoration(
                      color: context.palette.bgCanvas,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: QuiccColors.brand400, width: 2),
                    ),
                    child: Text(
                      '$outCount out',
                      style: QuiccType.text(QuiccType.caption, weight: FontWeight.w700, color: QuiccColors.brand400),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The open state's round button: tap closes; hold 2 s undoes the last
/// return (armed only while there is one to undo — the ring fills as you hold).
class _CloseUndoButton extends StatelessWidget {
  final bool canUndo;
  final Animation<double> holdAnimation;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  const _CloseUndoButton({
    super.key,
    required this.canUndo,
    required this.holdAnimation,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  @override
  Widget build(BuildContext context) {
    const size = 80.0;
    const ringStroke = 8.0;
    return _RoundButton(
      size: size,
      onTap: onTap,
      semantics: 'Close${canUndo ? '. Hold to undo the last return' : ''}',
      onTapDown: canUndo ? (_) => onHoldStart() : null,
      onTapUp: canUndo ? (_) => onHoldEnd() : null,
      onTapCancel: canUndo ? onHoldEnd : null,
      overlays: [
        IgnorePointer(
          child: AnimatedBuilder(
            animation: holdAnimation,
            builder: (_, _) => SizedBox(
              width: size + ringStroke * 2,
              height: size + ringStroke * 2,
              child: CircularProgressIndicator(
                value: holdAnimation.value,
                strokeWidth: ringStroke,
                strokeCap: StrokeCap.round,
                backgroundColor: Colors.transparent,
                valueColor: const AlwaysStoppedAnimation(QuiccColors.brand900),
              ),
            ),
          ),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.close, color: QuiccColors.brand900, size: 28),
          if (canUndo)
            Text(
              'hold: undo',
              style: QuiccType.text(QuiccType.caption - 1, weight: FontWeight.w600, color: QuiccColors.brand900),
            ),
        ],
      ),
    );
  }
}

/// The NEXT section: the next driver, his tickets and the one big button.
class _NextCard extends StatelessWidget {
  final NextPlan plan;
  final bool sending;
  final VoidCallback onPressed;
  const _NextCard({required this.plan, required this.sending, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final d = plan.driver;
    final stops = plan.stops;
    final more = stops.length - _maxTickets;
    final (label, icon) = switch (plan.go) {
      NextGo.sendOut => ('SEND OUT', Icons.delivery_dining),
      NextGo.deliveries => ('OPEN DELIVERIES', Icons.arrow_forward),
      NextGo.drivers => ('OPEN DRIVERS', Icons.arrow_forward),
    };
    return ConstrainedBox(
      key: const ValueKey('next-card'),
      constraints: const BoxConstraints(maxWidth: _cardWidth, minWidth: _cardWidth),
      child: Material(
        color: p.bgElevated,
        elevation: 6,
        borderRadius: BorderRadius.circular(QuiccRadius.xl),
        child: Padding(
          padding: const EdgeInsets.all(QuiccSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'Next driver',
                    style: QuiccType.text(QuiccType.label, weight: FontWeight.w600, color: p.textMuted),
                  ),
                  const Spacer(),
                  const InfoButton(kDriverButtonInfo, size: 22),
                ],
              ),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: d?.name ?? 'Nobody free',
                      style: QuiccType.text(QuiccType.title, weight: FontWeight.w700, color: p.textPrimary),
                    ),
                    if (d != null)
                      TextSpan(
                        text: '  ${stops.length} order${stops.length == 1 ? '' : 's'}',
                        style: QuiccType.text(QuiccType.body, color: p.textSecondary),
                      ),
                  ],
                ),
                key: const ValueKey('next-driver'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (stops.isNotEmpty) ...[
                QuiccSpace.gapMd,
                for (final s in stops.take(_maxTickets)) _TicketLine(stop: s),
                if (more > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: QuiccSpace.xs),
                    child: Text(
                      '+ $more more',
                      style: QuiccType.text(QuiccType.label, color: p.textMuted),
                    ),
                  ),
              ],
              if (plan.reason != null) ...[
                QuiccSpace.gapMd,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, size: 20, color: QuiccColors.statusFiring),
                    QuiccSpace.gapSm,
                    Expanded(
                      child: Text(
                        plan.reason!,
                        key: const ValueKey('next-reason'),
                        style: QuiccType.text(QuiccType.label, color: p.textSecondary, height: 1.3),
                      ),
                    ),
                  ],
                ),
              ],
              QuiccSpace.gapLg,
              SizedBox(
                height: 64,
                child: FilledButton.icon(
                  key: const ValueKey('next-action'),
                  style: FilledButton.styleFrom(
                    backgroundColor: QuiccColors.brand400,
                    foregroundColor: QuiccColors.brand900,
                    textStyle: QuiccType.text(QuiccType.heading, weight: FontWeight.w700),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(QuiccRadius.lg)),
                  ),
                  onPressed: sending ? null : onPressed,
                  icon: sending
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : Icon(icon, size: 28),
                  label: Text(label),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One ticket on the NEXT card: kitchen #, street, ready / cooking (and
/// "AUTO" for a yellow suggestion that would ride along).
class _TicketLine extends StatelessWidget {
  final SendOutStop stop;
  const _TicketLine({required this.stop});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final o = stop.order;
    final ready = o.state == OrderState.ready;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: QuiccSpace.xs),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              orderNumber(o),
              maxLines: 1,
              style: QuiccType.number(QuiccType.heading, weight: FontWeight.w700, color: QuiccColors.brand400),
            ),
          ),
          Expanded(
            child: Text(
              streetOf(o),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: QuiccType.text(QuiccType.body, weight: FontWeight.w600, color: p.textPrimary),
            ),
          ),
          if (stop.suggested) ...[
            const _Tag('AUTO', color: QuiccColors.statusFiring),
            QuiccSpace.gapXs,
          ],
          _Tag(ready ? 'Ready' : 'Cooking', color: ready ? QuiccColors.statusPaid : QuiccColors.statusOpen),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag(this.text, {required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.sm, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(QuiccRadius.sm),
      border: Border.all(color: color.withValues(alpha: 0.7)),
    ),
    child: Text(text, style: QuiccType.text(QuiccType.caption, weight: FontWeight.w700, color: color)),
  );
}

/// One driver who is out: tap = "I have returned".
class _DriverPill extends StatelessWidget {
  final Driver driver;
  final int orders;
  final bool busy;
  final VoidCallback onTap;
  const _DriverPill({required this.driver, required this.orders, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.bgElevated,
      elevation: 4,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.xl, vertical: QuiccSpace.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(color: QuiccColors.brand400, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(
                  driver.name.isEmpty ? '?' : driver.name.characters.first.toUpperCase(),
                  style: QuiccType.text(QuiccType.label, weight: FontWeight.w700, color: QuiccColors.brand900),
                ),
              ),
              QuiccSpace.gapMd,
              Text(
                driver.name,
                style: QuiccType.text(QuiccType.heading - 2, weight: FontWeight.w600, color: p.textPrimary),
              ),
              QuiccSpace.gapMd,
              Text(
                busy ? 'saving…' : '$orders order${orders == 1 ? '' : 's'} · tap when back',
                style: QuiccType.text(QuiccType.caption, color: p.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.lg, vertical: QuiccSpace.md),
      decoration: BoxDecoration(
        color: p.bgElevated,
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        border: Border.all(color: p.borderSoft),
      ),
      child: Text(
        text,
        textAlign: TextAlign.right,
        style: QuiccType.text(QuiccType.body, color: p.textSecondary, height: 1.3),
      ),
    );
  }
}
