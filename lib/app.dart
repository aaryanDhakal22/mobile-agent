import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'core/device_platform.dart';
import 'core/providers.dart';
import 'core/storage.dart';
import 'features/alert/new_order_alert.dart';
import 'features/diagnose/diagnose_entry.dart';
import 'features/home/home_screen.dart';
import 'features/setup/setup_controller.dart';
import 'features/setup/setup_entry.dart';
import 'features/setup/setup_wizard.dart';
import 'features/update/update_gate.dart';
import 'theme/quicc_theme.dart';

class MobileAgentApp extends ConsumerStatefulWidget {
  const MobileAgentApp({super.key});

  @override
  ConsumerState<MobileAgentApp> createState() => _MobileAgentAppState();
}

class _MobileAgentAppState extends ConsumerState<MobileAgentApp> {
  late final AppLifecycleListener _lifecycle;
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // FIX IT buttons anywhere (setup's test print included) open the guides.
    installGuideHook();
    _keepAwake();
    // Back in the foreground: re-assert the wakelock, reconnect SSE now
    // (skipping any backoff) and refetch.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _keepAwake();
        if (ref.read(pairingProvider) != null) ref.read(floorProvider.notifier).resume();
      },
    );
    scheduleMicrotask(_quickCheckOnce);
  }

  void _keepAwake() {
    WakelockPlus.enable().catchError((Object _) {});
  }

  /// A tablet upgraded from 1.2.0 skips the wizard (it is already paired) but
  /// ringing with the screen off needs permissions it never asked for: offer
  /// the tablet checks once.
  Future<void> _quickCheckOnce() async {
    final storage = ref.read(storageProvider);
    if (ref.read(pairingProvider) == null || ref.read(setupActiveProvider)) return;
    if (storage.getJson(AppStorage.kTabletChecksPrompted) != null) return;
    final c = await ref.read(devicePlatformProvider).checks();
    if (c == null) return;
    await storage.setJson(AppStorage.kTabletChecksPrompted, '1');
    final ctx = _navigator.currentContext;
    if (c.allGood || ctx == null || !ctx.mounted) return;
    final go = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: const Text('Quick tablet check'),
        content: const Text(
          'Quibase can now ring even when the screen is off or another app is open. '
          'It needs a few Android settings — it takes a minute.',
          style: TextStyle(fontSize: 17),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('LATER')),
          FilledButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('CHECK NOW')),
        ],
      ),
    );
    if (go == true) {
      await _navigator.currentState?.push(MaterialPageRoute<void>(builder: (_) => const TabletChecksScreen()));
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paired = ref.watch(pairingProvider.select((p) => p != null));
    final setup = ref.watch(setupActiveProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Quibase',
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      theme: QuiccTheme.light(),
      darkTheme: QuiccTheme.dark(),
      themeMode: themeMode,
      home: setup ? const SetupWizard() : const HomeScreen(),
      // The alarm (full-screen alert + "still ringing" banner) rides above
      // every route — the setup wizard included, once paired — so it shows
      // over order detail screens and dialogs too. A newer Quibase on the
      // agent locks everything below the alarm until installed (UpdateGate):
      // the new-order alert stays on top, so orders can always be accepted.
      builder: (context, child) =>
          paired ? pairedOverlays(child ?? const SizedBox.shrink()) : (child ?? const SizedBox.shrink()),
    );
  }
}

/// What rides above every route once paired: the alarm on top of the update
/// lock (UpdateGate) on top of the app.
Widget pairedOverlays(Widget child) => AlarmHost(child: UpdateGate(child: child));
