import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/floor_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../order_detail/order_detail_screen.dart';

/// Ready deliveries → pick a driver → send out; drivers out + "I have returned".
class DeliveriesPane extends ConsumerStatefulWidget {
  const DeliveriesPane({super.key});

  @override
  ConsumerState<DeliveriesPane> createState() => _DeliveriesPaneState();
}

class _DeliveriesPaneState extends ConsumerState<DeliveriesPane> {
  final Set<String> _selected = {};
  String? _driverId; // null → first available
  bool _sending = false;
  final Set<String> _returning = {};

  Future<void> _send(Driver driver, List<String> ids) async {
    setState(() => _sending = true);
    try {
      await ref.read(floorProvider.notifier).assign(driver.id, ids);
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _driverId = null;
      });
      toast(context, '${ids.length} order${ids.length == 1 ? '' : 's'} out with ${driver.name}');
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'driver_not_found') => 'That driver was removed. Pick another.',
        AgentException(code: 'driver_not_available') =>
          '${driver.name} isn\'t clocked in or is already out — pick another driver.',
        AgentException(isConflict: true) => 'An order is no longer ready for delivery — list refreshed.',
        _ => 'Not sent out: $e',
      };
      toast(context, msg, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _returned(Driver d) async {
    setState(() => _returning.add(d.id));
    try {
      await ref.read(floorProvider.notifier).driverReturned(d.id);
      if (mounted) toast(context, '${d.name} is back — moved to the end of the queue');
    } catch (e) {
      if (!mounted) return;
      final msg = switch (e) {
        AgentException(code: 'invalid_state') => '${d.name} isn\'t out any more — already marked returned.',
        AgentException(isNotFound: true) => '${d.name} was removed from the roster.',
        _ => 'Could not mark ${d.name} returned: $e',
      };
      toast(context, msg, error: true);
    } finally {
      if (mounted) setState(() => _returning.remove(d.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fs = ref.watch(floorProvider);
    final ready = fs.readyDeliveries;
    final readyIds = ready.map((o) => o.id).toSet();
    _selected.retainAll(readyIds);
    // Only clocked-in drivers who aren't on a run, in queue order.
    final available = fs.availableDrivers;
    Driver? driver;
    for (final d in available) {
      if (d.id == _driverId) driver = d;
    }
    driver ??= available.isEmpty ? null : available.first;
    final runs = _runs(fs);

    return RefreshIndicator(
      onRefresh: () => ref.read(floorProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.all(32),
        children: [
          PaneHeader(title: 'Deliveries', subtitle: '${ready.length} ready · ${runs.length} out'),
          const Eyebrow('Ready to go out'),
          const SizedBox(height: 10),
          if (ready.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text('No delivery orders are ready.', style: TextStyle(color: context.palette.textMuted)),
            )
          else ...[
            for (final o in ready)
              _ReadyRow(
                order: o,
                selected: _selected.contains(o.id),
                onChanged: (v) => setState(() => v ? _selected.add(o.id) : _selected.remove(o.id)),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(
                    () => _selected
                      ..clear()
                      ..addAll(readyIds),
                  ),
                  child: const Text('SELECT ALL'),
                ),
                if (_selected.isNotEmpty)
                  TextButton(onPressed: () => setState(_selected.clear), child: const Text('CLEAR')),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Eyebrow('Driver (queue order)'),
                    const SizedBox(height: 10),
                    if (available.isEmpty)
                      Text(
                        fs.anyDriverOnShift
                            ? 'Every clocked-in driver is out — wait for one to return, or clock another in on the Drivers tab.'
                            : 'No driver clocked in — clock one in on the Drivers tab.',
                        style: TextStyle(color: context.palette.textSecondary),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < available.length; i++)
                            ChoiceChip(
                              label: Text(
                                i == 0 ? '${available[i].name} · NEXT' : available[i].name,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                              selected: available[i].id == driver?.id,
                              selectedColor: QuiccColors.brand400.withValues(alpha: 0.3),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                              onSelected: (_) => setState(() => _driverId = available[i].id),
                            ),
                        ],
                      ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 60,
                      child: FilledButton.icon(
                        onPressed: (_sending || driver == null || _selected.isEmpty)
                            ? null
                            : () => _send(
                                driver!,
                                ready.where((o) => _selected.contains(o.id)).map((o) => o.id).toList(),
                              ),
                        icon: const Icon(Icons.delivery_dining, size: 28),
                        label: Text(
                          _selected.isEmpty
                              ? 'SELECT ORDERS TO SEND OUT'
                              : 'SEND ${_selected.length} OUT WITH ${driver?.name.toUpperCase() ?? '…'}',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 32),
          const Eyebrow('Out on delivery'),
          const SizedBox(height: 10),
          if (runs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text('No drivers are out.', style: TextStyle(color: context.palette.textMuted)),
            ),
          for (final run in runs)
            _RunCard(
              run: run,
              busy: run.driver != null && _returning.contains(run.driver!.id),
              onReturned: run.driver == null ? null : () => _returned(run.driver!),
            ),
        ],
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

class _ReadyRow extends StatelessWidget {
  final StoredOrder order;
  final bool selected;
  final ValueChanged<bool> onChanged;
  const _ReadyRow({required this.order, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final o = order.order;
    return Card(
      color: selected ? QuiccColors.brand400.withValues(alpha: 0.14) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        side: BorderSide(color: selected ? QuiccColors.brand400 : Colors.transparent, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        onTap: () => onChanged(!selected),
        onLongPress: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => OrderDetailScreen(orderId: order.id, initial: order),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Checkbox(value: selected, onChanged: (v) => onChanged(v ?? false)),
              SizedBox(
                width: 90,
                child: Text(
                  order.displayNumber,
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: QuiccColors.brand400),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.customerName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    Text(
                      o.fulfillment.address?.oneLine ?? 'No address',
                      style: TextStyle(color: context.palette.textSecondary),
                    ),
                  ],
                ),
              ),
              Ticker(
                interval: const Duration(seconds: 15),
                builder: (context, now) {
                  final r = order.status.readyAt;
                  return Text(
                    r == null ? '' : 'ready ${minutes(now.difference(r))}',
                    style: TextStyle(color: context.palette.textMuted),
                  );
                },
              ),
              const SizedBox(width: 12),
              Text(money(o.money.totalCents), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunCard extends StatelessWidget {
  final _Run run;
  final bool busy;
  final VoidCallback? onReturned;
  const _RunCard({required this.run, required this.busy, required this.onReturned});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.delivery_dining, color: QuiccColors.brand400, size: 28),
                      const SizedBox(width: 10),
                      Text(run.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 16),
                      Ticker(
                        builder: (context, now) {
                          final t = run.outAt;
                          if (t == null) return const SizedBox.shrink();
                          final d = now.difference(t);
                          return Text(
                            'out ${duration(d)}',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              color: d.inMinutes >= 45 ? QuiccColors.statusVoided : context.palette.textSecondary,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (run.orders.isEmpty)
                    Text('No orders on this run.', style: TextStyle(color: context.palette.textMuted)),
                  for (final o in run.orders)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${o.displayNumber}  ${o.order.customerName} · ${o.order.fulfillment.address?.oneLine ?? ''}',
                        style: TextStyle(color: context.palette.textSecondary, fontSize: 15),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              height: 60,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: QuiccColors.statusPaid,
                  foregroundColor: QuiccColors.brand900,
                ),
                onPressed: (busy || onReturned == null) ? null : onReturned,
                icon: busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.home_outlined),
                label: Text(onReturned == null ? 'DRIVER REMOVED' : 'I HAVE RETURNED'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
