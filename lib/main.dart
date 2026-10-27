import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/frame_stats.dart';
import 'core/providers.dart';
import 'core/ring_bridge.dart';
import 'features/update/updater.dart';

// On Android this runs once per process, at process start (QuibaseApp keeps
// one engine), possibly before any screen exists — so nothing here may need
// an Activity. Landscape is also pinned in the manifest.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Not awaited: with no Activity (the process started by RingService after
  // Android killed it, by a reboot or by a self-update) this platform call
  // never completes, and awaiting it hung main() before the Pi connection —
  // the tablet stayed silent until someone opened the app. The manifest pins
  // landscape anyway.
  unawaited(
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]).catchError((Object _) {}),
  );
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
  startRingBridge(container);
  // Self-update runs headless too: it installs after Close batch even with
  // the screen off (features/update/updater.dart).
  container.read(updaterProvider);
  // Frame timings for diagnostics (tablet.frames) from the first frame.
  container.read(frameStatsProvider);
  runApp(UncontrolledProviderScope(container: container, child: const MobileAgentApp()));
}
