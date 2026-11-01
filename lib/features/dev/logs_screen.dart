import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/delivery_models.dart';
import '../../core/local_log.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../settings/settings_card.dart';
import 'dev_log.dart';
import 'dev_texts.dart';
import 'dev_widgets.dart';
import 'settings_history.dart';

enum _Filter { all, connection, floor, errors }

/// Developer mode → Logs: this tablet's recent events (in memory), the Pi's
/// own recent events (2.2.0, `GET /api/dev/events`, polled while shown) and
/// the errors staff saw (kept on the tablet).
class DevLogsScreen extends ConsumerStatefulWidget {
  const DevLogsScreen({super.key});

  @override
  ConsumerState<DevLogsScreen> createState() => _DevLogsScreenState();
}

class _DevLogsScreenState extends ConsumerState<DevLogsScreen> {
  _Filter _filter = _Filter.all;

  bool _keep(DevLogEntry e) => switch (_filter) {
    _Filter.all => true,
    _Filter.connection => e.kind == DevLogKind.connection,
    _Filter.floor => e.kind == DevLogKind.floor,
    _Filter.errors => e.kind == DevLogKind.error,
  };

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(devLogProvider).where(_keep).toList().reversed.toList();
    final saved = ref.watch(localLogProvider).lines.reversed.take(60).toList();
    final palette = context.palette;
    return DevPane(
      title: DevText.logsTitle,
      subtitle: DevText.logsSubtitle,
      children: [
        SettingsCard(
          title: 'This tablet',
          info: kLogsInfo,
          subtitle: DevText.logsLine,
          children: [
            Row(
              children: [
                SegmentedButton<_Filter>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _Filter.all, label: Text('All')),
                    ButtonSegment(value: _Filter.connection, label: Text('Live link')),
                    ButtonSegment(value: _Filter.floor, label: Text('Orders')),
                    ButtonSegment(value: _Filter.errors, label: Text('Errors')),
                  ],
                  selected: {_filter},
                  onSelectionChanged: (s) => setState(() => _filter = s.first),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => ref.read(devLogProvider.notifier).clear(),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Clear'),
                ),
              ],
            ),
            QuiccSpace.gapMd,
            Container(
              constraints: const BoxConstraints(minHeight: 120, maxHeight: 420),
              decoration: BoxDecoration(
                color: palette.bgCanvas,
                borderRadius: BorderRadius.circular(QuiccRadius.sm),
                border: Border.all(color: palette.borderSoft),
              ),
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        'Nothing yet — events show up here as they happen.',
                        style: QuiccType.text(QuiccType.body, color: palette.textMuted),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('dev-log-list'),
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(QuiccSpace.sm),
                      itemCount: entries.length,
                      itemBuilder: (_, i) => _LogLine(entries[i]),
                    ),
            ),
          ],
        ),
        const _PiLogCard(),
        const SettingsHistoryCard(),
        SettingsCard(
          title: DevText.errorsTitle,
          info: kLogsInfo,
          subtitle: DevText.errorsLine,
          children: [
            if (saved.isEmpty)
              Text('No errors saved.', style: QuiccType.text(QuiccType.body, color: palette.textMuted))
            else
              for (final l in saved)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: SelectableText(l, style: QuiccType.number(QuiccType.caption, weight: FontWeight.w400)),
                ),
          ],
        ),
      ],
    );
  }
}

/// The Pi's recent events, newest first, polled every [_piPoll] while shown.
class _PiLogCard extends ConsumerStatefulWidget {
  const _PiLogCard();

  @override
  ConsumerState<_PiLogCard> createState() => _PiLogCardState();
}

const Duration _piPoll = Duration(seconds: 5);
const int _piKeep = 300;

class _PiLogCardState extends ConsumerState<_PiLogCard> {
  final List<PiEvent> _events = [];
  int _since = 0;
  bool _unsupported = false;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(_piPoll, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final client = ref.read(agentClientProvider);
    if (client == null || _unsupported) return;
    try {
      final r = await client.piEvents(since: _since);
      if (!mounted) return;
      setState(() {
        _error = null;
        if (r == null) {
          _unsupported = true;
          return;
        }
        final (events, last) = r;
        _events.addAll(events);
        if (_events.length > _piKeep) _events.removeRange(0, _events.length - _piKeep);
        if (last > _since) _since = last;
      });
    } catch (e) {
      if (mounted) setState(() => _error = "Can't reach the Pi");
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shown = _events.reversed.toList(growable: false);
    return SettingsCard(
      title: 'The Pi',
      info: kLogsInfo,
      subtitle: "The Pi's own recent events: orders, printing, the live link, the POS hub, updates. No names.",
      children: [
        if (_unsupported)
          Text(
            "This Pi doesn't share its log yet — it needs the 2.2 update.",
            style: QuiccType.text(QuiccType.body, color: palette.textMuted),
          )
        else ...[
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: QuiccSpace.sm),
              child: Text(_error!, style: QuiccType.text(QuiccType.label, color: QuiccColors.statusVoided)),
            ),
          Container(
            constraints: const BoxConstraints(minHeight: 120, maxHeight: 420),
            decoration: BoxDecoration(
              color: palette.bgCanvas,
              borderRadius: BorderRadius.circular(QuiccRadius.sm),
              border: Border.all(color: palette.borderSoft),
            ),
            child: shown.isEmpty
                ? Center(
                    child: Text('Nothing yet.', style: QuiccType.text(QuiccType.body, color: palette.textMuted)),
                  )
                : ListView.builder(
                    key: const ValueKey('pi-log-list'),
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(QuiccSpace.sm),
                    itemCount: shown.length,
                    itemBuilder: (_, i) => _PiLine(shown[i]),
                  ),
          ),
        ],
      ],
    );
  }
}

class _PiLine extends StatelessWidget {
  final PiEvent e;
  const _PiLine(this.e);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = switch (e.level) {
      'error' => QuiccColors.statusVoided,
      'warn' => QuiccColors.statusFiring,
      _ => palette.textSecondary,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              e.at == null ? '' : clockSeconds(e.at!),
              style: QuiccType.number(QuiccType.label, color: palette.textMuted),
            ),
          ),
          SizedBox(
            width: 72,
            child: Text(e.kind, style: QuiccType.text(QuiccType.caption, weight: FontWeight.w600, color: color)),
          ),
          Expanded(
            child: Text(e.text, style: QuiccType.text(QuiccType.label, color: e.level == 'info' ? null : color)),
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  final DevLogEntry e;
  const _LogLine(this.e);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (icon, color) = switch (e.kind) {
      DevLogKind.connection => (Icons.wifi_tethering, QuiccColors.statusOpen),
      DevLogKind.floor => (Icons.receipt_long_outlined, palette.textSecondary),
      DevLogKind.error => (Icons.error_outline, QuiccColors.statusVoided),
      DevLogKind.app => (Icons.tablet_android, QuiccColors.brand400),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(clockSeconds(e.at), style: QuiccType.number(QuiccType.label, color: palette.textMuted)),
          ),
          Icon(icon, size: 18, color: color),
          QuiccSpace.gapSm,
          Expanded(
            child: Text(
              e.text,
              style: QuiccType.text(QuiccType.label, color: e.kind == DevLogKind.error ? color : null),
            ),
          ),
        ],
      ),
    );
  }
}

/// 14:03:27 in local time.
String clockSeconds(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}
