import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/floor_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/island.dart';
import '../common/widgets.dart';
import '../deliveries/delivery_widgets.dart';
import '../maps/geo_format.dart';
import '../maps/runs_map_pane.dart';
import '../order_detail/order_detail_screen.dart';
import 'drivers_texts.dart';

/// What PRINT REPORT says when the Pi refused (null = the generic error).
String? driverReportErrorMessage(String name, Object e) => switch (e) {
  AgentException(code: kDriverReportUnsupported) => "This Pi needs an update to print one driver's report.",
  AgentException(code: 'nothing_printed') => "$name's report didn't print — check the receipt printer.",
  AgentException(code: 'printing_unavailable') => 'No printers are set up on the Pi — nothing to print on.',
  AgentException(code: 'driver_not_found') => '$name was removed from the roster.',
  _ => null,
};

/// The toast after a clock-out. A Pi ≥ 2.3 prints the driver's report in the
/// background ([reportPrinting]); how that went comes later as an app-wide
/// toast (SSE `driver.report_printed`).
String clockedOutMessage(String name, {bool reportPrinting = false}) =>
    reportPrinting ? '$name clocked out — printing his report…' : '$name clocked out';

/// A driver's deliveries of the open batch on the Drivers tab: delivered and
/// out now, newest first ([driverId] null = Unassigned).
List<StoredOrder> driverDeliveries(List<StoredOrder> batch, String? driverId) {
  final list = [
    for (final o in batch)
      if (driverId == null
          ? o.isUnassigned
          : o.isDelivery &&
                (o.state == OrderState.delivered || o.state == OrderState.onDelivery) &&
                o.status.driverId == driverId)
        o,
  ];
  DateTime at(StoredOrder o) =>
      o.status.deliveredAt ?? o.status.markedDelivered?.at ?? o.status.outAt ?? o.placedTime ?? DateTime(2000);
  list.sort((a, b) => at(b).compareTo(at(a)));
  return list;
}

/// The Drivers tab (2.0.0, owner): who delivered what this batch, and the
/// shift buttons.
///
///  * right: UNASSIGNED on top (amber with a count while it holds orders),
///    then the clocked-in drivers as big buttons in queue order (NEXT first;
///    hold and drag to reorder the queue), then every clocked-out driver as a
///    small grey button;
///  * left: the deliveries of the button picked — delivered this batch and
///    out now (Unassigned: the ones marked delivered with no driver);
///  * a tap on a delivery selects it, a hold opens it; with deliveries
///    selected a tap on a driver's button moves them to that driver (a
///    clocked-out one can't take any; an out one asks first; Unassigned
///    takes delivered ones only), with UNDO; with nothing selected a tap on
///    a button shows that driver;
///  * on top, for the driver shown: CLOCK IN / CLOCK OUT and PRINT REPORT.
///
/// Adding, editing and removing drivers is in Settings → Drivers.
class DriversPane extends ConsumerStatefulWidget {
  const DriversPane({super.key});

  @override
  ConsumerState<DriversPane> createState() => _DriversPaneState();
}

class _DriversPaneState extends ConsumerState<DriversPane> {
  /// The driver shown (null = Unassigned — what the tab opens on).
  String? _view;
  final Set<String> _selected = {};
  bool _busy = false;
  bool _printing = false;

  FloorController get _floor => ref.read(floorProvider.notifier);

  void _toast(String msg, {bool error = false}) => toast(context, msg, error: error);

