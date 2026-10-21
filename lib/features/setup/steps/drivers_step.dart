import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/friendly_error.dart';
import '../../../core/models.dart';
import '../../../core/providers.dart';
import '../../../theme/quicc_colors.dart';

/// "Who drives tonight?": the roster (restored from the Pi, or empty for a
/// new store), a quick add box, a clock-in switch per driver, drag to reorder.
///
/// Rows keep the order they first appeared in (or the order dragged to): the
/// Pi re-sorts its queue when someone clocks in, and a list that jumps under
/// the finger makes the next tap hit a different driver.
class DriversPanel extends ConsumerStatefulWidget {
  const DriversPanel({super.key});

  @override
  ConsumerState<DriversPanel> createState() => _DriversPanelState();
}

class _DriversPanelState extends ConsumerState<DriversPanel> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Driver ids in the order shown.
  final List<String> _order = [];

  List<Driver> _stable(List<Driver> drivers) {
    final ids = {for (final d in drivers) d.id};
    _order.removeWhere((id) => !ids.contains(id));
    for (final d in drivers) {
      if (!_order.contains(d.id)) _order.add(d.id);
    }
    final byId = {for (final d in drivers) d.id: d};
    return [for (final id in _order) byId[id]!];
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _do(Future<void> Function() op) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await op();
    } catch (e) {
      if (mounted) setState(() => _error = FriendlyError.from(e).short);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final n = _name.text.trim();
    if (n.isEmpty) return;
    await _do(() => ref.read(floorProvider.notifier).createDriver(n));
    if (mounted && _error == null) _name.clear();
  }

  @override
  Widget build(BuildContext context) {
    final drivers = _stable(ref.watch(floorProvider.select((s) => s.drivers)));
    final floor = ref.read(floorProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(fontSize: 20),
                decoration: const InputDecoration(hintText: 'Driver name'),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.person_add),
                label: const Text('ADD'),
              ),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: QuiccColors.statusVoided, fontSize: 16)),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: drivers.isEmpty
              ? Center(
                  child: Text(
                    'No drivers yet. Type a name and tap ADD.',
                    style: TextStyle(fontSize: 18, color: context.palette.textSecondary),
                  ),
                )
              : ReorderableListView(
                  buildDefaultDragHandles: false,
                  onReorder: (from, to) {
                    final list = [...drivers];
                    final d = list.removeAt(from);
                    list.insert(to > from ? to - 1 : to, d);
                    setState(() => _order
                      ..clear()
                      ..addAll(list.map((d) => d.id)));
                    _do(() => floor.reorderDrivers(list));
                  },
                  children: [
                    for (var i = 0; i < drivers.length; i++)
                      Card(
                        key: ValueKey(drivers[i].id),
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: ReorderableDragStartListener(
                            index: i,
                            child: const Icon(Icons.drag_indicator, size: 30),
                          ),
                          title: Text(drivers[i].name, style: const TextStyle(fontSize: 20)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_clockLabel(drivers[i]), style: const TextStyle(fontSize: 16)),
                              Switch(
                                value: drivers[i].status != DriverStatus.off,
                                onChanged: _busy || drivers[i].status == DriverStatus.out
                                    ? null
                                    : (on) => _do(() async {
                                        on ? await floor.clockIn(drivers[i].id) : await floor.clockOut(drivers[i].id);
                                      }),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  String _clockLabel(Driver d) => switch (d.status) {
    DriverStatus.off => 'Off',
    DriverStatus.out => 'Out on a run',
    _ => 'Clocked in',
  };
}
