import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/callout_preview_player.dart';
import '../../core/format.dart';
import '../../core/friendly_error.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'settings_card.dart';

const kCalloutInfo = InfoText(
  'Order callout',
  'When a counter order — or a takeout that is already paid — is marked READY on Kitchen, the store speaker '
      'says "Order ready for ticket number one oh two" once. Online orders and deliveries are never called, '
      'and no names are said.\n\n'
      'The store hub speaks it on the computer that plays the music, and turns the music down while it '
      'speaks. Voice: pick one, then hear it ON THIS TABLET (the store hub makes the words and sends them '
      'here — nothing plays in the store) or ON THE STORE SPEAKER. Both say the ticket number typed below. '
      'TEST CALLOUT says that number on the store speaker now.\n\n'
      'Repeat: the words are said 1, 2 or 3 times, a short pause between (the chime only once, the music '
      'down the whole time). The previews repeat too.\n\n'
      'Saved on the Pi for every tablet.',
);

const kFunLinesInfo = InfoText(
  'Fun lines',
  'Now and then a READY callout says a fun line instead of "Order ready for ticket number …". The slider '
      'sets how often (Off = never).\n\n'
      'Your lines: one per line, at most 10, each at most 120 letters. {n} is replaced by the ticket number; a '
      'line without {n} is said before the normal words. Leave it empty for the built-in lines.\n\n'
      'TRY A FUN LINE plays one on the store speaker now (ticket 290), even when the slider is Off.\n\n'
      'Saved on the Pi for every tablet.',
);

const kGuestVoicesInfo = InfoText(
  'Guest voices',
  'Now and then a READY callout is said by a guest voice picked at random instead of the chosen voice. The '
      'slider sets how often (Off = never).\n\n'
      'Pick up to 10 voices, or none for all the online voices. Online voices are made over the internet the '
      'first time a number is said, then kept on the store computer.\n\n'
      'Saved on the Pi for every tablet.',
);

/// TRY A FUN LINE says one with this ticket number.
const int kFunTryNumber = 290;

const kFinishingInfo = InfoText(
  'Finishing orders',
  'A ready pickup stays on the books until it is picked up. Terminal orders (counter and takeout rung at the '
      'POS) finish when SoftTouch closes the check. Online pickups never reach SoftTouch, so they finish by '
      'themselves this many minutes after they were marked ready.\n\n'
      'Finished orders no longer count as open: a Pi update waiting for a quiet moment can run mid-shift.',
);

/// How often the card asks the Pi for the hub's voices while it is shown
/// (a voice being prepared shows its progress).
const Duration kCalloutPoll = Duration(seconds: 10);

/// ON THIS TABLET: how long the Pi may hold each ask for the hub's audio,
/// and how many asks before giving up (the Pi itself answers 504 after 20 s).
const Duration kPreviewWait = Duration(seconds: 8);
const int kPreviewAsks = 4;

/// A preview the hub couldn't make, in plain words.
String calloutPreviewProblem(Object e) {
  if (e is AgentException && !e.isNetwork) {
    switch (e.code) {
      case 'hub_not_connected':
        return "The store hub is not connected, so it can't make the voice.";
      case 'hub_update_needed':
        return 'The store hub needs an update to play a preview on this tablet.';
      case 'not_installed':
        return 'The voice is not installed on the store computer yet.';
      case 'render_failed':
        return e.message.isEmpty || e.message.startsWith('HTTP ')
            ? 'The store computer could not make the voice.'
            : 'The store computer could not make the voice: ${e.message}';
      case 'timeout':
        return "The store hub didn't answer in time — try again.";
      case 'not_found':
        return 'The preview expired — try again.';
      case kSettingsUnsupported:
        return 'This Pi needs an update to play a preview on this tablet.';
    }
    if (e.statusCode == 504) return "The store hub didn't answer in time — try again.";
  }
  return FriendlyError.from(e).short;
}

/// Store settings → Order callout (1.8.0, Pi 2.3.0 + hub 0.2.0): on/off, the
/// voice with PREVIEW, voice volume, how far the music goes down and how fast
/// it comes back, the chime, TEST CALLOUT with a number.
class OrderCalloutCard extends ConsumerStatefulWidget {
  const OrderCalloutCard({super.key});

