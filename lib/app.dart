import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'core/providers.dart';
import 'features/alert/new_order_alert.dart';
import 'features/home/home_screen.dart';
import 'features/pairing/pairing_screen.dart';
import 'theme/quicc_theme.dart';

class MobileAgentApp extends ConsumerStatefulWidget {
  const MobileAgentApp({super.key});

  @override
  ConsumerState<MobileAgentApp> createState() => _MobileAgentAppState();
}

class _MobileAgentAppState extends ConsumerState<MobileAgentApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _keepAwake();
    // Back in the foreground: re-assert the wakelock, reconnect SSE now
    // (skipping any backoff) and refetch.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _keepAwake();
        if (ref.read(pairingProvider) != null) ref.read(floorProvider.notifier).resume();
      },
    );
  }

  void _keepAwake() {
    WakelockPlus.enable().catchError((Object _) {});
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paired = ref.watch(pairingProvider.select((p) => p != null));
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'quiccpos',
      debugShowCheckedModeBanner: false,
      theme: QuiccTheme.light(),
      darkTheme: QuiccTheme.dark(),
      themeMode: themeMode,
      home: paired ? const HomeScreen() : const PairingScreen(),
      // The alarm (full-screen alert + "still ringing" banner) rides above
      // every route, so it shows over order detail screens and dialogs too.
      builder: (context, child) =>
          paired ? AlarmHost(child: child ?? const SizedBox.shrink()) : (child ?? const SizedBox.shrink()),
    );
  }
}
