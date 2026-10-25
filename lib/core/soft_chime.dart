import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The gentle two-note chime for a new POS delivery (1.5.0) — once, never
/// looped. POS orders never ring: the cashier keyed them, the kitchen only
/// needs a heads-up that a delivery joined the pool.
const String kSoftChimeAsset = 'sounds/soft_chime.wav';

/// Plays the soft chime once. Tests swap in a fake via [softChimeProvider].
abstract class SoftChime {
  Future<void> play();
}

/// Through the notification stream (not the alarm stream the new-order ring
/// uses), so the tablet's notification volume governs it and it ducks other
/// audio briefly instead of taking it over.
class AudioplayersSoftChime implements SoftChime {
  AudioPlayer? _p;
  bool _configured = false;

  @override
  Future<void> play() async {
    try {
      final p = _p ??= AudioPlayer(playerId: 'quicc-soft-chime');
      if (!_configured) {
        await p.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              isSpeakerphoneOn: false,
              stayAwake: false,
              contentType: AndroidContentType.sonification,
              usageType: AndroidUsageType.notification,
              audioFocus: AndroidAudioFocus.gainTransientMayDuck,
            ),
            iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
          ),
        );
        await p.setReleaseMode(ReleaseMode.stop);
        _configured = true;
      }
      await p.stop();
      await p.play(AssetSource(kSoftChimeAsset), volume: 0.8);
    } catch (e) {
      // A missed chime is harmless: the order is already on the screen.
      debugPrint('SoftChime.play failed: $e');
    }
  }
}

final softChimeProvider = Provider<SoftChime>((_) => AudioplayersSoftChime());