  void _open(StoredOrder o) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => OrderDetailScreen(orderId: o.id, initial: o),
    ),
  );

  void _toggle(String id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  /// A driver's button (null = UNASSIGNED): moves the selection there, or
  /// shows them when nothing is selected.
  Future<void> _tapButton(Driver? d) async {
    if (_selected.isEmpty) {
      setState(() => _view = d?.id);
      return;
    }
    final fs = ref.read(floorProvider);
    final picked = [
      for (final id in _selected)
        if (fs.orders[id] != null) fs.orders[id]!,
    ];
    final moving = picked.where((o) => d == null ? !o.isUnassigned : o.status.driverId != d.id).toList();
    if (moving.isEmpty) {
      setState(_selected.clear);
      return;
    }
    if (d != null && d.isOff) {
      _toast('Clock ${d.name} in first — nothing moves to a clocked-out driver.', error: true);
      return;
    }
    final out = moving.where((o) => o.state == OrderState.onDelivery).toList();
    if (d == null && out.isNotEmpty) {
      _toast(
        '${numbersList([for (final o in out) orderNumber(o)])} ${out.length == 1 ? 'is' : 'are'} still out — only delivered ones go to Unassigned.',
        error: true,
      );
      return;
    }
    if (out.isNotEmpty) {
      final who = out.first.status.driverName ?? 'a driver';
      final ok = await confirmDialog(
        context,
        title: out.length == 1
            ? '${orderNumber(out.first)} is out with $who — move it to ${d!.name} anyway?'
            : '${numbersList([for (final o in out) orderNumber(o)])} are out — move them to ${d!.name} anyway?',
        message: 'They join ${d.name}\'s run${d.isAvailable ? ' (${d.name} goes out with them)' : ''}.',
        confirm: 'MOVE',
      );
      if (!ok || !mounted) return;
    }
    await _move(moving, d);
  }

  Future<void> _move(List<StoredOrder> moving, Driver? to) async {
    final island = Island.maybeOf(context);
    final floor = _floor;
    final from = <String?, List<String>>{};
    for (final o in moving) {
      from.putIfAbsent(o.isUnassigned ? null : o.status.driverId, () => []).add(o.id);
    }
    setState(_selected.clear);
    final name = to?.name ?? 'Unassigned';
    try {
      await floor.reassign([for (final o in moving) o.id], to?.id);
      island?.show(
        '${moving.length} moved to $name',
        kind: IslandKind.success,
        duration: const Duration(seconds: 10),
        actions: [
          IslandAction('UNDO', () async {
            try {
              for (final e in from.entries) {
                await floor.reassign(e.value, e.key);
              }
              island.show('Moved back', kind: IslandKind.info);
            } catch (_) {
              island.show("Couldn't undo — move them back by hand", kind: IslandKind.error);
            }
          }),
        ],
      );
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: kUnassignedUnsupported) => 'This Pi needs an update to move deliveries between drivers.',
        AgentException(code: 'driver_not_available') => "$name isn't clocked in any more — list refreshed.",
        AgentException(code: 'not_out_or_delivered') => 'One of them changed meanwhile — list refreshed.',
        AgentException(code: 'invalid_state') => 'Only delivered ones go to Unassigned — list refreshed.',
        _ => null,
      };
      msg == null ? toastError(context, e, lead: 'Not moved', area: 'drivers') : _toast(msg, error: true);
    }
  }

  Future<void> _clockIn(Driver d) async {
    setState(() => _busy = true);
    try {
      await _floor.clockIn(d.id);
      if (mounted) _toast('${d.name} clocked in — back of the queue');
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'invalid_state') => '${d.name} is already clocked in.',
        AgentException(isNotFound: true) => '${d.name} was removed from the roster.',
        _ => null,
      };
      msg == null
          ? toastError(context, e, lead: 'Could not clock ${d.name} in', area: 'drivers')
          : _toast(msg, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clockOut(Driver d) async {
    setState(() => _busy = true);
    try {
      final r = await _floor.clockOut(d.id);
      if (mounted) _toast(clockedOutMessage(d.name, reportPrinting: r.reportPrinting));
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'driver_not_available') =>
          d.isOff
              ? '${d.name} is already clocked out.'
              : '${d.name} is out on a run — mark him returned first, then clock him out.',
        AgentException(isNotFound: true) => '${d.name} was removed from the roster.',
        _ => null,
      };
      msg == null
          ? toastError(context, e, lead: 'Could not clock ${d.name} out', area: 'drivers')
          : _toast(msg, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// PRINT REPORT: this driver's report for the open batch so far, on the
  /// receipt printer (Pi 2.2.3).
  Future<void> _printReport(Driver d) async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      final r = await _floor.printDriverReport(d.id);
      if (mounted) {
        final name = r.driverName.isEmpty ? d.name : r.driverName;
        _toast(driverReportPrintedMessage(name, printedOn: r.printedOn, reroutedFrom: r.reroutedFrom));
      }
    } catch (e) {
      if (!mounted) return;
      final msg = driverReportErrorMessage(d.name, e);
      msg == null
          ? toastError(context, e, lead: "${d.name}'s report didn't print", area: 'drivers')
          : _toast(msg, error: true);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  /// Hold and drag a clocked-in button: the queue. The clocked-out drivers
  /// keep their places after them.
  void _reorder(List<Driver> onShift, List<Driver> all, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final list = [...onShift];
    list.insert(newIndex, list.removeAt(oldIndex));
    final ids = {for (final d in list) d.id};
    _floor.reorderDrivers([...list, ...all.where((d) => !ids.contains(d.id))]).catchError((Object e) {
      if (mounted) toastError(context, e, lead: 'Could not reorder', area: 'drivers');
    });
  }

  @override
  Widget build(BuildContext context) {
    final fs = ref.watch(floorProvider);
    final drivers = fs.drivers;
    final batch = fs.currentBatchOrders;
    var view = _view == null ? null : drivers.where((d) => d.id == _view).firstOrNull;
    if (_view != null && view == null) _view = null; // removed meanwhile: back to Unassigned
    final onShift = [
      for (final d in drivers)
        if (!d.isOff) d,
    ];
    final off = [
      for (final d in drivers)
        if (d.isOff) d,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final next = fs.nextDriver;
    final unassigned = driverDeliveries(batch, null);
    final shown = driverDeliveries(batch, view?.id);
    _selected.retainAll({for (final o in shown) o.id});

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(QuiccSpace.pane, QuiccSpace.pane, QuiccSpace.pane, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PaneHeader(
                title: view?.name ?? 'Unassigned',
                subtitle: view == null
                    ? '${unassigned.length} delivered with no driver — select them and tap the driver who took them'
                    : '${shown.length} deliver${shown.length == 1 ? 'y' : 'ies'} this batch · ${view.status.label.toLowerCase()}'
                          '${view.clockedInAt != null && !view.isOff ? ' since ${clock(view.clockedInAt)}' : ''}',
                trailing: view == null ? null : _topBar(view),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: _deliveries(context, shown, view)),
                    QuiccSpace.gapLg,
                    SizedBox(width: 300, child: _buttons(context, fs, onShift, off, next, unassigned.length, view)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_selected.isNotEmpty)
          Positioned(left: QuiccSpace.pane, right: 340, bottom: QuiccSpace.lg, child: _selectBar(context, shown)),
      ],
    );
  }

  Widget _topBar(Driver d) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const LabelWithInfo(label: SizedBox.shrink(), info: kClockInfo),
      QuiccSpace.gapSm,
      SizedBox(
        height: 48,
        child: OutlinedButton.icon(
          key: const ValueKey('print-report'),
          onPressed: _printing ? null : () => _printReport(d),
          icon: _printing ? const _Spinner() : const Icon(Icons.print_outlined),
          label: const Text('PRINT REPORT'),
        ),
      ),
      QuiccSpace.gapMd,
      SizedBox(
        width: 160,
        height: 48,
        child: d.isOff
            ? FilledButton(
                key: const ValueKey('clock-in'),
                onPressed: _busy ? null : () => _clockIn(d),
                child: _busy ? const _Spinner() : const Text('CLOCK IN'),
              )
            : OutlinedButton(
                key: const ValueKey('clock-out'),
                onPressed: _busy ? null : () => _clockOut(d),
                child: _busy ? const _Spinner() : const Text('CLOCK OUT'),
              ),
      ),
    ],
  );

  Widget _deliveries(BuildContext context, List<StoredOrder> shown, Driver? view) {
    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: QuiccSpace.xl),
        child: EmptyState(
          icon: view == null ? Icons.task_alt : Icons.delivery_dining_outlined,
          title: view == null ? 'Nothing unassigned' : 'No deliveries for ${view.name} this batch',
          message: view == null
              ? 'A delivery marked delivered with no driver waits here until you give it to the driver who took it.'
              : null,
        ),
      );
    }
    return ListView(
      key: const ValueKey('driver-deliveries'),
      padding: const EdgeInsets.only(bottom: 120),
      children: [
        for (final o in shown)
          DriverDeliveryCard(
            key: ValueKey('dd-${o.id}'),
            order: o,
            selected: _selected.contains(o.id),
            selecting: _selected.isNotEmpty,
            onTap: () => _toggle(o.id),
            onLongPress: () => _open(o),
          ),
      ],
    );
  }

  Widget _buttons(
    BuildContext context,
    FloorState fs,
    List<Driver> onShift,
    List<Driver> off,
    Driver? next,
    int unassigned,
    Driver? view,
  ) {
    final batch = fs.currentBatchOrders;
    int count(Driver d) => driverDeliveries(batch, d.id).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _UnassignedButton(count: unassigned, selected: view == null, onTap: () => _tapButton(null)),
        QuiccSpace.gapMd,
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverReorderableList(
                itemCount: onShift.length,
                onReorder: (a, b) => _reorder(onShift, fs.drivers, a, b),
                itemBuilder: (context, i) {
                  final d = onShift[i];
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey('driver-button-${d.id}'),
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: QuiccSpace.sm),
                      child: DriverButton(
                        driver: d,
                        color: driverColor(fs.drivers, d.id),
                        count: count(d),
                        next: next?.id == d.id,
                        selected: view?.id == d.id,
                        onTap: () => _tapButton(d),
                      ),
                    ),
                  );
                },
              ),
              if (off.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: QuiccSpace.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Eyebrow('Clocked out'),
                        QuiccSpace.gapSm,
                        Wrap(
                          spacing: QuiccSpace.sm,
                          runSpacing: QuiccSpace.sm,
                          children: [
                            for (final d in off)
                              _OffButton(
                                key: ValueKey('off-button-${d.id}'),
                                driver: d,
                                count: count(d),
                                selected: view?.id == d.id,
                                onTap: () => _tapButton(d),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _selectBar(BuildContext context, List<StoredOrder> shown) {
    final n = _selected.length;
    final all = shown.every((o) => _selected.contains(o.id));
    return Material(
      key: const ValueKey('driver-select-bar'),
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
                'Tap a driver to move them there. Hold one to open it.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
              ),
            ),
            if (!all)
              TextButton(
                key: const ValueKey('driver-select-all'),
                onPressed: () => setState(() => _selected.addAll(shown.map((o) => o.id))),
                child: const Text('SELECT ALL'),
              ),
            TextButton(
              key: const ValueKey('driver-select-clear'),
              onPressed: () => setState(_selected.clear),
              child: const Text('CLEAR'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One delivery of the driver shown: number, street + apt, CASH $ / PAID,
/// the tip; OUT while it is out. Tap = select, hold = details.
class DriverDeliveryCard extends StatelessWidget {
  final StoredOrder order;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const DriverDeliveryCard({
    super.key,
    required this.order,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final a = order.order.fulfillment.address;
    final street = a == null ? 'No address' : [a.line1.trim(), a.line2.trim()].where((p) => p.isNotEmpty).join(' ');
    final cash = order.cashDueCents;
    final tip = order.status.tipCents ?? order.order.money.tipCents;
    final out = order.state == OrderState.onDelivery;
    return Card(
      margin: const EdgeInsets.only(bottom: QuiccSpace.sm),
      color: selected ? QuiccColors.brand400.withValues(alpha: 0.14) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        side: BorderSide(color: selected ? QuiccColors.brand400 : Colors.transparent, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(QuiccSpace.md),
          child: Row(
            children: [
              if (selecting)
                Padding(
                  padding: const EdgeInsets.only(right: QuiccSpace.sm),
                  child: Icon(
                    selected ? Icons.check_box : Icons.check_box_outline_blank,
                    color: selected ? QuiccColors.brand400 : context.palette.textMuted,
                  ),
                ),
              SizedBox(
                width: 76,
                child: Text(
                  order.displayNumber,
                  style: QuiccType.number(QuiccType.heading, weight: FontWeight.w700, color: QuiccColors.brand400),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      street,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
                    ),
                    Text(
                      [cash > 0 ? 'CASH ${money(cash)}' : 'PAID', if (tip > 0) 'tip ${money(tip)}'].join(' · '),
                      style: QuiccType.number(QuiccType.label, color: context.palette.textSecondary),
                    ),
                  ],
                ),
              ),
              if (out) const GeoTag('OUT', color: QuiccColors.brand400),
            ],
          ),
        ),
      ),
    );
  }
}

/// A clocked-in driver's big button: their colour, name, NEXT / OUT /
/// AVAILABLE and how many deliveries they have this batch.
class DriverButton extends StatelessWidget {
  final Driver driver;
  final Color color;
  final int count;
  final bool next;
  final bool selected;
  final VoidCallback onTap;
  const DriverButton({
    super.key,
    required this.driver,
    required this.color,
    required this.count,
    required this.next,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final status = next ? 'NEXT' : (driver.isOut ? 'OUT' : 'AVAILABLE');
    return Material(
      color: selected ? color.withValues(alpha: 0.22) : context.palette.bgElevated,
      borderRadius: BorderRadius.circular(QuiccRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        onTap: onTap,
        child: Container(
          height: 76,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(QuiccRadius.lg),
            border: Border.all(color: selected ? color : context.palette.borderSoft, width: selected ? 3 : 1),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(QuiccRadius.lg)),
                ),
              ),
              QuiccSpace.gapMd,
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      driver.name.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: QuiccType.text(QuiccType.heading, weight: FontWeight.w800),
                    ),
                    Text(
                      status,
                      style: QuiccType.text(
                        QuiccType.caption,
                        weight: FontWeight.w700,
                        color: next
                            ? QuiccColors.statusPaid
                            : (driver.isOut ? QuiccColors.brand400 : context.palette.textMuted),
                      ).copyWith(letterSpacing: 1.2),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: QuiccSpace.lg),
                child: Text('$count', style: QuiccType.number(QuiccType.heading + 6, weight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// UNASSIGNED at the top of the buttons: amber with a count while it holds
/// orders, grey when empty.
class _UnassignedButton extends StatelessWidget {
  final int count;
  final bool selected;
  final VoidCallback onTap;
  const _UnassignedButton({required this.count, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final amber = count > 0;
    final c = amber ? QuiccColors.statusFiring : context.palette.textMuted;
    return Material(
      key: const ValueKey('unassigned-button'),
      color: amber ? QuiccColors.statusFiring.withValues(alpha: selected ? 0.30 : 0.16) : context.palette.bgElevated,
      borderRadius: BorderRadius.circular(QuiccRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        onTap: onTap,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(QuiccRadius.lg),
            border: Border.all(color: selected ? c : c.withValues(alpha: 0.5), width: selected ? 3 : 1),
          ),
          child: Row(
            children: [
              Icon(Icons.person_off_outlined, color: c),
              QuiccSpace.gapMd,
              Expanded(
                child: Text(
                  'UNASSIGNED',
                  style: QuiccType.text(QuiccType.heading, weight: FontWeight.w800, color: c),
                ),
              ),
              if (amber)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.md, vertical: 4),
                  decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(999)),
                  child: Text(
                    '$count',
                    style: QuiccType.number(QuiccType.body, weight: FontWeight.w800, color: QuiccColors.brand900),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A clocked-out driver: small and grey — shows their deliveries; CLOCK IN
/// on top. Nothing can be moved to them.
class _OffButton extends StatelessWidget {
  final Driver driver;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  const _OffButton({super.key, required this.driver, required this.count, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: selected ? 1 : 0.6,
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.md, vertical: QuiccSpace.sm),
        side: BorderSide(color: selected ? QuiccColors.brand400 : context.palette.borderSoft, width: selected ? 2 : 1),
        foregroundColor: context.palette.textSecondary,
      ),
      onPressed: onTap,
      child: Text(count == 0 ? driver.name : '${driver.name} · $count'),
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
}
