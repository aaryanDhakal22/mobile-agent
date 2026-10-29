import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/delivery_models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../settings/pos_settings_cards.dart';
import '../settings/settings_card.dart';

const kSettingsHistoryInfo = InfoText(
  'Settings changes',
  'Every setting changed on the Pi, newest first: when, which tablet (by its name) or the Pi web '
      'page did it, and each switch or value from → to.\n\n'
      'Kept on the Pi for 90 days, so it survives restarts and shows changes made from any tablet.',
);

/// Developer mode → Logs → Settings changes (agent 2.3.11): the Pi's settings
/// history, refreshed every [_poll] while shown.
class SettingsHistoryCard extends ConsumerStatefulWidget {
  const SettingsHistoryCard({super.key});

  @override
  ConsumerState<SettingsHistoryCard> createState() => _SettingsHistoryCardState();
}

const Duration _poll = Duration(seconds: 30);

class _SettingsHistoryCardState extends ConsumerState<SettingsHistoryCard> {
  List<SettingsChange> _changes = const [];
  bool _loaded = false;
  bool _unsupported = false;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(_poll, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final client = ref.read(agentClientProvider);
    if (client == null || _unsupported) return;
    try {
      final r = await client.settingsChanges();
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = null;
        if (r == null) {
          _unsupported = true;
        } else {
          _changes = r;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = "Can't reach the Pi");
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SettingsCard(
      title: 'Settings changes',
      info: kSettingsHistoryInfo,
      subtitle: 'Who changed what on the Pi, newest first. Kept 90 days.',
      children: [
        Row(
          children: [
            if (_error != null)
              Text(_error!, style: QuiccType.text(QuiccType.label, color: QuiccColors.statusVoided)),
            const Spacer(),
            TextButton.icon(
              key: const ValueKey('settings-history-refresh'),
              onPressed: _unsupported ? null : _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
        QuiccSpace.gapSm,
        if (_unsupported)
          Text(
            "This Pi doesn't keep a settings history yet — it needs the 2.3.11 update.",
            style: QuiccType.text(QuiccType.body, color: palette.textMuted),
          )
        else
          Container(
            constraints: const BoxConstraints(minHeight: 120, maxHeight: 420),
            decoration: BoxDecoration(
              color: palette.bgCanvas,
              borderRadius: BorderRadius.circular(QuiccRadius.sm),
              border: Border.all(color: palette.borderSoft),
            ),
            child: _changes.isEmpty
                ? Center(
                    child: Text(
                      _loaded ? 'No settings changed in the last 90 days.' : 'Loading…',
                      style: QuiccType.text(QuiccType.body, color: palette.textMuted),
                    ),
                  )
                : ListView.separated(
                    key: const ValueKey('settings-history-list'),
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(QuiccSpace.sm),
                    itemCount: _changes.length,
                    separatorBuilder: (_, _) => Divider(height: QuiccSpace.md, color: palette.borderSoft),
                    itemBuilder: (_, i) => SettingsChangeTile(_changes[i]),
                  ),
          ),
      ],
    );
  }
}

/// One change: when · who · section, then each key from → to.
class SettingsChangeTile extends StatelessWidget {
  final SettingsChange c;
  const SettingsChangeTile(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 132,
                child: Text(
                  c.at == null ? '' : settingsWhen(c.at!),
                  style: QuiccType.number(QuiccType.label, color: palette.textMuted),
                ),
              ),
              Icon(c.byTablet ? Icons.tablet_android : Icons.language, size: 18, color: QuiccColors.brand400),
              QuiccSpace.gapXs,
              Flexible(
                child: Text(
                  settingsWho(c),
                  overflow: TextOverflow.ellipsis,
                  style: QuiccType.text(QuiccType.label, weight: FontWeight.w600),
                ),
              ),
              QuiccSpace.gapSm,
              Text('· ${settingsSectionLabel(c.section)}', style: QuiccType.text(QuiccType.label, color: palette.textSecondary)),
            ],
          ),
          for (final d in c.changes)
            Padding(
              padding: const EdgeInsets.only(left: 132, top: 2),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${settingKeyLabel(c.section, d.key)}  '),
                    TextSpan(
                      text: settingValue(d.from),
                      style: TextStyle(color: palette.textMuted),
                    ),
                    const TextSpan(text: '  →  '),
                    TextSpan(
                      text: settingValue(d.to),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                style: QuiccType.text(QuiccType.label),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Oct 29 16:31:37" in local time.
String settingsWhen(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${months[l.month - 1]} ${l.day} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

/// "Counter" (a tablet) or "Pi web page".
String settingsWho(SettingsChange c) => c.byName.isNotEmpty ? c.byName : (c.byTablet ? 'A tablet' : 'Pi web page');

const _sectionLabels = {
  'tickets': 'Kitchen tickets',
  'features': 'POS features',
  'times': 'Default times',
  'finishing': 'Finishing',
  'callout': 'Callout',
  'deliveries': 'Deliveries',
  'auto-accept': 'Auto-accept',
  'auto-update': 'Pi auto-update',
  'receipt': 'Receipt',
  'floor': 'Floor',
  'driver-reset': 'Driver clock-out',
};

String settingsSectionLabel(String section) => _sectionLabels[section] ?? section;

/// The label Settings uses for a switch, else the key in plain words
/// (`default_pickup_minutes` → "Default pickup minutes").
String settingKeyLabel(String section, String key) {
  final specs = switch (section) {
    'tickets' => kTicketSwitches,
    'features' => kFeatureSwitches,
    _ => const <SwitchSpec>[],
  };
  for (final s in specs) {
    if (s.key == key) return s.label;
  }
  // A nested key (callout voice_lines.<voice id>): only the field is words.
  final dot = key.indexOf('.');
  final field = dot < 0 ? key : key.substring(0, dot);
  final words = field.replaceAll('_', ' ').trim();
  if (words.isEmpty) return key;
  final label = words[0].toUpperCase() + words.substring(1);
  return dot < 0 ? label : '$label › ${key.substring(dot + 1)}';
}

/// ON / OFF, — for not set, the value otherwise.
String settingValue(Object? v) => switch (v) {
  null => '—',
  true => 'ON',
  false => 'OFF',
  '' => '""',
  String s => s,
  num n => n.toString(),
  _ => jsonEncode(v),
};
