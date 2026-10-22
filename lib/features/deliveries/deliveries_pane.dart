import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/auto_preview.dart';
import '../../core/floor_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../maps/pool_map_screen.dart';
import '../order_detail/order_detail_screen.dart';
import 'delivery_widgets.dart';

/// Keeps toasts clear of the bottom-right driver button.
const double _toastInset = 160;

/// Room under each column's last card so it scrolls clear of the driver
/// button (104 px + its ring, 24 px from the edge).
const double _fabClearance = 170;

/// Deliveries (1.4.0): unassigned deliveries on the left; on the right one
/// box per available driver in queue order (NEXT on top), each with the pool
/// staff build up by drag and drop (long-press) or Select ✓ + tap, and SEND
/// OUT. Below the boxes: drivers out, with I HAVE RETURNED. AUTO suggests
/// runs for every available driver as a yellow preview; nothing is saved
/// until CONFIRM (or Send Out with the yellow stops showing). A single tap
/// on any delivery opens it.
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

  void _tapOrder(StoredOrder o) => _selectMode ? _toggle(o.id) : _open(o);

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

  Future<bool> _confirmCooking(List<String> numbers, String driver) {
    final one = numbers.length == 1;
    return confirmDialog(
      context,
      title: "${numbersList(numbers)} ${one ? "isn't" : "aren't"} marked ready — send anyway?",
      message: 'SEND ANYWAY marks ${one ? 'it' : 'them'} ready and sends ${one ? 'it' : 'them'} out with $driver.',
      confirm: 'SEND ANYWAY',
    );
  }

  Future<void> _sendOut(Driver d) async {
    final fs = ref.read(floorProvider);
    final preview = ref.read(autoPreviewProvider);
    final yellowIds = preview?.suggestedFor(d.id) ?? const <String>[];
    final all = [
      ...fs.poolFor(d.id),
      for (final id in yellowIds)
        if (fs.orders[id] != null) fs.orders[id]!,
    ];
    if (all.isEmpty) return;
    var markReady = false;
    final cooking = all.where((o) => o.state != OrderState.ready).toList();
    if (cooking.isNotEmpty) {
      if (!await _confirmCooking(cooking.map(orderNumber).toList(), d.name)) return;
      markReady = true;
    }
    if (!mounted) return;
    setState(() => _sending.add(d.id));
    // The yellow stops leave the preview while they go out, so the send's own
    // echo isn't taken for someone else's change.
    final taken = yellowIds.isEmpty ? const <String>[] : _preview.takeRun(d.id);
    try {
      while (true) {
        try {
          final out = await _floor.sendOut(
            d.id,
            markReady: markReady,
            includeOrderIds: taken.isEmpty ? null : taken,
            planId: taken.isEmpty ? null : preview?.planId,
          );
          _toast('${out.length} order${out.length == 1 ? '' : 's'} out with ${d.name}');
          return;
        } on NotReadyException catch (e) {
          // The Pi knows better: something we thought ready isn't.
          if (markReady || !mounted) rethrow;
          final now = ref.read(floorProvider).orders;
          final numbers = [for (final id in e.orderIds) now[id] == null ? '#?' : orderNumber(now[id]!)];
          if (!await _confirmCooking(numbers, d.name)) {
            if (preview != null) _preview.restoreRun(preview, d.id, taken);
            return;
          }
          markReady = true;
        }
      }
    } catch (e) {
      if (preview != null) _preview.restoreRun(preview, d.id, taken);
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'driver_not_available') =>
          "${d.name} isn't available — clocked out or already out. List refreshed.",
        AgentException(code: 'driver_not_found') => '${d.name} was removed — list refreshed.',
        AgentException(code: 'bad_request') => "${d.name}'s pool is empty now — list refreshed.",
        AgentException(code: 'invalid_state') || AgentException(code: 'not_ready') =>
          "Something in ${d.name}'s pool changed — list refreshed.",
        AgentException(code: kPoolsUnsupported) => 'This Pi needs an update for driver pools.',
        _ => null,
      };
      msg == null
          ? toastError(context, e, lead: 'Not sent out', area: 'deliveries', rightInset: _toastInset)
          : _toast(msg, error: true);
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
    final suggested = preview?.suggestedIds ?? const <String>{};
    final left = fs.unassignedDeliveries.where((o) => !suggested.contains(o.id)).toList();
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
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PaneHeader(
                title: 'Deliveries',
                subtitle: '${left.length} unassigned · $pooledCount in pools · ${runs.length} out',
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: _leftColumn(context, left, target, fs)),
                    const SizedBox(width: 16),
                    Expanded(flex: 6, child: _rightColumn(context, fs, drivers, pools, preview, runs)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_selectMode)
          Positioned(left: 24, right: _toastInset, bottom: 16, child: _selectBar(context)),
      ],
    );
  }

  Widget _leftColumn(BuildContext context, List<StoredOrder> left, int target, FloorState fs) {
    final moveHere = _selectMode && _selected.isNotEmpty;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 4, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Unassigned · ${left.length}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                        ),
                      ),
                      _HeaderButton(
                        key: const ValueKey('auto'),
                        icon: Icons.auto_awesome,
                        label: 'AUTO',
                        busy: _autoBusy,
                        onTap: _autoBusy ? null : _auto,
                      ),
                      const SizedBox(width: 6),
                      _HeaderButton(
                        key: const ValueKey('select'),
                        icon: _selectMode ? Icons.check_box : Icons.check_box_outlined,
                        label: 'SELECT',
                        active: _selectMode,
                        onTap: () => _selectMode ? _endSelect() : setState(() => _selectMode = true),
                      ),
                    ],
                  ),
                ),
                if (moveHere)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                    child: Text(
                      'Tap here to take the selected out of their pools',
                      style: TextStyle(color: context.palette.textMuted, fontSize: 13),
                    ),
                  ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _floor.refresh(),
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: _fabClearance),
                      children: [
                        if (left.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                            child: Text(
                              'No deliveries waiting for a driver.',
                              style: TextStyle(color: context.palette.textMuted),
                            ),
                          ),
                        for (final o in left)
                          DeliveryDraggable(
                            key: ValueKey('row-${o.id}'),
                            data: _dragData(o, fromDriver: null),
                            child: UnassignedRow(
                              order: o,
                              selectMode: _selectMode,
                              selected: _selected.contains(o.id),
                              targetMinutes: target,
                              onTap: () => _tapOrder(o),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
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
    return ListView(
      padding: const EdgeInsets.only(bottom: _fabClearance),
      children: [
        if (preview != null) _previewBar(context, preview),
        if (drivers.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(Icons.person_off_outlined, color: context.palette.textMuted, size: 32),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      fs.anyDriverOnShift
                          ? 'Every clocked-in driver is out — wait for one to return, or clock another in on the Drivers tab.'
                          : 'No driver clocked in — clock one in on the Drivers tab.',
                      style: TextStyle(color: context.palette.textSecondary, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
        for (var i = 0; i < drivers.length; i++)
          _driverBox(context, fs, drivers[i], i == 0, pools[drivers[i].id] ?? const [], preview),
        const SizedBox(height: 16),
        Eyebrow('Out · ${runs.length}'),
        const SizedBox(height: 8),
        if (runs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('No drivers are out.', style: TextStyle(color: context.palette.textMuted)),
          ),
        for (final run in runs)
          OutRunCard(
            key: ValueKey('out-${run.driver?.id ?? run.name}'),
            name: run.name,
            outAt: run.outAt,
            orders: run.orders,
            busy: run.driver != null && _returning.contains(run.driver!.id),
            onReturned: run.driver == null ? null : () => _returned(run.driver!),
            onOpen: _open,
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
    final sending = _sending.contains(d.id);
    final moveHere = _selectMode && _selected.isNotEmpty;

    return DragTarget<DeliveryDrag>(
      key: ValueKey('driver-${d.id}'),
      onWillAcceptWithDetails: (x) => x.data.suggestion || x.data.fromDriver != d.id,
      onAcceptWithDetails: (x) => _move(x.data.ids, d.id),
      builder: (context, candidates, _) {
        final hover = candidates.isNotEmpty;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
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
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (next) ...[const NextBadge(), const SizedBox(width: 8)],
                      Expanded(
                        child: InkWell(
                          key: ValueKey('driver-header-${d.id}'),
                          borderRadius: BorderRadius.circular(QuiccRadius.sm),
                          onTap: moveHere ? () => _move(_selected.toList(), d.id) : () => _openPoolMap(d, [for (final c in chips) c.order.id], yellowIds.toSet()),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: d.name,
                                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                                  ),
                                  TextSpan(
                                    text: ' · $stops stop${stops == 1 ? '' : 's'}${tips > 0 ? ' · tips ${money(tips)}' : ''}',
                                    style: TextStyle(color: context.palette.textSecondary, fontSize: 15),
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
                  const SizedBox(height: 4),
                  if (stops == 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        moveHere ? 'Tap to move the selected here' : 'Drag deliveries here',
                        style: TextStyle(color: context.palette.textMuted),
                      ),
                    ),
                  for (final c in chips)
                    if (!c.yellow)
                      DeliveryDraggable(
                        key: ValueKey('chip-${c.order.id}'),
                        data: _dragData(c.order, fromDriver: d.id),
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
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        key: ValueKey('send-${d.id}'),
                        onPressed: (stops == 0 || sending) ? null : () => _sendOut(d),
                        icon: sending
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.delivery_dining),
                        label: const Text('SEND OUT'),
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
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: QuiccColors.statusFiring.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        border: Border.all(color: QuiccColors.statusFiring, width: 2),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, color: QuiccColors.statusFiring),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AUTO suggests ${p.count} · not saved yet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (p.plan.estimated)
                      const Text(
                        'estimated (offline)',
                        style: TextStyle(color: QuiccColors.statusFiring, fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    if (leftovers > 0)
                      Text(
                        '$leftovers stay unassigned',
                        style: TextStyle(color: context.palette.textSecondary, fontSize: 13),
                      ),
                  ],
                ),
              ],
            ),
          ),
          TextButton(onPressed: _confirmBusy ? null : _preview.clear, child: const Text('CLEAR')),
          const SizedBox(width: 4),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: QuiccColors.statusFiring,
              foregroundColor: QuiccColors.brand900,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
        padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
        child: Row(
          children: [
            Text('$n selected', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                n == 0 ? 'Tap deliveries to pick them' : 'Tap a driver to move them there, or the left side to unassign',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.palette.textSecondary),
              ),
            ),
            TextButton(onPressed: _endSelect, child: const Text('CANCEL')),
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
        runs.add(_Run(driver: d, name: d.name, orders: orders));
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

/// AUTO / SELECT in the left column's header.
class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool busy;
  final VoidCallback? onTap;
  const _HeaderButton({
    super.key,
    required this.icon,
    required this.label,
    this.active = false,
    this.busy = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        backgroundColor: active ? QuiccColors.brand400.withValues(alpha: 0.18) : null,
        side: BorderSide(color: active ? QuiccColors.brand400 : context.palette.borderSoft),
      ),
      onPressed: onTap,
      icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon),
      label: Text(label),
    ),
  );
}
