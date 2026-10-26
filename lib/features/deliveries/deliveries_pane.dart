import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/auto_preview.dart';
import '../../core/delivery_models.dart';
import '../../core/floor_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import '../home/home_nav.dart';
import '../maps/pool_map_screen.dart';
import '../maps/runs_map_pane.dart';
import '../order_detail/order_detail_screen.dart';
import 'came_back.dart';
import 'delivery_widgets.dart';
import 'lava_glow.dart';
import 'send_out.dart';

/// Keeps toasts clear of the bottom-right driver button.
const double _toastInset = kSendOutToastInset;

/// Room under the left column's last card so it scrolls clear of the select
/// bar.
const double _listClearance = 96;

/// The most of the left column the "Came back" section takes; the Unassigned
/// list keeps the rest (and both scroll on their own).
const double _cameBackShare = 0.45;

/// The send-out bar stops short of the collapsed driver button (64 px, 24 px
/// from the screen's right edge; the pane itself pads 24).
const double _fabSlot = 80;

/// Deliveries (1.4.0, reworked 1.6.0): unassigned deliveries on the left; on
/// the right one box per available driver in queue order (NEXT on top), each
/// with the pool staff build up by drag and drop (long-press) or Select ✓ +
/// tap. Below the boxes: drivers out, with I HAVE RETURNED. Drivers leave in
/// queue order, so there is one SEND OUT — the bar pinned under the pools,
/// for the NEXT driver ([NextSendOutBar]). AUTO (with its lava-lamp glow
/// while there is something to plan) suggests runs for every available
/// driver as a yellow preview; nothing is saved until CONFIRM (or SEND OUT
/// with the next driver's yellow stops showing). A single tap on any
/// delivery opens it. Rows in [deliveryHighlightProvider] pulse yellow until
/// you tap, drag, move or send something. Under Unassigned, below a rule,
/// "Came back · N" (1.7.1) holds the deliveries a driver brought back
/// ([CameBackSection]): not draggable or selectable, held to go to
/// Unassigned.
class DeliveriesPane extends ConsumerStatefulWidget {
  const DeliveriesPane({super.key});

  @override
  ConsumerState<DeliveriesPane> createState() => _DeliveriesPaneState();
}

class _DeliveriesPaneState extends ConsumerState<DeliveriesPane> {
  bool _selectMode = false;
  final Set<String> _selected = {};
  final Set<String> _sending = {};
  final Set<String> _returning = {};
  bool _autoBusy = false;
  bool _confirmBusy = false;

  /// Bumped per AUTO preview, so its suggestions slide in once.
  int _previewSeq = 0;

  FloorController get _floor => ref.read(floorProvider.notifier);
  AutoPreviewController get _preview => ref.read(autoPreviewProvider.notifier);

  void _toast(String msg, {bool error = false}) {
    if (mounted) toast(context, msg, error: error, rightInset: _toastInset);
  }

