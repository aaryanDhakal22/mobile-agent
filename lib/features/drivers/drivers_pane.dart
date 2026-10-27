import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'driver_dialog.dart';
import 'drivers_texts.dart';

/// The agent refuses (409 `driver_not_available`) to remove a driver who is
/// out on a run.
String removeDriverOutMessage(String name) =>
    "Can't remove a driver who is out on a run — tap I HAVE RETURNED for $name on Deliveries first.";

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

/// Driver roster in queue order. Drivers clock in when they arrive (joining
/// the back of the queue) and out when they leave; the first available
/// driver is next up. Drag to reorder.
class DriversPane extends ConsumerStatefulWidget {
  const DriversPane({super.key});

  @override
  ConsumerState<DriversPane> createState() => _DriversPaneState();
}

class _DriversPaneState extends ConsumerState<DriversPane> {
  /// Drivers with a clock-in / clock-out in flight.
  final Set<String> _busy = {};

  /// Drivers whose report is printing.
  final Set<String> _printing = {};

  FloorController get _floor => ref.read(floorProvider.notifier);

  /// Runs [op]; on failure toasts [failure] and returns false.
  Future<bool> _run(Future<void> Function() op, String failure) async {
    try {
      await op();
      return true;
    } catch (e) {
      if (mounted) toastError(context, e, lead: failure, area: 'drivers');
      return false;
    }
  }

  Future<void> _add() async {
    final r = await driverDialog(context, title: 'Add driver', confirm: 'ADD');
    if (r == null || r.name.isEmpty || !mounted) return;
    final ok = await _run(
      () => _floor.createDriver(r.name, posNumber: r.posNumber.isEmpty ? null : r.posNumber),
      'Could not add ${r.name}',
    );
    if (ok && mounted) toast(context, '${r.name} added — clock them in when they start');
  }

  /// Name and Driver # (their SoftTouch Employee Number); only what changed is sent.
  Future<void> _edit(Driver d) async {
    final r = await driverDialog(context, title: 'Edit driver', name: d.name, posNumber: d.posNumber ?? '');
    if (r == null || r.name.isEmpty || !mounted) return;
    final name = r.name == d.name ? null : r.name;
    final number = r.posNumber == (d.posNumber ?? '') ? null : r.posNumber;
    if (name == null && number == null) return;
    await _run(() => _floor.updateDriver(d.id, name: name, posNumber: number), 'Could not save ${d.name}');
  }

