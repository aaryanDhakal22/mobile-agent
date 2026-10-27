import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Plays an order-callout preview (1.8.1) — the WAV the store hub made for
/// Settings › Order callout › ON THIS TABLET — once, through the tablet's own
/// speaker. Tests swap in a fake via [calloutPreviewPlayerProvider].
abstract class CalloutPreviewPlayer {
  /// Plays [wav] (a whole WAV file). Throws when it can't start.
  Future<void> play(Uint8List wav);
}

/// On the media stream (the tablet's media volume governs it), briefly
/// ducking other audio. Plays from a temp file: more reliable on Android
/// than a bytes source.
class AudioplayersCalloutPreviewPlayer implements CalloutPreviewPlayer {
  AudioPlayer? _p;
  bool _configured = false;

  @override
  Future<void> play(Uint8List wav) async {
    final p = _p ??= AudioPlayer(playerId: 'quicc-callout-preview');
    if (!_configured) {
      await p.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.speech,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
          iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
        ),
      );
      await p.setReleaseMode(ReleaseMode.stop);
      _configured = true;
    }
    await p.stop();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/callout_preview.wav');
    await file.writeAsBytes(wav, flush: true);
    await p.play(DeviceFileSource(file.path, mimeType: 'audio/wav'), volume: 1.0);
  }
}

final calloutPreviewPlayerProvider = Provider<CalloutPreviewPlayer>((_) => AudioplayersCalloutPreviewPlayer());
