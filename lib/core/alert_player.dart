import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The set of bundled chimes. Add a new entry here AND add the file to the
/// `assets:` list in pubspec.yaml — the Settings dropdown reads this enum
/// directly.
enum AlertSound {
  defaultSound(label: 'Default', asset: 'sounds/default.mp3'),
  ddlg(label: 'DDLG', asset: 'sounds/ddlg.mp3'),
  dhoom(label: 'Dhoom', asset: 'sounds/dhoom.mp3'),
  indian(label: 'Indian', asset: 'sounds/indian.mp3'),
  nokia(label: 'Nokia', asset: 'sounds/nokia.mp3');

  final String label;
  final String asset;
  const AlertSound({required this.label, required this.asset});

  static AlertSound byName(String? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return defaultSound;
  }
}

/// The audio operations AlertPlayer needs — the real one is audioplayers;
/// tests swap in a fake via [AlertPlayer.sink].
abstract class AlarmSink {
  Future<void> configure();
  Future<void> setSource(String asset);
  Future<void> setVolume(double volume);
  Future<void> seek(Duration position);
  Future<void> resume();
  Future<void> stop();
  void haptic();
}

/// Plays through the Android alarm stream (`AndroidUsageType.alarm`) so it
/// stays audible even when media volume is down — the DoorDash "can't miss
/// it" posture. `stayAwake: true` keeps the CPU alive so the chime doesn't cut
/// out if the screen dims (needs the WAKE_LOCK permission in the manifest).
class AudioplayersAlarmSink implements AlarmSink {
  AudioPlayer? _p;
  AudioPlayer get _player => _p ??= AudioPlayer(playerId: 'quicc-new-order');

  @override
  Future<void> configure() async {
    await _player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: true,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.duckOthers},
        ),
      ),
    );
    await _player.setReleaseMode(ReleaseMode.loop);
  }

  @override
  Future<void> setSource(String asset) => _player.setSource(AssetSource(asset));

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() => _player.stop();

  @override
  void haptic() => unawaited(HapticFeedback.heavyImpact().catchError((Object _) {}));
}

/// Plays the cashier-selected chime on loop until [stop] is called.
///
/// Never throws: a failed start is logged and leaves [isPlaying] false, so the
/// alarm host retries it on the next escalation / floor refresh
/// ([shouldRetry]). A generation token makes a [stop] that lands while
/// [start] is still awaiting the player win — the pending start never resumes.
class AlertPlayer {
  @visibleForTesting
  static AlarmSink sink = AudioplayersAlarmSink();

  static bool _contextConfigured = false;
  static String? _currentAsset;

  /// Bumped by every start and stop; a start that sees a newer generation
  /// after an await gives up.
  static int _gen = 0;
  static bool _starting = false;
  static bool _playing = false;
  static DateTime? _lastFailure;

  /// Minimum gap between automatic retries of a failed start.
  static const Duration retryAfter = Duration(seconds: 5);

  /// Volume while ringing normally, and once an order has escalated.
  static const double normalVolume = 0.7;
  static const double loudVolume = 1.0;

  /// True while the real new-order alarm owns the player; previews then
  /// neither start nor stop it.
  static bool _alarmActive = false;
  static bool get alarmActive => _alarmActive;

  /// The player is (as far as we know) looping the chime.
  static bool get isPlaying => _playing;
  static bool get isStarting => _starting;

  /// The alarm should be ringing but isn't, and no start is in flight (and
  /// the last failure, if any, was over [retryAfter] ago).
  static bool shouldRetry([DateTime? now]) {
    if (!_alarmActive || _playing || _starting) return false;
    final f = _lastFailure;
    return f == null || (now ?? DateTime.now()).difference(f) >= retryAfter;
  }

  /// Starts (or restarts, from the top) looping [sound]. Cheap to re-call
  /// with the same sound — the source is only re-assigned if the selection
  /// changed. A [preview] (Settings sampling) is ignored while the alarm
  /// rings. Resolves true once the player is playing; false if it was
  /// superseded by a stop / newer start, or failed (logged).
  static Future<bool> start(AlertSound sound, {bool loud = false, bool preview = false}) async {
    if (preview && _alarmActive) return false;
    if (!preview) _alarmActive = true;
    final gen = ++_gen;
    _starting = true;
    bool current() => gen == _gen;
    try {
      sink.haptic();
      if (!_contextConfigured) {
        await sink.configure();
        _contextConfigured = true;
        if (!current()) return false;
      }
      if (_currentAsset != sound.asset) {
        _currentAsset = null;
        await sink.setSource(sound.asset);
        _currentAsset = sound.asset;
        if (!current()) return false;
      }
      await sink.setVolume(loud ? loudVolume : normalVolume);
      if (!current()) return false;
      await sink.seek(Duration.zero);
      if (!current()) return false;
      await sink.resume();
      if (!current()) return false;
      _playing = true;
      _lastFailure = null;
      return true;
    } catch (e, st) {
      if (current()) {
        _playing = false;
        _lastFailure = DateTime.now();
      }
      debugPrint('AlertPlayer.start failed (will retry): $e\n$st');
      return false;
    } finally {
      if (current()) _starting = false;
    }
  }

  /// Switches an already-ringing alarm between normal and loud.
  static Future<void> setLoud(bool loud) async {
    if (!_contextConfigured || !_playing) return;
    if (loud) sink.haptic();
    try {
      await sink.setVolume(loud ? loudVolume : normalVolume);
    } catch (e) {
      debugPrint('AlertPlayer.setLoud failed: $e');
    }
  }

  /// Stops the player. A [preview] stop never silences the real alarm.
  static Future<void> stop({bool preview = false}) async {
    if (preview && _alarmActive) return;
    if (!preview) _alarmActive = false;
    _gen++;
    _starting = false;
    _playing = false;
    _lastFailure = null;
    if (!_contextConfigured) return;
    try {
      await sink.stop();
    } catch (e) {
      debugPrint('AlertPlayer.stop failed: $e');
    }
  }

  @visibleForTesting
  static void resetForTest(AlarmSink s) {
    sink = s;
    _contextConfigured = false;
    _currentAsset = null;
    _gen = 0;
    _starting = false;
    _playing = false;
    _lastFailure = null;
    _alarmActive = false;
  }
}