  @override
  ConsumerState<OrderCalloutCard> createState() => _OrderCalloutCardState();
}

class _OrderCalloutCardState extends ConsumerState<OrderCalloutCard> {
  CalloutView? _view;
  CalloutSettings? _draft; // slider values while dragging
  bool _unsupported = false;
  bool _saving = false;
  bool _speaking = false;
  bool _preparing = false; // ON THIS TABLET: waiting for the hub's audio
  String? _previewError;
  Timer? _poll;
  final _number = TextEditingController(text: '102');
  final _funLines = TextEditingController();
  String? _funLinesFrom; // the saved lines the field was filled from

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _poll = Timer.periodic(kCalloutPoll, (_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _number.dispose();
    _funLines.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    try {
      final v = await client.getCallout();
      if (mounted) {
        setState(() {
          _view = v;
          _syncFunLines(v.settings.funLines);
        });
      }
    } on AgentException catch (e) {
      if (e.code == kSettingsUnsupported && mounted) {
        _poll?.cancel();
        setState(() => _unsupported = true);
      }
    } catch (_) {
      // Offline: keep what we had; the next poll tries again.
    }
  }

  CalloutSettings get _settings => _draft ?? _view?.settings ?? ref.read(floorProvider).settings.callout;

  /// Fills Your lines with the Pi's [saved] lines unless someone is editing
  /// them ([force]: after SAVE).
  void _syncFunLines(String? saved, {bool force = false}) {
    if (saved == null) return;
    if (force || _funLinesFrom == null || _funLines.text == _funLinesFrom) _funLines.text = saved;
    _funLinesFrom = saved;
  }

  Future<CalloutSettings?> _save(CalloutSettings next, String done) async {
    setState(() {
      _draft = next;
      _saving = true;
    });
    try {
      final saved = await ref.read(floorProvider.notifier).saveCallout(next);
      if (!mounted) return saved;
      setState(
        () => _view = CalloutView(
          settings: saved,
          hubConnected: _view?.hubConnected ?? false,
          hub: _view?.hub,
          preview: _view?.preview ?? false,
        ),
      );
      toast(context, done);
      return saved;
    } catch (e) {
      if (mounted) toastError(context, e, lead: 'Callout not changed', area: 'settings');
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _draft = null;
          _saving = false;
        });
      }
    }
  }

  /// SAVE under Your lines.
  Future<void> _saveFunLines() async {
    final text = _funLines.text.trim();
    final saved = await _save(
      _settings.copyWith(funLines: text),
      text.isEmpty ? 'Fun lines: the built-in ones' : 'Fun lines saved',
    );
    if (saved != null && mounted) setState(() => _syncFunLines(saved.funLines ?? text, force: true));
  }

  /// A voice ticked or unticked under Guest voices.
  void _toggleGuest(CalloutSettings s, CalloutVoice v, bool on) {
    final ids = [...s.guestVoiceIds.where((id) => id != v.id), if (on) v.id];
    final done = on ? 'Guest voice: ${v.label}' : 'Not a guest: ${v.label}';
    unawaited(_save(s.copyWith(guestVoices: ids.join(',')), done));
  }

  /// The Ticket # field, or null (with a toast) when it isn't 1–9999.
  int? _ticket() {
    final n = int.tryParse(_number.text.trim());
    if (n == null || n < 1 || n > 9999) {
      toast(context, 'Type a ticket number from 1 to 9999', error: true);
      return null;
    }
    return n;
  }

  /// ON THIS TABLET (Pi 2.3.2 + hub 0.2.2): the Pi asks the hub for the WAV
  /// (feed callout.render), the hub uploads it to the Pi, we fetch and play
  /// it here. Nothing plays in the store.
  Future<void> _previewOnTablet(String voice) async {
    final n = _ticket();
    if (n == null) return;
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    setState(() {
      _preparing = true;
      _previewError = null;
    });
    try {
      final id = await client.calloutPreview(n, voice: voice);
      Uint8List? wav;
      for (var i = 0; i < kPreviewAsks && wav == null; i++) {
        if (!mounted) return;
        wav = await client.calloutPreviewAudio(id, wait: kPreviewWait);
      }
      if (wav == null) {
        throw const AgentException("The store hub didn't answer in time", statusCode: 504, code: 'timeout');
      }
      if (!mounted) return;
      setState(() => _preparing = false);
      try {
        await ref.read(calloutPreviewPlayerProvider).play(wav);
      } catch (e) {
        if (mounted) setState(() => _previewError = 'This tablet could not play the voice.');
        return;
      }
      if (mounted) toast(context, 'Playing #$n on this tablet…');
    } catch (e) {
      if (mounted) setState(() => _previewError = calloutPreviewProblem(e));
    } finally {
      if (mounted && _preparing) setState(() => _preparing = false);
    }
  }

  Future<void> _speak({required String kind, String voice = '', int? number}) async {
    final n = number ?? _ticket();
    if (n == null) return;
    setState(() => _speaking = true);
    try {
      final connected = await ref.read(agentClientProvider)!.calloutTest(n, voice: voice, kind: kind);
      if (!mounted) return;
      toast(
        context,
        connected
            ? switch (kind) {
                'preview' => 'Playing on the store speaker…',
                'fun' => 'Playing a fun line for #$n on the store speaker…',
                _ => 'Calling #$n on the store speaker…',
              }
            : 'Sent — but the store hub is not connected, so nothing will play yet',
        error: !connected,
      );
    } on AgentException catch (e) {
      // An older Pi refuses the kind.
      if (!mounted) return;
      if (kind == 'fun' && e.statusCode == 400) {
        toast(context, 'Update the Pi for fun lines', error: true);
      } else {
        toastError(context, e, lead: 'Nothing played', area: 'settings');
      }
    } catch (e) {
      if (mounted) toastError(context, e, lead: 'Nothing played', area: 'settings');
    } finally {
      if (mounted) setState(() => _speaking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (_unsupported) {
      return const SettingsCard(
        title: 'Order callout',
        info: kCalloutInfo,
        children: [
          ComingSoonRow(
            key: ValueKey('coming-callout'),
            icon: Icons.campaign_outlined,
            title: 'Call out ready orders',
            explanation: '"Order ready for ticket number …" on the store speaker.',
          ),
        ],
      );
    }
    final s = _settings;
    final hub = _view?.hub;
    final voices = hub?.voices ?? const <CalloutVoice>[];
    final voiceId = s.voice.isNotEmpty ? s.voice : (hub?.defaultVoice ?? '');
    final selected = voices.where((v) => v.id == voiceId).firstOrNull;
    final busy = _saving || _view == null;
    final previewBusy = _speaking || _preparing;
    final label = QuiccType.text(QuiccType.body, weight: FontWeight.w600);
    final hint = QuiccType.text(QuiccType.label, color: palette.textSecondary);
    final card = SettingsCard(
      key: const ValueKey('callout-card'),
      title: 'Order callout',
      info: kCalloutInfo,
      subtitle: '"Order ready for ticket number …" on the store speaker when a counter order is READY.',
      children: [
        _HubLine(view: _view),
        SwitchListTile(
          key: const ValueKey('callout-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text('Call out ready orders', style: label),
          subtitle: Text(
            s.enabled
                ? 'On — counter orders, and takeout once it is paid.'
                : 'Off — nothing is said (TEST CALLOUT still plays).',
            style: TextStyle(color: palette.textSecondary),
          ),
          value: s.enabled,
          onChanged: busy ? null : (on) => _save(s.copyWith(enabled: on), on ? 'Callout is on' : 'Callout is off'),
        ),
        const Divider(),
        Text('Voice', style: label),
        QuiccSpace.gapXs,
        DropdownButtonFormField<String>(
          key: const ValueKey('callout-voice'),
          initialValue: selected?.id,
          isExpanded: true,
          hint: Text(voices.isEmpty ? 'The store hub has not sent its voices yet' : 'Pick a voice'),
          items: [
            for (final v in voices)
              DropdownMenuItem(
                value: v.id,
                child: Row(
                  children: [
                    Flexible(child: Text('${v.label} — ${v.about}', overflow: TextOverflow.ellipsis)),
                    if (v.status.isNotEmpty)
                      Text(
                        v.online ? '  · ${v.status}' : '  (${v.status})',
                        key: ValueKey('voice-status-${v.id}'),
                        style: hint,
                      ),
                  ],
                ),
              ),
          ],
          // ~30 voices: a scrolling menu, not one over the whole screen.
          menuMaxHeight: 480,
          onChanged: busy || voices.isEmpty
              ? null
              : (id) {
                  if (id != null && id != voiceId) {
                    final v = voices.firstWhere((x) => x.id == id);
                    unawaited(_save(s.copyWith(voice: id), 'Voice: ${v.label}'));
                  }
                },
        ),
        QuiccSpace.gapSm,
        Wrap(
          spacing: QuiccSpace.md,
          runSpacing: QuiccSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_view?.preview ?? false)
              SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  key: const ValueKey('callout-preview-tablet'),
                  onPressed: previewBusy || voiceId.isEmpty ? null : () => _previewOnTablet(voiceId),
                  icon: const Icon(Icons.tablet_android),
                  label: const Text('ON THIS TABLET'),
                ),
              ),
            SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                key: const ValueKey('callout-preview-store'),
                onPressed: previewBusy || voiceId.isEmpty ? null : () => _speak(kind: 'preview', voice: voiceId),
                icon: const Icon(Icons.speaker_outlined),
                label: const Text('ON THE STORE SPEAKER'),
              ),
            ),
            if (_preparing)
              Row(
                key: const ValueKey('callout-preview-spinner'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  QuiccSpace.gapSm,
                  Text('Preparing…', style: hint),
                ],
              ),
          ],
        ),
        if (_previewError != null)
          Padding(
            padding: const EdgeInsets.only(top: QuiccSpace.xs),
            child: Text(
              _previewError!,
              key: const ValueKey('callout-preview-error'),
              style: QuiccType.text(QuiccType.label, weight: FontWeight.w600, color: QuiccColors.statusVoided),
            ),
          ),
        if (selected != null && selected.online)
          Padding(
            padding: const EdgeInsets.only(top: QuiccSpace.xs),
            child: Text(
              'An online (ElevenLabs) voice: each number is made over the internet the first time it is said, '
              'then kept on the store computer.',
              key: const ValueKey('callout-voice-online'),
              style: hint,
            ),
          ),
        if (hub != null && hub.rendering)
          Padding(
            padding: const EdgeInsets.only(top: QuiccSpace.xs),
            child: Text(
              'Preparing every number for this voice: ${hub.renderingDone} of ${hub.renderingTotal}. '
              'Numbers not ready yet still play, a few seconds later.',
              style: hint,
            ),
          ),
        const Divider(),
        _SliderRow(
          key: const ValueKey('callout-volume'),
          label: 'Voice volume',
          value: s.volume.toDouble(),
          min: 0,
          max: 100,
          divisions: 20,
          text: '${s.volume}%',
          onChanged: busy ? null : (v) => setState(() => _draft = s.copyWith(volume: v.round())),
          onChangeEnd: (v) => _save(s.copyWith(volume: v.round()), 'Voice volume ${v.round()}%'),
        ),
        _SliderRow(
          key: const ValueKey('callout-dip'),
          label: 'Turn the music down by',
          value: s.musicDip.toDouble(),
          min: 0,
          max: 100,
          divisions: 20,
          text: s.musicDip == 0 ? 'not at all' : (s.musicDip == 100 ? 'silent' : '${s.musicDip}%'),
          onChanged: busy ? null : (v) => setState(() => _draft = s.copyWith(musicDip: v.round())),
          onChangeEnd: (v) => _save(s.copyWith(musicDip: v.round()), 'Music dip ${v.round()}%'),
        ),
        _SliderRow(
          key: const ValueKey('callout-restore'),
          label: 'Music comes back over',
          value: s.restoreSeconds,
          min: 0,
          max: 10,
          divisions: 20,
          text: s.restoreSeconds == 0 ? 'at once' : '${_secs(s.restoreSeconds)} s',
          onChanged: busy ? null : (v) => setState(() => _draft = s.copyWith(restoreSeconds: v)),
          onChangeEnd: (v) => _save(s.copyWith(restoreSeconds: v), 'Music back over ${_secs(v)} s'),
        ),
        // Pi 2.3.4: say the phrase 1-3 times (hidden on an older Pi).
        if (s.repeat != null)
          _SliderRow(
            key: const ValueKey('callout-repeat'),
            label: 'Repeat',
            value: s.repeat!.toDouble(),
            min: CalloutSettings.minRepeat.toDouble(),
            max: CalloutSettings.maxRepeat.toDouble(),
            divisions: CalloutSettings.maxRepeat - CalloutSettings.minRepeat,
            text: 'Say it ${s.repeat}×',
            onChanged: busy ? null : (v) => setState(() => _draft = s.copyWith(repeat: v.round())),
            onChangeEnd: (v) => _save(s.copyWith(repeat: v.round()), 'Said ${v.round()}× per callout'),
          ),
        SwitchListTile(
          key: const ValueKey('callout-chime'),
          contentPadding: EdgeInsets.zero,
          title: Text('Chime first', style: label),
          subtitle: Text('A soft two-note chime before the words.', style: TextStyle(color: palette.textSecondary)),
          value: s.chime,
          onChanged: busy ? null : (on) => _save(s.copyWith(chime: on), on ? 'Chime on' : 'Chime off'),
        ),
        const Divider(),
        Row(
          children: [
            SizedBox(
              width: 140,
              child: TextField(
                key: const ValueKey('callout-number'),
                controller: _number,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                decoration: const InputDecoration(labelText: 'Ticket #'),
              ),
            ),
            QuiccSpace.gapMd,
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                key: const ValueKey('callout-test'),
                onPressed: previewBusy ? null : () => _speak(kind: 'test'),
                icon: const Icon(Icons.campaign_outlined),
                label: const Text('TEST CALLOUT'),
              ),
            ),
          ],
        ),
        if (hub?.last != null) ...[
          QuiccSpace.gapSm,
          Text(_lastLine(hub!.last!), key: const ValueKey('callout-last'), style: hint),
        ],
      ],
    );
    // 1.9.2: fun lines and guest voices, each only when the Pi has the
    // setting and the hub says it speaks them.
    final fun = s.funChance != null && (hub?.fun ?? false);
    final guest = s.guestChance != null && (hub?.guest ?? false);
    if (!fun && !guest) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card,
        if (fun) _funCard(s, busy: busy, previewBusy: previewBusy, label: label, hint: hint),
        if (guest) _guestCard(s, voices, busy: busy, label: label, hint: hint),
      ],
    );
  }

  Widget _funCard(
    CalloutSettings s, {
    required bool busy,
    required bool previewBusy,
    required TextStyle label,
    required TextStyle hint,
  }) {
    final chance = s.funChance!;
    final problem = funLinesProblem(_funLines.text);
    final edited = _funLines.text.trim() != (_funLinesFrom ?? '').trim();
    return SettingsCard(
      key: const ValueKey('callout-fun-card'),
      title: 'Fun lines',
      info: kFunLinesInfo,
      subtitle: 'Now and then a fun line instead of "Order ready for ticket number …".',
      children: [
        _SliderRow(
          key: const ValueKey('callout-fun-chance'),
          label: 'Fun lines',
          value: chance.toDouble(),
          min: 0,
          max: 50,
          divisions: 10,
          text: _chanceText(chance),
          textWidth: 150,
          onChanged: busy ? null : (v) => setState(() => _draft = s.copyWith(funChance: v.round())),
          onChangeEnd: (v) => _save(
            s.copyWith(funChance: v.round()),
            v.round() == 0 ? 'Fun lines off' : 'Fun lines: ${v.round()}% of callouts',
          ),
        ),
        const Divider(),
        Text('Your lines', style: label),
        QuiccSpace.gapXs,
        TextField(
          key: const ValueKey('callout-fun-lines'),
          controller: _funLines,
          minLines: 3,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            hintText: 'Alright alright alright, order for {n} is ready at the counter.',
            helperText: 'One per line. {n} = the ticket number. Empty = the built-in lines.',
            helperMaxLines: 2,
            errorText: problem,
          ),
          onChanged: (_) => setState(() {}),
        ),
        QuiccSpace.gapSm,
        Wrap(
          spacing: QuiccSpace.md,
          runSpacing: QuiccSpace.sm,
          children: [
            SizedBox(
              height: 56,
              child: FilledButton(
                key: const ValueKey('callout-fun-save'),
                onPressed: busy || problem != null || !edited ? null : _saveFunLines,
                child: const Text('SAVE'),
              ),
            ),
            SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                key: const ValueKey('callout-fun-try'),
                onPressed: previewBusy ? null : () => _speak(kind: 'fun', number: kFunTryNumber),
                icon: const Icon(Icons.speaker_outlined),
                label: const Text('TRY A FUN LINE'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _guestCard(
    CalloutSettings s,
    List<CalloutVoice> voices, {
    required bool busy,
    required TextStyle label,
    required TextStyle hint,
  }) {
    final chance = s.guestChance!;
    final ids = s.guestVoiceIds;
    final full = ids.length >= CalloutSettings.maxGuestVoices;
    return SettingsCard(
      key: const ValueKey('callout-guest-card'),
      title: 'Guest voices',
      info: kGuestVoicesInfo,
      subtitle:
          "Now and then a guest voice calls the order instead. Online voices are made the first time they're used.",
      children: [
        _SliderRow(
          key: const ValueKey('callout-guest-chance'),
          label: 'Guest voices',
          value: chance.toDouble(),
          min: 0,
          max: CalloutSettings.maxGuestChance.toDouble(),
          divisions: CalloutSettings.maxGuestChance,
          text: _chanceText(chance),
          textWidth: 150,
          onChanged: busy ? null : (v) => setState(() => _draft = s.copyWith(guestChance: v.round())),
          onChangeEnd: (v) => _save(
            s.copyWith(guestChance: v.round()),
            v.round() == 0 ? 'Guest voices off' : 'Guest voices: ${v.round()}% of callouts',
          ),
        ),
        const Divider(),
        Row(
          children: [
            Expanded(child: Text('Which voices', style: label)),
            if (ids.isNotEmpty)
              TextButton(
                key: const ValueKey('callout-guest-all'),
                onPressed: busy ? null : () => _save(s.copyWith(guestVoices: ''), 'Guest voices: all online voices'),
                child: const Text('ALL ONLINE VOICES'),
              ),
          ],
        ),
        Text(
          ids.isEmpty
              ? 'All online voices'
              : '${ids.length} picked${full ? ' — at most ${CalloutSettings.maxGuestVoices}' : ''}',
          key: const ValueKey('callout-guest-summary'),
          style: hint,
        ),
        QuiccSpace.gapSm,
        Wrap(
          spacing: QuiccSpace.sm,
          runSpacing: QuiccSpace.sm,
          children: [
            for (final v in voices)
              FilterChip(
                key: ValueKey('callout-guest-${v.id}'),
                label: Text(v.online ? '${v.label} · online' : v.label),
                selected: ids.contains(v.id),
                onSelected: busy || (full && !ids.contains(v.id)) ? null : (on) => _toggleGuest(s, v, on),
              ),
          ],
        ),
      ],
    );
  }

  static String _chanceText(int v) => v == 0 ? 'Off' : '$v% of callouts';

  static String _secs(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  static String _lastLine(CalloutSpoken l) {
    final what = switch (l.kind) {
      'ready' => 'Last called',
      'preview' => 'Last preview',
      _ => 'Last test',
    };
    return l.ok ? '$what: #${l.number} at ${clock(l.at)}' : '$what #${l.number} did not play: ${l.error}';
  }
}

/// Whether the hub can speak right now, in a line.
class _HubLine extends StatelessWidget {
  final CalloutView? view;
  const _HubLine({this.view});

  @override
  Widget build(BuildContext context) {
    final v = view;
    final (text, color) = switch (v) {
      null => ('Asking the Pi…', context.palette.textMuted),
      _ when !v.hubConnected => (
        'The store hub is not connected — callouts wait until it is',
        QuiccColors.statusFiring,
      ),
      _ when v.hub == null => ('The store hub needs an update for callouts', QuiccColors.statusFiring),
      _ when !v.hub!.installed => ('The voice is not installed on the store computer yet', QuiccColors.statusFiring),
      _ when v.hub!.error.isNotEmpty => ('Voice problem: ${v.hub!.error}', QuiccColors.statusVoided),
      _ => ('Store speaker ready', QuiccColors.statusPaid),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: QuiccSpace.xs),
      child: Row(
        children: [
          Icon(Icons.speaker_outlined, color: color, size: 20),
          QuiccSpace.gapSm,
          Expanded(
            child: Text(
              text,
              key: const ValueKey('callout-hub-line'),
              style: QuiccType.text(QuiccType.label, weight: FontWeight.w600, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String text;
  final double textWidth;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double> onChangeEnd;
  const _SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.text,
    this.textWidth = 96,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 200,
          child: Text(label, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChanged == null ? null : onChangeEnd,
          ),
        ),
        SizedBox(
          width: textWidth,
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: QuiccType.number(QuiccType.body, weight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// Developer mode → POS hub → Finishing orders (1.8.0, Pi 2.3.0): online
/// pickups finish N min after ready; terminal orders when SoftTouch closes
/// them (shown, not editable).
class FinishingOrdersCard extends ConsumerStatefulWidget {
  const FinishingOrdersCard({super.key});

  @override
  ConsumerState<FinishingOrdersCard> createState() => _FinishingOrdersCardState();
}

class _FinishingOrdersCardState extends ConsumerState<FinishingOrdersCard> {
  int? _minutes;
  int? _saved;
  bool _unsupported = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    try {
      final f = await client.getFinishing();
      if (mounted) setState(() => _minutes = _saved = f.onlinePickupMinutes);
    } on AgentException catch (e) {
      if (e.code == kSettingsUnsupported && mounted) setState(() => _unsupported = true);
    } catch (_) {}
  }

  Future<void> _save() async {
    final m = _minutes;
    if (m == null) return;
    setState(() => _saving = true);
    try {
      final f = await ref.read(floorProvider.notifier).saveFinishing(FinishingSettings(onlinePickupMinutes: m));
      if (!mounted) return;
      setState(() => _minutes = _saved = f.onlinePickupMinutes);
      toast(context, m == 0 ? 'Online pickups wait for Close batch' : 'Online pickups finish $m min after ready');
    } catch (e) {
      if (mounted) toastError(context, e, lead: 'Not saved', area: 'settings');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = QuiccType.text(QuiccType.body, weight: FontWeight.w600);
    final m = _minutes;
    return SettingsCard(
      key: const ValueKey('finishing-card'),
      title: 'Finishing orders',
      info: kFinishingInfo,
      subtitle: 'When a ready pickup counts as picked up (no longer open).',
      children: [
        if (_unsupported)
          const ComingSoonRow(
            key: ValueKey('coming-finishing'),
            icon: Icons.task_alt,
            title: 'Finishing orders',
            explanation: 'Ready pickups finish so a Pi update can run mid-shift.',
          )
        else ...[
          Row(
            children: [
              Expanded(child: Text('Online pickups finish after', style: label)),
              IconButton(
                key: const ValueKey('finishing-minus'),
                onPressed: m == null || m <= 0 || _saving
                    ? null
                    : () => setState(() => _minutes = (m - 5).clamp(0, 240)),
                icon: const Icon(Icons.remove_circle_outline),
              ),
              SizedBox(
                width: 110,
                child: Text(
                  m == null ? '…' : (m == 0 ? 'never' : '$m min'),
                  key: const ValueKey('finishing-value'),
                  textAlign: TextAlign.center,
                  style: QuiccType.number(QuiccType.heading, weight: FontWeight.w700),
                ),
              ),
              IconButton(
                key: const ValueKey('finishing-plus'),
                onPressed: m == null || m >= 240 || _saving
                    ? null
                    : () => setState(() => _minutes = (m + 5).clamp(0, 240)),
                icon: const Icon(Icons.add_circle_outline),
              ),
              QuiccSpace.gapSm,
              FilledButton(
                key: const ValueKey('finishing-save'),
                onPressed: m == null || m == _saved || _saving ? null : _save,
                child: const Text('SAVE'),
              ),
            ],
          ),
          Text(
            '… of being marked ready (default 30; never = wait for Close batch).',
            style: TextStyle(color: palette.textSecondary),
          ),
          const Divider(),
          Row(
            children: [
              Expanded(child: Text('Terminal orders (counter, takeout)', style: label)),
              Text(
                'When SoftTouch closes the check',
                key: const ValueKey('finishing-terminal'),
                style: QuiccType.text(QuiccType.body, weight: FontWeight.w700, color: palette.textSecondary),
              ),
            ],
          ),
          Text('Fixed — not a setting.', style: TextStyle(color: palette.textMuted)),
        ],
      ],
    );
  }
}
