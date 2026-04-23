import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/alert_player.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _urlCtrl;
  bool _autoAcceptPending = false;
  Timer? _previewTimer;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: ref.read(agentBaseUrlProvider));
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _previewTimer?.cancel();
    AlertPlayer.stop();
    super.dispose();
  }

  /// Plays the given chime for 2 s so the cashier can sample it. Cancels any
  /// existing preview so rapid-fire dropdown changes don't overlap.
  void _previewSound(AlertSound sound) {
    _previewTimer?.cancel();
    AlertPlayer.start(sound);
    _previewTimer = Timer(const Duration(seconds: 2), AlertPlayer.stop);
  }

  void _stopPreview() {
    _previewTimer?.cancel();
    _previewTimer = null;
    AlertPlayer.stop();
  }

  void _saveUrl() {
    final trimmed = _urlCtrl.text.trim();
    if (trimmed.isEmpty) return;
    ref.read(agentBaseUrlProvider.notifier).state = trimmed;
    ref.invalidate(arrivedOrdersProvider);
    ref.invalidate(autoAcceptProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Agent URL set to $trimmed'),
      ),
    );
  }

  Future<void> _toggleAutoAccept(bool next) async {
    setState(() => _autoAcceptPending = true);
    try {
      await ref.read(agentClientProvider).setAutoAccept(next);
      ref.invalidate(autoAcceptProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: QuiccColors.statusVoided,
            content: Text('Failed: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _autoAcceptPending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final autoAccept = ref.watch(autoAcceptProvider);
    final selectedSound = ref.watch(alertSoundProvider);
    final isPreviewing = _previewTimer?.isActive ?? false;
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const Text(
          'Settings',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'AGENT BASE URL',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 2,
                    color: context.palette.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'LAN address of the agent computer. Changes apply immediately.',
                  style: TextStyle(color: context.palette.textSecondary),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _urlCtrl,
                        decoration: const InputDecoration(
                          hintText: 'http://192.168.x.x  (nginx) or :8080 (direct)',
                        ),
                        onSubmitted: (_) => _saveUrl(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(onPressed: _saveUrl, child: const Text('SAVE')),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ORDER CHIME',
                            style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 2,
                              color: context.palette.textMuted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'The sound that plays full-screen when a new order arrives.',
                            style: TextStyle(color: context.palette.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<AlertSound>(
                        initialValue: selectedSound,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.music_note_outlined),
                        ),
                        items: [
                          for (final s in AlertSound.values)
                            DropdownMenuItem(
                              value: s,
                              child: Text(s.label),
                            ),
                        ],
                        onChanged: (next) {
                          if (next == null) return;
                          ref.read(alertSoundProvider.notifier).state = next;
                          _previewSound(next);
                          setState(() {}); // refresh isPreviewing flag
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 56,
                      child: isPreviewing
                          ? OutlinedButton.icon(
                              onPressed: () {
                                _stopPreview();
                                setState(() {});
                              },
                              icon: const Icon(Icons.stop, size: 18),
                              label: const Text('STOP'),
                            )
                          : OutlinedButton.icon(
                              onPressed: () {
                                _previewSound(selectedSound);
                                setState(() {});
                              },
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: const Text('PREVIEW'),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: autoAccept.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              ),
              error: (e, _) => Text(
                'Could not load auto-accept: $e',
                style: const TextStyle(color: QuiccColors.statusVoided),
              ),
              data: (enabled) => Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AUTO-ACCEPT',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 2,
                            color: context.palette.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Agent prints incoming orders immediately, without waiting for a tap.',
                          style: TextStyle(color: context.palette.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: enabled,
                    onChanged: _autoAcceptPending ? null : _toggleAutoAccept,
                    activeTrackColor: QuiccColors.brand400,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
