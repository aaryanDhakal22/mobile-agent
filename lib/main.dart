import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/ring_bridge.dart';

// On Android this runs once per process, at process start (QuibaseApp keeps
// one engine), possibly before any screen exists — so nothing here may need
// an Activity. Landscape is also pinned in the manifest.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } catch (_) {
    // No Activity attached yet.
  }
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
  startRingBridge(container);
  runApp(UncontrolledProviderScope(container: container, child: const MobileAgentApp()));
}
