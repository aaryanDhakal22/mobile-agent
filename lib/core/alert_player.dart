import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Plays `assets/sounds/alert.mp3` on loop until [stop] is called. Routed
/// through the Android alarm stream (`AndroidUsageType.alarm`) so it stays
/// audible even when media volume is down — the DoorDash "can't miss it"
/// posture. `stayAwake: true` keeps the CPU alive so the chime doesn't cut
/// out if the screen dims during a slow dismiss.
class AlertPlayer {
  static final AudioPlayer _player = AudioPlayer(playerId: 'quicc-new-order');
  static bool _configured = false;

  static Future<void> _configure() async {
    if (_configured) return;
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
    await _player.setSource(AssetSource('sounds/alert.mp3'));
    _configured = true;
  }

  static Future<void> start() async {
    unawaited(HapticFeedback.heavyImpact());
    await _configure();
    await _player.seek(Duration.zero);
    await _player.resume();
  }

  static Future<void> stop() async {
    if (!_configured) return;
    await _player.stop();
  }
}
