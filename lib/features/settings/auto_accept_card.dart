import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'settings_card.dart';

const kAutoAcceptInfo = InfoText(
  'Auto-accept',
  'On: every new online order is accepted by the Pi the moment it arrives — the kitchen tickets '
      'print and the timer starts at the store\'s default time (Default times below). The tablet '
      'does not ring; it plays a short chime and shows "#1104 auto-accepted" for 3 seconds.\n\n'
      'Off: a new order rings until someone taps ACCEPT and picks the time.\n\n'
      'Saved on the Pi, so every tablet and the Pi\'s web page agree.',
);

/// Store settings → New orders (2.2.0): the Pi's auto-accept switch. An older
/// Pi keeps it on its web page only — then this says so.
class AutoAcceptCard extends ConsumerStatefulWidget {
  const AutoAcceptCard({super.key});

  @override
  ConsumerState<AutoAcceptCard> createState() => _AutoAcceptCardState();
}

class _AutoAcceptCardState extends ConsumerState<AutoAcceptCard> {
  bool? _on;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(agentClientProvider);
    bool? v;
    try {
      v = await client?.autoAccept();
    } catch (_) {
      v = null;
    }
    if (mounted) {
      setState(() {
        _on = v;
        _loaded = true;
      });
    }
  }

  Future<void> _set(bool on) async {
    if (on &&
        !await confirmDialog(
          context,
          title: 'Turn on auto-accept?',
          message:
              'New online orders will print and start cooking without anyone tapping ACCEPT, at the store\'s '
              'default time. The tablet chimes instead of ringing.',
          confirm: 'TURN ON',
        )) {
      return;
    }
    final client = ref.read(agentClientProvider);
    if (client == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final saved = await client.setAutoAccept(on);
      if (!mounted) return;
      setState(() => _on = saved);
      toast(context, saved ? 'Auto-accept is on' : 'Auto-accept is off — new orders ring');
    } catch (e) {
      if (mounted) toastError(context, e, lead: 'Auto-accept not changed', area: 'settings');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SettingsCard(
      title: 'Auto-accept',
      info: kAutoAcceptInfo,
      subtitle: 'Accept new online orders without a tap.',
      children: [
        if (!_loaded)
          const Align(alignment: Alignment.centerLeft, child: CircularProgressIndicator())
        else if (_on == null)
          Text(
            "This Pi doesn't let tablets change auto-accept yet — use the Pi's web page.",
            style: QuiccType.text(QuiccType.body, color: palette.textSecondary),
          )
        else
          SwitchListTile(
            key: const ValueKey('auto-accept-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text('Auto-accept', style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
            subtitle: Text(
              _on! ? 'On — orders print as they arrive; the tablet chimes.' : 'Off — new orders ring until accepted.',
              style: TextStyle(color: palette.textSecondary),
            ),
            value: _on!,
            onChanged: _saving ? null : _set,
          ),
      ],
    );
  }
}