  Future<void> _remove(Driver d) async {
    if (d.isOut) {
      toast(context, removeDriverOutMessage(d.name), error: true);
      return;
    }
    final ok = await confirmDialog(
      context,
      title: 'Remove ${d.name}?',
      message: 'They leave the roster. Past orders and shift records keep their name.',
      confirm: 'REMOVE',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await _floor.removeDriver(d.id);
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'driver_not_available') => removeDriverOutMessage(d.name),
        AgentException(isNotFound: true) => '${d.name} was already removed.',
        _ => null,
      };
      msg == null
          ? toastError(context, e, lead: 'Could not remove ${d.name}', area: 'drivers')
          : toast(context, msg, error: true);
    }
  }

  Future<void> _clockIn(Driver d) async {
    setState(() => _busy.add(d.id));
    try {
      await _floor.clockIn(d.id);
      if (mounted) toast(context, '${d.name} clocked in — back of the queue');
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'invalid_state') => '${d.name} is already clocked in.',
        AgentException(isNotFound: true) => '${d.name} was removed from the roster.',
        _ => null,
      };
      msg == null
          ? toastError(context, e, lead: 'Could not clock ${d.name} in', area: 'drivers')
          : toast(context, msg, error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(d.id));
    }
  }

  Future<void> _clockOut(Driver d) async {
    setState(() => _busy.add(d.id));
    try {
      final r = await _floor.clockOut(d.id);
      if (mounted) toast(context, clockedOutMessage(d.name, reportPrinting: r.reportPrinting));
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'driver_not_available') =>
          d.isOff
              ? '${d.name} is already clocked out.'
              : '${d.name} is out on a run — tap I HAVE RETURNED on Deliveries first, then clock them out.',
        AgentException(isNotFound: true) => '${d.name} was removed from the roster.',
        _ => null,
      };
      msg == null
          ? toastError(context, e, lead: 'Could not clock ${d.name} out', area: 'drivers')
          : toast(context, msg, error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(d.id));
    }
  }

  /// PRINT REPORT: this driver's report for the open batch so far, on the
  /// receipt printer (Pi 2.2.3).
  Future<void> _printReport(Driver d) async {
    if (_printing.contains(d.id)) return;
    setState(() => _printing.add(d.id));
    try {
      final r = await _floor.printDriverReport(d.id);
      if (mounted) {
        final name = r.driverName.isEmpty ? d.name : r.driverName;
        toast(context, driverReportPrintedMessage(name, printedOn: r.printedOn, reroutedFrom: r.reroutedFrom));
      }
    } catch (e) {
      if (!mounted) return;
      final msg = driverReportErrorMessage(d.name, e);
      msg == null
          ? toastError(context, e, lead: "${d.name}'s report didn't print", area: 'drivers')
          : toast(context, msg, error: true);
    } finally {
      if (mounted) setState(() => _printing.remove(d.id));
    }
  }

  void _showShifts() {
    showDialog<void>(context: context, builder: (_) => const _ShiftsDialog());
  }

  @override
  Widget build(BuildContext context) {
    final drivers = ref.watch(floorProvider.select((s) => s.drivers));
    final resetTime = ref.watch(floorProvider.select((s) => s.floor?.driverResetTime));
    final inQueue = drivers.where((d) => d.isAvailable).length;
    final out = drivers.where((d) => d.isOut).length;
    final off = drivers.where((d) => d.isOff).length;

    // Queue rank among available drivers (1 = next up).
    final rank = <String, int>{};
    for (final d in drivers) {
      if (d.isAvailable) rank[d.id] = rank.length + 1;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(
            title: 'Drivers',
            subtitle: '$inQueue in queue · $out out · $off off',
            trailing: FilledButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('ADD DRIVER'),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Clock drivers in when they start — they join the back of the queue, and the first '
                      'available driver is next up. Drag ≡ to reorder.',
                      style: QuiccType.text(QuiccType.body, color: context.palette.textMuted),
                    ),
                    const Wrap(
                      spacing: 16,
                      children: [
                        LabelWithInfo(label: Text('Clock in / out'), info: kClockInfo),
                        LabelWithInfo(label: Text('The queue'), info: kQueueInfo),
                        LabelWithInfo(label: Text('Remove'), info: kRemoveDriverInfo),
                      ],
                    ),
                    if (resetTime != null && resetTime.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.schedule, size: 16, color: context.palette.textMuted),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Everyone is clocked out daily at ${wallTime(resetTime)} (set in the agent web UI).',
                              style: QuiccType.text(QuiccType.label, color: context.palette.textMuted),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TextButton.icon(onPressed: _showShifts, icon: const Icon(Icons.history), label: const Text('SHIFTS')),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: drivers.isEmpty
                ? const EmptyState(
                    icon: Icons.delivery_dining_outlined,
                    title: 'No drivers yet',
                    message: 'Add your drivers once, then clock them in when they start a shift.',
                  )
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.only(bottom: 32),
                    itemCount: drivers.length,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex -= 1;
                      final list = [...drivers];
                      list.insert(newIndex, list.removeAt(oldIndex));
                      _run(() => _floor.reorderDrivers(list), 'Could not reorder');
                    },
                    itemBuilder: (context, i) {
                      final d = drivers[i];
                      return Padding(
                        key: ValueKey(d.id),
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _DriverRow(
                          index: i,
                          driver: d,
                          rank: rank[d.id],
                          busy: _busy.contains(d.id),
                          printing: _printing.contains(d.id),
                          onPrintReport: () => _printReport(d),
                          onClockIn: () => _clockIn(d),
                          onClockOut: () => _clockOut(d),
                          onEdit: () => _edit(d),
                          onRemove: () => _remove(d),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _DriverRow extends StatelessWidget {
  final int index;
  final Driver driver;

  /// Position among available drivers (1 = next up); null if not in queue.
  final int? rank;
  final bool busy;

  /// Their report is printing (PRINT REPORT shows a spinner).
  final bool printing;
  final VoidCallback onPrintReport;
  final VoidCallback onClockIn;
  final VoidCallback onClockOut;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const _DriverRow({
    required this.index,
    required this.driver,
    required this.rank,
    required this.busy,
    required this.printing,
    required this.onPrintReport,
    required this.onClockIn,
    required this.onClockOut,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final d = driver;
    final details = [
      ?driverNumberLabel(d.posNumber),
      if (d.isOff) 'Clocked out' else if (d.clockedInAt != null) 'In since ${clock(d.clockedInAt)}',
      '${d.deliveries} run${d.deliveries == 1 ? '' : 's'} this batch',
      if (d.lastReturnedAt != null && !d.isOff) 'back ${clock(d.lastReturnedAt)}',
    ];

    return Opacity(
      opacity: d.isOff ? 0.7 : 1,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(Icons.drag_handle, color: context.palette.textMuted, size: 30),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  rank == null ? '' : '$rank',
                  style: QuiccType.number(QuiccType.heading + 2, weight: FontWeight.w700, color: context.palette.textMuted),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rank == 1 ? '${d.name} · NEXT' : d.name,
                      overflow: TextOverflow.ellipsis,
                      style: QuiccType.text(QuiccType.heading, weight: FontWeight.w600),
                    ),
                    Text(
                      details.join(' · '),
                      overflow: TextOverflow.ellipsis,
                      style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
                    ),
                  ],
                ),
              ),
              _DriverStatusPill(d.status),
              const SizedBox(width: 12),
              SizedBox(
                height: 48,
                child: TextButton.icon(
                  key: ValueKey('print-report-${d.id}'),
                  onPressed: printing ? null : onPrintReport,
                  icon: printing ? const _Spinner() : const Icon(Icons.print_outlined),
                  label: const Text('PRINT REPORT'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 150,
                height: 48,
                child: d.isOff
                    ? FilledButton(
                        onPressed: busy ? null : onClockIn,
                        child: busy ? const _Spinner() : const Text('CLOCK IN'),
                      )
                    : OutlinedButton(
                        onPressed: busy ? null : onClockOut,
                        child: busy ? const _Spinner() : const Text('CLOCK OUT'),
                      ),
              ),
              const SizedBox(width: 4),
              IconButton(tooltip: 'Edit name / Driver #', onPressed: onEdit, icon: const Icon(Icons.edit_outlined)),
              IconButton(
                tooltip: 'Remove',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, color: QuiccColors.statusVoided),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
}

class _DriverStatusPill extends StatelessWidget {
  final DriverStatus status;
  const _DriverStatusPill(this.status);

  @override
  Widget build(BuildContext context) {
    final c = switch (status) {
      DriverStatus.available => QuiccColors.statusPaid,
      DriverStatus.out => QuiccColors.brand400,
      DriverStatus.off => context.palette.textMuted,
    };
    return Container(
      width: 104,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(QuiccRadius.sm),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Text(
        status.label,
        style: QuiccType.text(QuiccType.caption, weight: FontWeight.w700, color: c).copyWith(letterSpacing: 1.2),
      ),
    );
  }
}

/// Shift records of the last 7 days (`GET /api/drivers/shifts?days=7`) — who
/// worked when, for reports. Not wages.
class _ShiftsDialog extends ConsumerWidget {
  const _ShiftsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shifts = ref.watch(driverShiftsProvider);
    return AlertDialog(
      title: const Text('Shifts — last 7 days'),
      content: SizedBox(
        width: 640,
        height: 420,
        child: shifts.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Align(
            alignment: Alignment.topCenter,
            child: InlineError.from(
              e,
              lead: 'Could not load shifts',
              area: 'drivers',
              onRetry: () => ref.invalidate(driverShiftsProvider),
            ),
          ),
          data: (list) => list.isEmpty
              ? Center(
                  child: Text('No shifts in the last 7 days.', style: QuiccType.text(QuiccType.body, color: context.palette.textMuted)),
                )
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => Divider(height: 1, color: context.palette.borderSoft),
                  itemBuilder: (context, i) => _ShiftRow(list[i]),
                ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CLOSE'))],
    );
  }
}

class _ShiftRow extends StatelessWidget {
  final Shift shift;
  const _ShiftRow(this.shift);

  @override
  Widget build(BuildContext context) {
    final s = shift;
    final span = s.isOpen ? '${clock(s.clockIn)} – now' : '${clock(s.clockIn)} – ${clock(s.clockOut)}';
    final len = s.length(timeNow());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              s.driverName.isEmpty ? 'Driver' : s.driverName,
              overflow: TextOverflow.ellipsis,
              style: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              '${dateClock(s.clockIn).split(',').first} · $span',
              style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              len == null ? '' : minutes(len),
              textAlign: TextAlign.right,
              style: QuiccType.number(QuiccType.label, weight: FontWeight.w500, color: context.palette.textSecondary),
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              s.isOpen ? 'ON SHIFT' : (s.autoOut ? 'AUTO OUT' : ''),
              textAlign: TextAlign.right,
              style: QuiccType.text(
                QuiccType.caption,
                weight: FontWeight.w700,
                color: s.isOpen ? QuiccColors.statusPaid : context.palette.textMuted,
              ).copyWith(letterSpacing: 1.2),
            ),
          ),
        ],
      ),
    );
  }
}
