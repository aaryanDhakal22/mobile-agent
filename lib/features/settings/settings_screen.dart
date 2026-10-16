import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/alert_player.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/sse.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _addrCtrl;
  Timer? _previewTimer;

  @override
  void initState() {
    super.initState();
    _addrCtrl = TextEditingController(text: _shortAddress(ref.read(pairingProvider)?.address ?? ''));
  }

  @override
  void dispose() {
    _addrCtrl.dispose();
    if (_previewTimer != null) {
      _previewTimer!.cancel();
      AlertPlayer.stop(preview: true);
    }
    super.dispose();
  }

  static String _shortAddress(String base) => base.replaceFirst(RegExp(r'^http://'), '');

  /// Plays the chime for 2 s — never over the real alarm (they share one
  /// player; AlertPlayer ignores previews while the alarm rings).
  void _previewSound(AlertSound sound) {
    if (AlertPlayer.alarmActive) {
      toast(context, 'The order alarm is ringing — accept the order first.');
      return;
    }
    _previewTimer?.cancel();
    AlertPlayer.start(sound, preview: true);
    _previewTimer = Timer(const Duration(seconds: 2), _stopPreview);
  }

  void _stopPreview() {
    final wasPreviewing = _previewTimer != null;
    _previewTimer?.cancel();
    _previewTimer = null;
    if (wasPreviewing) AlertPlayer.stop(preview: true);
    if (mounted) setState(() {});
  }

  Future<void> _saveAddress() async {
    final next = normalizeAgentAddress(_addrCtrl.text);
    if (next.isEmpty) return;
    await ref.read(pairingProvider.notifier).setAddress(next);
    if (mounted) toast(context, 'Agent address set to ${_shortAddress(next)}');
  }

  Future<void> _unpair() async {
    final ok = await confirmDialog(
      context,
      title: 'Unpair this tablet?',
      message:
          'The tablet revokes its key on the agent and goes back to the pairing screen. '
          'If the agent can\'t be reached, revoke it in the agent web UI (Settings → Counter tablets).',
      confirm: 'UNPAIR',
      destructive: true,
    );
    if (!ok) return;
    try {
      // Best effort: revoke the key on the agent so it stops working.
      await ref.read(agentClientProvider)?.unpairSelf();
    } catch (_) {
      // Agent unreachable — the key is still forgotten locally.
    }
    await ref.read(pairingProvider.notifier).unpair();
  }

  @override
  Widget build(BuildContext context) {
    final pairing = ref.watch(pairingProvider);
    final selectedSound = ref.watch(alertSoundProvider);
    final fs = ref.watch(floorProvider);
    final unsynced = fs.floor?.unsyncedEvents ?? 0;
    final isPreviewing = _previewTimer?.isActive ?? false;

    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const PaneHeader(title: 'Settings'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Eyebrow('Agent'),
                const SizedBox(height: 6),
                Text(
                  'LAN address of the agent (host:port). Keeps the same pairing key.',
                  style: TextStyle(color: context.palette.textSecondary),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _addrCtrl,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(hintText: '192.168.1.219:8080'),
                        onSubmitted: (_) => _saveAddress(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(onPressed: _saveAddress, child: const Text('SAVE')),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 32,
                  runSpacing: 8,
                  children: [
                    _Info('Connection', switch (fs.connection) {
                      SseStatus.connected => 'Live',
                      SseStatus.connecting => 'Connecting…',
                      SseStatus.disconnected => 'Disconnected — retrying',
                    }),
                    _Info('Last sync', fs.lastSyncAt == null ? '—' : clock(fs.lastSyncAt)),
                    _Info('Sync backlog', '$unsynced event${unsynced == 1 ? '' : 's'}', warn: unsynced > 0),
                  ],
                ),
                if (unsynced > 0) ...[
                  const SizedBox(height: 6),
                  Text(
                    'The agent has floor changes it has not yet sent to the Quicc server (it keeps retrying).',
                    style: TextStyle(color: context.palette.textMuted, fontSize: 13),
                  ),
                ],
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
                const Eyebrow('This tablet'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pairing?.deviceName.isNotEmpty == true ? pairing!.deviceName : 'Paired tablet',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          if (pairing?.deviceId.isNotEmpty == true)
                            Text(
                              'device ${pairing!.deviceId}',
                              style: TextStyle(color: context.palette.textMuted, fontSize: 12),
                            ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: QuiccColors.statusVoided),
                      onPressed: _unpair,
                      icon: const Icon(Icons.link_off),
                      label: const Text('UNPAIR'),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Eyebrow('Order chime'),
                const SizedBox(height: 6),
                Text(
                  'Loops full-screen until every new order is accepted.',
                  style: TextStyle(color: context.palette.textSecondary),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<AlertSound>(
                        initialValue: selectedSound,
                        decoration: const InputDecoration(prefixIcon: Icon(Icons.music_note_outlined)),
                        items: [for (final s in AlertSound.values) DropdownMenuItem(value: s, child: Text(s.label))],
                        onChanged: (next) {
                          if (next == null) return;
                          ref.read(alertSoundProvider.notifier).set(next);
                          _previewSound(next);
                          setState(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 56,
                      child: isPreviewing
                          ? OutlinedButton.icon(
                              onPressed: _stopPreview,
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
      ],
    );
  }
}

class _Info extends StatelessWidget {
  final String label;
  final String value;
  final bool warn;
  const _Info(this.label, this.value, {this.warn = false});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Eyebrow(label),
      const SizedBox(height: 2),
      Text(
        value,
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: warn ? QuiccColors.statusFiring : null),
      ),
    ],
  );
}
