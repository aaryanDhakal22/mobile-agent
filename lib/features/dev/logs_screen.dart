import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_log.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../settings/settings_card.dart';
import 'dev_log.dart';
import 'dev_texts.dart';
import 'dev_widgets.dart';

enum _Filter { all, connection, floor, errors }

/// Developer mode → Logs: this tablet's recent events (in memory) and the
/// errors staff saw (kept on the tablet). The Pi's own log is 1.7.0.
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
            QuiccSpace.gapSm,
            Text(DevText.piLogsSoon, style: QuiccType.text(QuiccType.caption, color: palette.textMuted)),
          ],
        ),
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
