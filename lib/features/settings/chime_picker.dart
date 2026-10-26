import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/alert_player.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../theme/quicc_spacing.dart';

/// The order chime: a dropdown of the sounds (saved at once, previewed on
/// change) and PREVIEW / STOP. Used in Settings and the setup wizard.
class ChimePicker extends ConsumerStatefulWidget {
  const ChimePicker({super.key});

  @override
  ConsumerState<ChimePicker> createState() => _ChimePickerState();
}

class _ChimePickerState extends ConsumerState<ChimePicker> {
  Timer? _previewTimer;

  @override
  void dispose() {
    if (_previewTimer != null) {
      _previewTimer!.cancel();
      AlertPlayer.stop(preview: true);
    }
    super.dispose();
  }

  /// Plays the chime for 2 s — never over the real alarm (they share one
  /// player; AlertPlayer ignores previews while the alarm rings).
  void _preview(AlertSound sound) {
    if (AlertPlayer.alarmActive) {
      toast(context, 'The order alarm is ringing — accept the order first.');
      return;
    }
    _previewTimer?.cancel();
    AlertPlayer.start(sound, preview: true);
    _previewTimer = Timer(const Duration(seconds: 2), _stop);
    setState(() {});
  }

  void _stop() {
    final wasPreviewing = _previewTimer != null;
    _previewTimer?.cancel();
    _previewTimer = null;
    if (wasPreviewing) AlertPlayer.stop(preview: true);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(alertSoundProvider);
    final previewing = _previewTimer?.isActive ?? false;
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<AlertSound>(
            initialValue: selected,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.music_note_outlined)),
            items: [for (final s in AlertSound.values) DropdownMenuItem(value: s, child: Text(s.label))],
            onChanged: (next) {
              if (next == null) return;
              ref.read(alertSoundProvider.notifier).set(next);
              _preview(next);
            },
          ),
        ),
        QuiccSpace.gapMd,
        SizedBox(
          height: 56,
          child: previewing
              ? OutlinedButton.icon(onPressed: _stop, icon: const Icon(Icons.stop, size: 18), label: const Text('STOP'))
              : OutlinedButton.icon(
                  onPressed: () => _preview(selected),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('PREVIEW'),
                ),
        ),
      ],
    );
  }
}
