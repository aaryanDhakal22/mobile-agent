import 'package:flutter/services.dart';

/// The Android side of "ring anywhere" (the engine-level `quibase/ring`
/// channel, RingService.kt): a foreground service that keeps Quibase's
/// connection to the Pi alive in the background, and a full-screen new-order
/// notification for when nobody is looking at the app. Every call is a no-op
/// where the channel doesn't exist (tests, desktop).
class RingPlatform {
  static const _ch = MethodChannel('quibase/ring');

  Future<bool> startService(String text) => _call<bool>('startService', {'text': text}).then((v) => v ?? false);
  Future<void> updateService(String text) => _call<void>('updateService', {'text': text});
  Future<void> stopService() => _call<void>('stopService');

  /// Shows the full-screen alarm notification unless the app is on screen.
  Future<bool> showRing({required String title, required String text}) =>
      _call<bool>('showRing', {'title': title, 'text': text}).then((v) => v ?? false);
  Future<void> cancelRing() => _call<void>('cancelRing');

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
