import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'time.dart';

/// Header carrying this tablet's Quibase version ("1.6.0+160") on every
/// request to the agent and on the `/api/events` stream (1.6.0). The agent
/// ignores it until 2.2.0, which records it per device.
const String kQuibaseVersionHeader = 'X-Quibase-Version';

/// "1.6.0" + 160 → "1.6.0+160" (just the name when there is no code).
String quibaseVersionString(String name, Object? code) {
  final n = name.trim();
  if (n.isEmpty) return '';
  final c = code is num ? code.toInt() : int.tryParse('${code ?? ''}');
  return c == null || c <= 0 ? n : '$n+$c';
}

/// The installed Quibase version, read once from the Android side
/// ('quibase/install' channel, MainActivity) and then kept.
///
/// Never awaited on the request path: with no Activity (the process started
/// headless by RingService) the channel has no handler, and in widget tests
/// it never answers. Until it is known (the first few ms after start, or a
/// headless process) requests simply go without the header; [current] asks
/// again at most every [retryEvery].
class QuibaseVersion {
  QuibaseVersion._();

  static const MethodChannel _channel = MethodChannel('quibase/install');
  static const Duration retryEvery = Duration(seconds: 30);

  static String? _value;
  static bool _loading = false;
  static DateTime? _lastTry;

  /// "1.6.0+160", or null while not known yet. Reading it starts the lookup.
  static String? get current {
    _kick();
    return _value;
  }

  static void _kick() {
    if (_value != null || _loading) return;
    final now = timeNow();
    final last = _lastTry;
    if (last != null && now.difference(last) < retryEvery) return;
    _loading = true;
    _lastTry = now;
    unawaited(_load());
  }

  static Future<void> _load() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('version');
      final v = quibaseVersionString('${m?['versionName'] ?? ''}', m?['versionCode']);
      if (v.isNotEmpty) _value = v;
    } catch (_) {
      // No channel yet (headless start, tests, desktop): try again later.
    } finally {
      _loading = false;
    }
  }

  /// Tests: let the next [current] ask the channel again.
  @visibleForTesting
  static void debugAllowLookup() {
    _loading = false;
    _lastTry = null;
  }

  /// Tests: pin the version (null = unknown, and no lookup for a while).
  @visibleForTesting
  static void debugSet(String? v) {
    _value = v;
    _loading = false;
    _lastTry = timeNow();
  }
}