  void _open(StoredOrder o) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => OrderDetailScreen(orderId: o.id, initial: o)));

  void _toggle(String id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  void _tapOrder(StoredOrder o) {
    _clearHighlight();
    _selectMode ? _toggle(o.id) : _open(o);
  }

  /// The glow asks for attention until staff act on the deliveries.
  void _clearHighlight() {
    if (ref.read(deliveryHighlightProvider).isNotEmpty) ref.read(deliveryHighlightProvider.notifier).clear();
  }

  void _endSelect() => setState(() {
    _selectMode = false;
    _selected.clear();
  });

  // --- moving deliveries -------------------------------------------------------

  /// Moves [ids] into [driverId]'s pool (null = back to unassigned). Yellow
  /// suggestions among them leave the preview first; ones already where they
  /// are going are skipped.
  Future<void> _move(List<String> ids, String? driverId) async {
    if (ids.isEmpty) return;
    _clearHighlight();
    final fs = ref.read(floorProvider);
    final suggested = ref.read(autoPreviewProvider)?.suggestedIds ?? const <String>{};
    final yellow = ids.where(suggested.contains).toList();
    if (yellow.isNotEmpty) _preview.forget(yellow);
    final real = ids.where((id) {
      final o = fs.orders[id];
      if (o == null) return false;
      final pool = o.status.poolDriverId;
      return driverId == null ? pool != null : pool != driverId;
    }).toList();
    setState(() {
      _selected.removeAll(ids);
      if (_selected.isEmpty) _selectMode = false;
    });
    if (real.isEmpty) return;
    try {
      await _floor.poolOrders(real, driverId);
    } catch (e) {
      if (!mounted) return;
      final name = driverId == null ? '' : _driverName(driverId);
      final msg = switch (e) {
        AgentException(code: 'driver_not_available') =>
          "$name isn't available any more (clocked out or out on a run) — list refreshed.",
        AgentException(code: 'driver_not_found') => 'That driver was removed — list refreshed.',
        AgentException(code: 'invalid_state') => 'That order was sent out or cancelled meanwhile — list refreshed.',
        AgentException(code: 'not_found') => 'That order is gone — list refreshed.',
        AgentException(code: kPoolsUnsupported) => 'This Pi needs an update for driver pools.',
        AgentException(code: kCameBack) => kCameBackFirst,
        _ => null,
      };
      msg == null
          ? toastError(context, e, lead: 'Not moved', area: 'deliveries', rightInset: _toastInset)
          : _toast(msg, error: true);
    }
  }

  String _driverName(String id) =>
      ref.read(floorProvider).drivers.where((d) => d.id == id).firstOrNull?.name ?? 'That driver';

  // --- send out ------------------------------------------------------------------

  Future<void> _sendOut(Driver d) async {
    try {
      await sendOutDriver(
        context,
        d,
        toastInset: _toastInset,
        onSending: () => mounted ? setState(() => _sending.add(d.id)) : null,
      );
    } finally {
      if (mounted) setState(() => _sending.remove(d.id));
    }
  }

  Future<void> _returned(Driver d) async {
    setState(() => _returning.add(d.id));
    try {
      await _floor.driverReturned(d.id);
      _toast('${d.name} is back — moved to the end of the queue');
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'invalid_state') => "${d.name} isn't out any more — already marked returned.",
        AgentException(isNotFound: true) => '${d.name} was removed from the roster.',
        _ => null,
      };
      msg == null
          ? toastError(
              context,
              e,
              lead: 'Could not mark ${d.name} returned',
              area: 'deliveries',
              rightInset: _toastInset,
            )
          : _toast(msg, error: true);
    } finally {
      if (mounted) setState(() => _returning.remove(d.id));
    }
  }

  // --- AUTO ----------------------------------------------------------------------

  Future<void> _auto() async {
    _clearHighlight();
    setState(() => _autoBusy = true);
    try {
      final plan = await _floor.autoPlan();
      if (!mounted) return;
      if (_preview.show(plan)) {
        setState(() => _previewSeq++);
      } else {
        _toast(
          plan.unassigned.isEmpty
              ? 'Nothing for AUTO to suggest — no delivery is ready or nearly ready.'
              : 'AUTO found no run to suggest — ${plan.unassigned.length} stay unassigned.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: kNoDrivers) => 'No driver is free — clock one in on the Drivers tab.',
        AgentException(code: kPoolsUnsupported) => 'This Pi needs an update for AUTO.',
        _ => null,
      };
      msg == null
          ? toastError(context, e, lead: "AUTO didn't work", area: 'deliveries', rightInset: _toastInset)
          : _toast(msg, error: true);
    } finally {
      if (mounted) setState(() => _autoBusy = false);
    }
  }

  Future<void> _confirmPreview() async {
    final p = ref.read(autoPreviewProvider);
    if (p == null) return;
    // Cleared first: the pools it creates must not read as "the floor
    // changed under the preview".
    _preview.clear();
    setState(() => _confirmBusy = true);
    final orders = ref.read(floorProvider).orders;
    String num(String id) => orders[id] == null ? '#?' : orderNumber(orders[id]!);
    try {
      // An edited preview confirms only what is still showing (to the
      // planned drivers); confirming it all would bring removed stops back.
      final r = await _floor.confirmPlan(p.planId, orderIds: p.edited ? p.suggestedIds.toList() : null);
      final skipped = r.skipped.map((s) => num(s.orderId)).toList();
      _toast(
        'Applied ${r.applied.length}'
        '${skipped.isEmpty ? '' : ' · skipped ${numbersList(skipped)} (changed meanwhile)'}',
      );
    } catch (e) {
      if (!mounted) return;
      e is AgentException && e.code == kPoolsUnsupported
          ? _toast('This Pi needs an update for AUTO.', error: true)
          : toastError(context, e, lead: 'Suggestion not applied', area: 'deliveries', rightInset: _toastInset);
    } finally {
      if (mounted) setState(() => _confirmBusy = false);
    }
  }

  /// [orderIds] in the box's driving order (pooled + yellow).
  void _openPoolMap(Driver d, List<String> orderIds, Set<String> yellow) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PoolMapScreen(
          driverId: d.id,
          driverName: d.name,
          orderIds: orderIds,
          yellowIds: yellow,
        ),
      ),
    );
  }

  // --- build ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(autoPreviewDroppedProvider, (_, _) {
      _toast('The floor changed — AUTO suggestion cleared. Tap AUTO again.');
    });
    final fs = ref.watch(floorProvider);
    final preview = ref.watch(autoPreviewProvider);
    final highlight = ref.watch(deliveryHighlightProvider);
    final suggested = preview?.suggestedIds ?? const <String>{};
    final left = fs.unassignedDeliveries.where((o) => !suggested.contains(o.id)).toList();
    final back = fs.cameBackDeliveries;
    // AUTO kept these for a driver on his way back (2.2.1).
    final held = {
      for (final u in preview?.plan.unassigned ?? const <PlanLeftover>[])
        if (u.reason == 'held_for_returning_driver' && u.heldFor != null) u.orderId: u.heldFor!,
    };
    final drivers = fs.availableDrivers;
    final pools = {for (final d in drivers) d.id: fs.poolFor(d.id)};
    final runs = _runs(fs);
    final target = fs.floor?.deliveryTargetMinutes ?? kDefaultDeliveryTargetMinutes;

    // Selection follows the floor: anything that left the screen drops out.
    final visible = {
      for (final o in left) o.id,
      for (final p in pools.values) ...p.map((o) => o.id),
      ...suggested,
    };
    _selected.retainAll(visible);
    final pooledCount = pools.values.fold<int>(0, (n, p) => n + p.length);

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(QuiccSpace.pane, QuiccSpace.pane, QuiccSpace.pane, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PaneHeader(
                title: 'Deliveries',
                subtitle:
                    '${left.length} unassigned · $pooledCount in pools · ${runs.length} out'
                    '${back.isEmpty ? '' : ' · ${back.length} came back'}',
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: _leftColumn(context, left, back, target, fs, highlight, held)),
                    QuiccSpace.gapLg,
                    Expanded(flex: 6, child: _rightColumn(context, fs, drivers, pools, preview, runs)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_selectMode)
          Positioned(left: QuiccSpace.pane, right: _toastInset, bottom: QuiccSpace.lg, child: _selectBar(context)),
      ],
    );
  }

  Widget _leftColumn(
    BuildContext context,
    List<StoredOrder> left,
    List<StoredOrder> back,
    int target,
    FloorState fs,
    Set<String> highlight,
    Map<String, HeldFor> held,
  ) {
    final moveHere = _selectMode && _selected.isNotEmpty;
    // AUTO glows while it has something to plan: a delivery waiting, a free
    // driver and no suggestion already up.
    final autoInviting =
        left.isNotEmpty && fs.availableDrivers.isNotEmpty && ref.watch(autoPreviewProvider) == null && !_autoBusy;
    return DragTarget<DeliveryDrag>(
      onWillAcceptWithDetails: (d) => d.data.fromDriver != null || d.data.suggestion,
      onAcceptWithDetails: (d) => _move(d.data.ids, null),
      builder: (context, candidates, _) {
        final hover = candidates.isNotEmpty;
        return GestureDetector(
          key: const ValueKey('unassigned-column'),
          behavior: HitTestBehavior.translucent,
          onTap: moveHere ? () => _move(_selected.toList(), null) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: hover ? QuiccColors.brand400.withValues(alpha: 0.08) : Colors.transparent,
              borderRadius: BorderRadius.circular(QuiccRadius.lg),
              border: Border.all(
                color: hover ? QuiccColors.brand400 : (moveHere ? context.palette.borderSoft : Colors.transparent),
                width: 2,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, box) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(QuiccSpace.sm, QuiccSpace.xs, QuiccSpace.xs, QuiccSpace.sm),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Unassigned · ${left.length}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700),
                          ),
                        ),
                        LavaGlow(
                          active: autoInviting,
                          child: _HeaderButton(
                            key: const ValueKey('auto'),
                            icon: Icons.auto_awesome,
                            label: 'AUTO',
                            busy: _autoBusy,
                            glowing: autoInviting,
                            onTap: _autoBusy ? null : _auto,
                          ),
                        ),
                        QuiccSpace.gapMd,
                        _HeaderButton(
                          key: const ValueKey('select'),
                          icon: _selectMode ? Icons.check_box : Icons.check_box_outlined,
                          label: 'Select',
                          active: _selectMode,
                          onTap: () => _selectMode ? _endSelect() : setState(() => _selectMode = true),
                        ),
                      ],
                    ),
                  ),
                  if (moveHere)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(QuiccSpace.sm, 0, QuiccSpace.sm, QuiccSpace.sm),
                      child: Text(
                        'Tap here to take the selected out of their pools',
                        style: QuiccType.text(QuiccType.label, color: context.palette.textMuted),
                      ),
                    ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () => _floor.refresh(),
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: _listClearance),
                        children: [
                          if (left.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: QuiccSpace.xl, horizontal: QuiccSpace.sm),
                              child: Text(
                                'No deliveries waiting for a driver.',
                                style: QuiccType.text(QuiccType.body, color: context.palette.textMuted),
                              ),
                            ),
                          for (final o in left)
                            DeliveryDraggable(
                              key: ValueKey('row-${o.id}'),
                              data: _dragData(o, fromDriver: null),
                              onDragStarted: _clearHighlight,
                              child: UnassignedRow(
                                order: o,
                                selectMode: _selectMode,
                                selected: _selected.contains(o.id),
                                highlight: highlight.contains(o.id),
                                targetMinutes: target,
                                heldFor: held[o.id],
                                onTap: () => _tapOrder(o),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // Below the rule, never in the way of the list above: it
                  // takes what it needs up to [_cameBackShare] and scrolls.
                  if (back.isNotEmpty)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: box.maxHeight * _cameBackShare),
                      child: CameBackSection(orders: back),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The drag carries the whole selection when the dragged one is selected.
  DeliveryDrag _dragData(StoredOrder o, {required String? fromDriver, bool suggestion = false}) {
    final orders = ref.read(floorProvider).orders;
    final ids = (_selectMode && _selected.contains(o.id)) ? _selected.toList() : [o.id];
    return DeliveryDrag(
      ids: ids,
      fromDriver: fromDriver,
      suggestion: suggestion,
      numbers: [for (final id in ids) orders[id]?.displayNumber ?? '?'],
    );
  }

  Widget _rightColumn(
    BuildContext context,
    FloorState fs,
    List<Driver> drivers,
    Map<String, List<StoredOrder>> pools,
    AutoPreview? preview,
    List<_Run> runs,
  ) {
    final next = drivers.isEmpty ? null : drivers.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
            children: [
              if (preview != null) _previewBar(context, preview),
              if (drivers.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(QuiccSpace.lg),
                    child: Row(
                      children: [
                        Icon(Icons.person_off_outlined, color: context.palette.textMuted, size: 32),
                        QuiccSpace.gapMd,
                        Expanded(
                          child: Text(
                            fs.anyDriverOnShift
                                ? 'Every clocked-in driver is out — wait for one to return, or clock another in on the Drivers tab.'
                                : 'No driver clocked in — clock one in on the Drivers tab.',
                            style: QuiccType.text(QuiccType.body, color: context.palette.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              for (var i = 0; i < drivers.length; i++)
                _driverBox(context, fs, drivers[i], i == 0, pools[drivers[i].id] ?? const [], preview),
              QuiccSpace.gapLg,
              Eyebrow('Out · ${runs.length}'),
              QuiccSpace.gapSm,
              if (runs.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: QuiccSpace.sm),
                  child: Text(
                    'No drivers are out.',
                    style: QuiccType.text(QuiccType.body, color: context.palette.textMuted),
                  ),
                ),
              for (final run in runs)
                OutRunCard(
                  key: ValueKey('out-${run.driver?.id ?? run.name}'),
                  name: run.name,
                  outAt: run.outAt,
                  orders: run.orders,
                  color: driverColor(fs.drivers, run.driver?.id ?? ''),
                  busy: run.driver != null && _returning.contains(run.driver!.id),
                  onReturned: run.driver == null ? null : () => _returned(run.driver!),
                  onOpen: _open,
                ),
            ],
          ),
        ),
        if (next != null)
          Padding(
            padding: const EdgeInsets.only(right: _fabSlot, bottom: QuiccSpace.xl),
            child: NextSendOutBar(
              driver: next,
              stops: sendOutStops(fs, preview, next.id).length,
              sending: _sending.contains(next.id),
              onPressed: () => _sendOut(next),
            ),
          ),
      ],
    );
  }

  Widget _driverBox(
    BuildContext context,
    FloorState fs,
    Driver d,
    bool next,
    List<StoredOrder> pooled,
    AutoPreview? preview,
  ) {
    final yellowIds = preview?.suggestedFor(d.id) ?? const <String>[];
    final yellow = [
      for (final id in yellowIds)
        if (fs.orders[id] != null) fs.orders[id]!,
    ];
    final stops = pooled.length + yellow.length;
    final tips = [...pooled, ...yellow].fold<int>(0, (n, o) => n + o.order.money.tipCents);
    // One list in driving order: the pool by pool_seq; with an AUTO preview
    // up, pooled + yellow stops follow the plan run's order (stops the run
    // doesn't name keep their place after it).
    final chips = [for (final o in pooled) (order: o, yellow: false), for (final o in yellow) (order: o, yellow: true)];
    final run = preview?.plan.runs.where((r) => r.driverId == d.id).firstOrNull;
    if (run != null && yellow.isNotEmpty) {
      int rank(int i) {
        final r = run.orderIds.indexOf(chips[i].order.id);
        return r < 0 ? run.orderIds.length + i : r;
      }

      final idx = List<int>.generate(chips.length, (i) => i)..sort((x, y) => rank(x).compareTo(rank(y)));
      final sorted = [for (final i in idx) chips[i]];
      chips
        ..clear()
        ..addAll(sorted);
    }
    var yellowIndex = 0;
    final moveHere = _selectMode && _selected.isNotEmpty;

    return DragTarget<DeliveryDrag>(
      key: ValueKey('driver-${d.id}'),
      onWillAcceptWithDetails: (x) => x.data.suggestion || x.data.fromDriver != d.id,
      onAcceptWithDetails: (x) => _move(x.data.ids, d.id),
      builder: (context, candidates, _) {
        final hover = candidates.isNotEmpty;
        return Card(
          margin: const EdgeInsets.only(bottom: QuiccSpace.md),
          color: hover ? QuiccColors.brand400.withValues(alpha: 0.10) : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(QuiccRadius.lg),
            side: BorderSide(
              color: hover ? QuiccColors.brand400 : (moveHere ? QuiccColors.brand200 : context.palette.borderSoft),
              width: hover || moveHere ? 2 : 1,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(QuiccRadius.lg),
            onTap: moveHere ? () => _move(_selected.toList(), d.id) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(QuiccSpace.md, QuiccSpace.sm, QuiccSpace.md, QuiccSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (next) ...[const NextBadge(), QuiccSpace.gapSm],
                      Expanded(
                        child: InkWell(
                          key: ValueKey('driver-header-${d.id}'),
                          borderRadius: BorderRadius.circular(QuiccRadius.sm),
                          onTap: moveHere ? () => _move(_selected.toList(), d.id) : () => _openPoolMap(d, [for (final c in chips) c.order.id], yellowIds.toSet()),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: QuiccSpace.sm),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: d.name,
                                    style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700),
                                  ),
                                  TextSpan(
                                    text: ' · $stops stop${stops == 1 ? '' : 's'}${tips > 0 ? ' · tips ${money(tips)}' : ''}',
                                    style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Show the run on the map',
                        icon: const Icon(Icons.map_outlined, color: QuiccColors.brand400),
                        onPressed: stops == 0 ? null : () => _openPoolMap(d, [for (final c in chips) c.order.id], yellowIds.toSet()),
                      ),
                    ],
                  ),
                  QuiccSpace.gapXs,
                  if (stops == 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: QuiccSpace.md),
                      child: Text(
                        moveHere ? 'Tap to move the selected here' : 'Drag deliveries here',
                        style: QuiccType.text(QuiccType.body, color: context.palette.textMuted),
                      ),
                    ),
                  for (final c in chips)
                    if (!c.yellow)
                      DeliveryDraggable(
                        key: ValueKey('chip-${c.order.id}'),
                        data: _dragData(c.order, fromDriver: d.id),
                        onDragStarted: _clearHighlight,
                        child: PoolStopChip(
                          order: c.order,
                          selectMode: _selectMode,
                          selected: _selected.contains(c.order.id),
                          onTap: () => _tapOrder(c.order),
                          onRemove: () => _move([c.order.id], null),
                        ),
                      )
                    else
                      SlideIn(
                        key: ValueKey('slide-$_previewSeq-${c.order.id}'),
                        index: yellowIndex++,
                        child: DeliveryDraggable(
                          key: ValueKey('yellow-${c.order.id}'),
                          data: _dragData(c.order, fromDriver: d.id, suggestion: true),
                          child: PoolStopChip(
                            order: c.order,
                            yellow: true,
                            selectMode: _selectMode,
                            selected: _selected.contains(c.order.id),
                            onTap: () => _tapOrder(c.order),
                            onRemove: () => _preview.forget([c.order.id]),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _previewBar(BuildContext context, AutoPreview p) {
    final leftovers = p.plan.unassigned.length;
    return Container(
      key: const ValueKey('auto-preview-bar'),
      margin: const EdgeInsets.only(bottom: QuiccSpace.md),
      padding: const EdgeInsets.fromLTRB(QuiccSpace.lg, QuiccSpace.md, QuiccSpace.md, QuiccSpace.md),
      decoration: BoxDecoration(
        color: QuiccColors.statusFiring.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        border: Border.all(color: QuiccColors.statusFiring, width: 2),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, color: QuiccColors.statusFiring),
          QuiccSpace.gapMd,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AUTO suggests ${p.count} · not saved yet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: QuiccType.text(QuiccType.body, weight: FontWeight.w700),
                ),
                Wrap(
                  spacing: QuiccSpace.sm,
                  children: [
                    if (p.plan.estimated)
                      Text(
                        'estimated (offline)',
                        style: QuiccType.text(QuiccType.caption, weight: FontWeight.w600, color: QuiccColors.statusFiring),
                      ),
                    if (leftovers > 0)
                      Text(
                        '$leftovers stay unassigned',
                        style: QuiccType.text(QuiccType.caption, color: context.palette.textSecondary),
                      ),
                  ],
                ),
              ],
            ),
          ),
          TextButton(onPressed: _confirmBusy ? null : _preview.clear, child: const Text('Clear')),
          QuiccSpace.gapXs,
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: QuiccColors.statusFiring,
              foregroundColor: QuiccColors.brand900,
              padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.lg, vertical: QuiccSpace.md),
            ),
            onPressed: _confirmBusy ? null : _confirmPreview,
            child: const Text('CONFIRM'),
          ),
        ],
      ),
    );
  }

  Widget _selectBar(BuildContext context) {
    final n = _selected.length;
    return Material(
      key: const ValueKey('select-bar'),
      elevation: 6,
      color: context.palette.bgElevated,
      borderRadius: BorderRadius.circular(QuiccRadius.lg),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(QuiccSpace.lg, QuiccSpace.sm, QuiccSpace.sm, QuiccSpace.sm),
        child: Row(
          children: [
            Text('$n selected', style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700)),
            QuiccSpace.gapMd,
            Expanded(
              child: Text(
                n == 0 ? 'Tap deliveries to pick them' : 'Tap a driver to move them there, or the left side to unassign',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
              ),
            ),
            TextButton(onPressed: _endSelect, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }

  /// One entry per driver who is out (roster status) or has on_delivery
  /// orders — including orders whose driver has since been removed.
  List<_Run> _runs(FloorState fs) {
    final byDriver = <String, List<StoredOrder>>{};
    for (final o in fs.onDelivery) {
      byDriver.putIfAbsent(o.status.driverId ?? '', () => []).add(o);
    }
    final runs = <_Run>[];
    for (final d in fs.drivers) {
      final orders = byDriver.remove(d.id) ?? const <StoredOrder>[];
      if (d.isOut || orders.isNotEmpty) {
        runs.add(_Run(driver: d, name: d.name, orders: inStopOrder(orders, d)));
      }
    }
    byDriver.forEach((id, orders) {
      runs.add(_Run(driver: null, name: orders.first.status.driverName ?? 'Unknown driver', orders: orders));
    });
    return runs;
  }
}

class _Run {
  final Driver? driver;
  final String name;
  final List<StoredOrder> orders;
  const _Run({required this.driver, required this.name, required this.orders});

  DateTime? get outAt {
    DateTime? first;
    for (final o in orders) {
      final t = o.status.outAt;
      if (t != null && (first == null || t.isBefore(first))) first = t;
    }
    return first;
  }
}

/// AUTO / SELECT in the left column's header. [glowing] = AUTO sits on its
/// lava lamp: an opaque face (so the label stays crisp over the blobs) and
/// an amber edge.
class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool busy;
  final bool glowing;
  final VoidCallback? onTap;
  const _HeaderButton({
    super.key,
    required this.icon,
    required this.label,
    this.active = false,
    this.busy = false,
    this.glowing = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.md),
        backgroundColor: active
            ? QuiccColors.brand400.withValues(alpha: 0.18)
            : (glowing ? context.palette.bgSurface.withValues(alpha: 0.88) : null),
        // Amber on the dark face; a deep amber on the light one (contrast).
        foregroundColor: glowing
            ? (Theme.of(context).brightness == Brightness.dark ? QuiccColors.statusFiring : const Color(0xFFB45309))
            : null,
        side: BorderSide(
          color: active
              ? QuiccColors.brand400
              : (glowing ? QuiccColors.statusFiring.withValues(alpha: 0.8) : context.palette.borderSoft),
        ),
      ),
      onPressed: onTap,
      icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon),
      label: Text(label),
    ),
  );
}
