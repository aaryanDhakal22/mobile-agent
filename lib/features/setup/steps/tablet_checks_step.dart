import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/device_platform.dart';
import '../../../theme/quicc_colors.dart';
import '../setup_texts.dart';
import '../setup_widgets.dart';

/// Reads the tablet checks now, again whenever the app comes back from a
/// settings screen, and every few seconds (volume buttons don't resume the
/// app). Off-device it stays null.
class TabletChecksPanel extends ConsumerStatefulWidget {
  /// Called with the latest checks (null off-device).
  final ValueChanged<DeviceChecks?>? onChanged;
  const TabletChecksPanel({super.key, this.onChanged});

  @override
  ConsumerState<TabletChecksPanel> createState() => _TabletChecksPanelState();
}

class _TabletChecksPanelState extends ConsumerState<TabletChecksPanel> {
  DeviceChecks? _c;
  bool _loaded = false;
  late final AppLifecycleListener _lifecycle;
  Timer? _poll;
  bool _askedNotifications = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _read);
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _read());
    scheduleMicrotask(_read);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    final c = await ref.read(devicePlatformProvider).checks();
    if (!mounted) return;
    setState(() {
      _c = c;
      _loaded = true;
    });
    widget.onChanged?.call(c);
  }

  Future<void> _fixNotifications() async {
    final dp = ref.read(devicePlatformProvider);
    // The first tap shows Android's own "Allow notifications?" (the row
    // updates when it's answered); once that was refused, only the settings
    // page can change it.
    if (!_askedNotifications) {
      _askedNotifications = true;
      await dp.requestNotifications();
      return;
    }
    await dp.openSettings(DeviceSetting.notifications);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final c = _c;
    if (c == null) {
      return const Center(child: Text("These checks only run on the tablet itself.", style: TextStyle(fontSize: 18)));
    }
    final dp = ref.read(devicePlatformProvider);
    final pct = c.alarmPercent;
    return ListView(
      children: [
        CheckRow(
          icon: Icons.notifications_active,
          label: 'Notifications',
          detail: c.notifications ? 'Allowed' : 'Needed so orders ring when the app is in the background',
          info: SetupInfo.notifications,
          ok: c.notifications,
          actionLabel: 'ALLOW',
          onAction: _fixNotifications,
        ),
        CheckRow(
          icon: Icons.fullscreen,
          label: 'Full-screen alerts',
          detail: c.fullScreen ? 'Allowed' : 'Lets a new order turn the screen on',
          info: SetupInfo.fullScreen,
          ok: c.fullScreen,
          actionLabel: 'OPEN SETTINGS',
          onAction: () => dp.openSettings(DeviceSetting.fullScreen),
        ),
        CheckRow(
          icon: Icons.battery_charging_full,
          label: 'Battery saving off',
          detail: c.battery ? 'Quibase stays awake' : 'Android may put Quibase to sleep',
          info: SetupInfo.battery,
          ok: c.battery,
          actionLabel: 'TURN OFF',
          onAction: () => dp.openSettings(DeviceSetting.battery),
        ),
        CheckRow(
          icon: Icons.system_update,
          label: 'App updates allowed',
          detail: c.installs ? 'Allowed' : 'Allow Quibase to install its own updates',
          info: SetupInfo.installs,
          ok: c.installs,
          actionLabel: 'ALLOW',
          onAction: () => dp.openSettings(DeviceSetting.installs),
        ),
        CheckRow(
          icon: Icons.volume_up,
          label: 'Order alarm volume',
          detail: pct == null
              ? null
              : c.alarmQuiet
              ? 'Only $pct% — turn it up with the volume buttons'
              : '$pct%',
          info: SetupInfo.volume,
          ok: !c.alarmQuiet,
          actionLabel: 'SOUND SETTINGS',
          onAction: () => dp.openSettings(DeviceSetting.sound),
        ),
      ],
    );
  }
}

/// Asks before leaving the checks with something still off.
Future<bool> confirmChecksIncomplete(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Some checks are not done'),
        content: const Text(
          'Orders might not ring when the screen is off or another app is open. '
          'You can come back to this any time in Settings.',
          style: TextStyle(fontSize: 17),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('FIX THEM')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: QuiccColors.statusFiring),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('CONTINUE ANYWAY'),
          ),
        ],
      ),
    ) ??
    false;
