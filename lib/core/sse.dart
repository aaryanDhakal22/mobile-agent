import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'app_version.dart';

/// One dispatched SSE frame.
class SseEvent {
  final String event;
  final String data;
  final String? id;
  const SseEvent(this.event, this.data, {this.id});

  /// Decoded `data:` JSON, or null if it isn't JSON.
  Object? get json {
    try {
      return jsonDecode(data);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'SseEvent($event, ${data.length} bytes)';
}

/// Incremental parser for the `text/event-stream` format. Feed it one line at
/// a time (no trailing newline); a blank line dispatches the buffered frame.
/// Comment lines (`:` — the agent's 25 s keepalive) are ignored.
class SseLineParser {
  String _event = '';
  final List<String> _data = [];
  String? _id;

  /// Returns the dispatched event when [line] completes a frame, else null.
  SseEvent? addLine(String line) {
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.isEmpty) return _dispatch();
    if (line.startsWith(':')) return null;

    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        _data.add(value);
      case 'id':
        _id = value;
      default:
        break; // `retry:` and unknown fields are ignored.
    }
    return null;
  }

  SseEvent? _dispatch() {
    if (_data.isEmpty) {
      _event = '';
      return null;
    }
    final ev = SseEvent(_event.isEmpty ? 'message' : _event, _data.join('\n'), id: _id);
    _event = '';
    _data.clear();
    return ev;
  }

  /// Drops a half-read frame (on reconnect).
  void reset() {
    _event = '';
    _data.clear();
  }
}

enum SseStatus { connecting, connected, disconnected }

/// Reconnect delay after [attempt] consecutive failures: 1 s, 2 s, 4 s … capped
/// at [max].
Duration sseBackoff(int attempt, {Duration max = const Duration(seconds: 30)}) {
  if (attempt <= 0) return const Duration(seconds: 1);
  final secs = math.pow(2, math.min(attempt, 10)).toInt();
  final d = Duration(seconds: secs);
  return d > max ? max : d;
}

/// A self-reconnecting subscription to the agent's `GET /api/events`.
///
/// Every successful (re)connect fires [onConnected] — the caller refetches
/// its state then, since frames can be dropped while disconnected. A 401
/// `device_required` fires [onDeviceRevoked] and stops for good.
class AgentEventStream {
  final String baseUrl;
  final String deviceKey;
  final void Function(SseEvent event) onEvent;
  final void Function(SseStatus status) onStatus;
  final void Function() onConnected;
  final void Function() onDeviceRevoked;

  /// No bytes (not even a keepalive comment, sent every 25 s) for this long
  /// means the socket is dead: drop it and reconnect.
  final Duration idleTimeout;

  /// A fresh HTTP client per connection attempt (tests inject a fake).
  final http.Client Function() clientFactory;

  /// Wait before reconnect attempt n (0 after a connection that worked).
  final Duration Function(int attempt) backoff;

  /// This tablet's Quibase version for [kQuibaseVersionHeader] (read at each
  /// connect; null = left off). Defaults to [QuibaseVersion].
  final String? Function() appVersion;

  AgentEventStream({
    required String baseUrl,
    required this.deviceKey,
    required this.onEvent,
    required this.onStatus,
    required this.onConnected,
    required this.onDeviceRevoked,
    this.idleTimeout = const Duration(seconds: 70),
    http.Client Function()? clientFactory,
    Duration Function(int attempt)? backoff,
    String? Function()? appVersion,
  }) : baseUrl = normalizeAgentAddress(baseUrl),
       clientFactory = clientFactory ?? http.Client.new,
       backoff = backoff ?? sseBackoff,
       appVersion = appVersion ?? _installedVersion;

  static String? _installedVersion() => QuibaseVersion.current;

  bool _running = false;
  http.Client? _client;
  Completer<void>? _wake;
  int _failures = 0;

  void start() {
    if (_running) return;
    _running = true;
    // Deferred so the first status callback never runs inside the caller's
    // own setup (e.g. a provider's build).
    scheduleMicrotask(() => unawaited(_loop()));
  }

  void stop() {
    _running = false;
    _client?.close();
    _client = null;
    _wakeUp();
  }

  /// Skip the current backoff wait and reconnect now (e.g. app resumed).
  void reconnectNow() {
    _failures = 0;
    _wakeUp();
  }

  void _wakeUp() {
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _loop() async {
    final parser = SseLineParser();
    while (_running) {
      onStatus(SseStatus.connecting);
      final client = clientFactory();
      _client = client;
      try {
        final req = http.Request('GET', Uri.parse('$baseUrl/api/events'))
          ..headers[kDeviceKeyHeader] = deviceKey
          ..headers['Accept'] = 'text/event-stream'
          ..headers['Cache-Control'] = 'no-cache'
          ..headers.addAll(quibaseVersionHeaders(appVersion()));
        final resp = await client.send(req).timeout(const Duration(seconds: 10));
        if (resp.statusCode != 200) {
          final raw = await resp.stream.bytesToString().timeout(const Duration(seconds: 5), onTimeout: () => '');
          final err = AgentClient.exceptionFromResponse(resp.statusCode, raw);
          if (err.isDeviceRevoked) {
            _running = false;
            onStatus(SseStatus.disconnected);
            onDeviceRevoked();
            return;
          }
          throw err;
        }
        _failures = 0;
        parser.reset();
        onStatus(SseStatus.connected);
        onConnected();

        final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter()).timeout(idleTimeout);
        await for (final line in lines) {
          if (!_running) break;
          final ev = parser.addLine(line);
          if (ev != null) onEvent(ev);
        }
        // The agent closed the stream — e.g. it dropped this tablet for
        // falling behind (buffer overflow). Frames were lost: reconnect, and
        // the reconnect's onConnected refetches everything.
      } catch (_) {
        // Refused / dropped / idle timeout — fall through to backoff.
      } finally {
        client.close();
        if (identical(_client, client)) _client = null;
      }
      if (!_running) break;
      onStatus(SseStatus.disconnected);
      final wait = backoff(_failures);
      _failures++;
      _wake = Completer<void>();
      await Future.any([Future<void>.delayed(wait), _wake!.future]);
      _wake = null;
    }
    onStatus(SseStatus.disconnected);
  }
}
