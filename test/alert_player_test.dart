import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/alert_player.dart';

/// Records calls; any step can be made to throw or to wait on a completer.
class FakeSink implements AlarmSink {
  final List<String> calls = [];
  final Set<String> failOn = {};
  Completer<void>? holdSetSource;

  Future<void> _step(String name) async {
    calls.add(name);
    if (failOn.contains(name)) throw Exception('$name: SecurityException (no WAKE_LOCK)');
  }

  @override
  Future<void> configure() => _step('configure');
  @override
  Future<void> setSource(String asset) async {
    await _step('setSource');
    final h = holdSetSource;
    if (h != null) await h.future;
  }

  @override
  Future<void> setVolume(double volume) => _step('setVolume($volume)');
  @override
  Future<void> seek(Duration position) => _step('seek');
  @override
  Future<void> resume() => _step('resume');
  @override
  Future<void> stop() => _step('stop');
  @override
  void haptic() {}
}

void main() {
  late FakeSink sink;
  setUp(() {
    sink = FakeSink();
    AlertPlayer.resetForTest(sink);
  });

  test('start plays the chime on loop', () async {
    expect(await AlertPlayer.start(AlertSound.nokia), isTrue);
    expect(AlertPlayer.isPlaying, isTrue);
    expect(AlertPlayer.alarmActive, isTrue);
    expect(sink.calls, ['configure', 'setSource', 'setVolume(0.7)', 'seek', 'resume']);
  });

  test('a failing start is caught, logged and retried later', () async {
    sink.failOn.add('configure');
    expect(await AlertPlayer.start(AlertSound.nokia), isFalse, reason: 'never throws');
    expect(AlertPlayer.isPlaying, isFalse);
    expect(AlertPlayer.shouldRetry(), isFalse, reason: 'throttled right after a failure');
    expect(AlertPlayer.shouldRetry(DateTime.now().add(AlertPlayer.retryAfter)), isTrue);

    sink.failOn.clear();
    expect(await AlertPlayer.start(AlertSound.nokia, loud: true), isTrue);
    expect(AlertPlayer.isPlaying, isTrue);
    expect(AlertPlayer.shouldRetry(DateTime.now().add(const Duration(hours: 1))), isFalse);
    expect(sink.calls.last, 'resume');
    expect(sink.calls, contains('setVolume(1.0)'));
  });

  test('a stop landing while start awaits setSource wins — no resume afterwards', () async {
    sink.holdSetSource = Completer<void>();
    final pending = AlertPlayer.start(AlertSound.dhoom);
    await Future<void>.delayed(Duration.zero);
    expect(sink.calls.last, 'setSource');
    expect(AlertPlayer.isStarting, isTrue);

    await AlertPlayer.stop();
    sink.holdSetSource!.complete();
    expect(await pending, isFalse);
    expect(sink.calls, isNot(contains('resume')));
    expect(AlertPlayer.isPlaying, isFalse);
    expect(AlertPlayer.isStarting, isFalse);
    expect(AlertPlayer.shouldRetry(DateTime.now().add(const Duration(hours: 1))), isFalse, reason: 'alarm is off');
  });

  test('restart (escalation) re-runs resume on a player that stopped', () async {
    await AlertPlayer.start(AlertSound.nokia);
    sink.calls.clear();
    expect(await AlertPlayer.start(AlertSound.nokia, loud: true), isTrue);
    expect(sink.calls, ['setVolume(1.0)', 'seek', 'resume'], reason: 'source cached, still resumed');
  });

  test('setLoud / stop never throw', () async {
    await AlertPlayer.start(AlertSound.nokia);
    sink.failOn.addAll({'setVolume(1.0)', 'stop'});
    await AlertPlayer.setLoud(true);
    await AlertPlayer.stop();
    expect(AlertPlayer.isPlaying, isFalse);
  });

  test('a preview never touches the ringing alarm', () async {
    await AlertPlayer.start(AlertSound.nokia);
    sink.calls.clear();
    expect(await AlertPlayer.start(AlertSound.ddlg, preview: true), isFalse);
    await AlertPlayer.stop(preview: true);
    expect(sink.calls, isEmpty);
    expect(AlertPlayer.isPlaying, isTrue);
  });
}
