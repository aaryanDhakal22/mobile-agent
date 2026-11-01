import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import '../drivers/driver_dialog.dart';
import 'settings_card.dart';

const kDriversSettingsInfo = InfoText(
  'Drivers',
  'Your drivers, set up once: their name, their Driver # (the Employee Number on the POS — how '
      'the POS and the Pi know it is them) and their phone in Pushover (SEND OUT sends them the '
      'route; SEND TEST tries it).\n\n'
      'The bin takes a driver off the list for good — when someone stops working here, not at the '
      'end of a shift. Past orders and shift records keep their name. A driver who is out on a run '
      'can\'t be removed until they are back.\n\n'
      'SHIFTS shows who clocked in and out over the last 7 days.\n\n'
      'Clocking in and out happens on the Drivers tab and the driver button.',
);

/// The agent refuses (409 `driver_not_available`) to remove a driver who is
/// out on a run.
String removeDriverOutMessage(String name) =>
    "Can't remove a driver who is out on a run — tap I HAVE RETURNED for $name on Deliveries first.";

/// Settings → Drivers (2.0.0): add, edit and remove drivers, and the 7-day
/// shifts — moved off the Drivers tab, which is for the shift itself.
class DriversSettingsCard extends ConsumerStatefulWidget {
  const DriversSettingsCard({super.key});

  @override
  ConsumerState<DriversSettingsCard> createState() => _DriversSettingsCardState();
}

class _DriversSettingsCardState extends ConsumerState<DriversSettingsCard> {
  FloorController get _floor => ref.read(floorProvider.notifier);

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
      () => _floor.createDriver(
        r.name,
        posNumber: r.posNumber.isEmpty ? null : r.posNumber,
        pushoverDevice: r.pushoverDevice.isEmpty ? null : r.pushoverDevice,
      ),
      'Could not add ${r.name}',
    );
    if (ok && mounted) toast(context, '${r.name} added — clock them in when they start');
  }

  /// Name, Driver # (their SoftTouch Employee Number) and phone (Pushover
  /// device, with SEND TEST); only what changed is sent.
  Future<void> _edit(Driver d) async {
    final r = await driverDialog(
      context,
      title: 'Edit driver',
      name: d.name,
      posNumber: d.posNumber ?? '',
      pushoverDevice: d.pushoverDevice,
      onSendTest: () => _floor.testRoute(d.id),
    );
    if (r == null || r.name.isEmpty || !mounted) return;
    final name = r.name == d.name ? null : r.name;
    final number = r.posNumber == (d.posNumber ?? '') ? null : r.posNumber;
    final device = r.pushoverDevice == d.pushoverDevice ? null : r.pushoverDevice;
    if (name == null && number == null && device == null) return;
    await _run(
      () => _floor.updateDriver(d.id, name: name, posNumber: number, pushoverDevice: device),
      'Could not save ${d.name}',
    );
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

  @override
  Widget build(BuildContext context) {
    final drivers = [...ref.watch(floorProvider.select((s) => s.drivers))]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return SettingsCard(
      title: 'Drivers',
      info: kDriversSettingsInfo,
      subtitle: 'Name, Driver # and phone. Clock in and out on the Drivers tab.',
      children: [
        Row(
          children: [
            FilledButton.icon(
              key: const ValueKey('add-driver'),
              onPressed: _add,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('ADD DRIVER'),
            ),
            QuiccSpace.gapMd,
            TextButton.icon(
              key: const ValueKey('driver-shifts'),
              onPressed: () => showDialog<void>(context: context, builder: (_) => const ShiftsDialog()),
              icon: const Icon(Icons.history),
              label: const Text('SHIFTS'),
            ),
          ],
        ),
        QuiccSpace.gapMd,
        if (drivers.isEmpty)
          Text(
            'No drivers yet. Add them once, then clock them in when they start a shift.',
            style: QuiccType.text(QuiccType.body, color: context.palette.textMuted),
          ),
        for (final d in drivers)
          Padding(
            key: ValueKey('driver-setting-${d.id}'),
            padding: const EdgeInsets.only(bottom: QuiccSpace.xs),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
                      Text(
                        [
                          ?driverNumberLabel(d.posNumber),
                          d.pushoverDevice.isEmpty ? 'no phone' : 'phone ${d.pushoverDevice}',
                        ].join(' · '),
                        style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('edit-driver-${d.id}'),
                  tooltip: 'Edit',
                  onPressed: () => _edit(d),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: ValueKey('remove-driver-${d.id}'),
                  tooltip: 'Remove',
                  onPressed: () => _remove(d),
                  icon: const Icon(Icons.delete_outline, color: QuiccColors.statusVoided),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Shift records of the last 7 days (`GET /api/drivers/shifts?days=7`) — who
/// worked when, for reports. Not wages.
class ShiftsDialog extends ConsumerWidget {
  const ShiftsDialog({super.key});

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
                  child: Text(
                    'No shifts in the last 7 days.',
                    style: QuiccType.text(QuiccType.body, color: context.palette.textMuted),
                  ),
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
