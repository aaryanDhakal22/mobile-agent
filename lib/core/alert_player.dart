import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
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
}

/// Plays the cashier-selected chime on loop until [stop] is called. Routed
/// through the Android alarm stream (`AndroidUsageType.alarm`) so it stays
/// audible even when media volume is down — the DoorDash "can't miss it"
/// posture. `stayAwake: true` keeps the CPU alive so the chime doesn't cut
/// out if the screen dims during a slow dismiss.
class AlertPlayer {
  static final AudioPlayer _player = AudioPlayer(playerId: 'quicc-new-order');
  static bool _contextConfigured = false;
  static String? _currentAsset;

  static Future<void> _ensureContext() async {
    if (_contextConfigured) return;
    await _player.setAudioContext(AudioContext(
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
    ));
    await _player.setReleaseMode(ReleaseMode.loop);
    _contextConfigured = true;
  }

  /// Starts looping [sound]. Cheap to re-call with the same sound — the
  /// source is cached and only re-assigned if the selection changed.
  static Future<void> start(AlertSound sound) async {
    unawaited(HapticFeedback.heavyImpact());
    await _ensureContext();
    if (_currentAsset != sound.asset) {
      await _player.setSource(AssetSource(sound.asset));
      _currentAsset = sound.asset;
    }
    await _player.seek(Duration.zero);
    await _player.resume();
  }

  static Future<void> stop() async {
    if (!_contextConfigured) return;
    await _player.stop();
  }
}
