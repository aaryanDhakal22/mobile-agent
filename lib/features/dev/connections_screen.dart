import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/sse.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../diagnose/diagnose_entry.dart';
import '../diagnose/report.dart' show installedVersionName;
import '../settings/settings_card.dart';
import 'dev_log.dart';
import 'dev_texts.dart';
import 'dev_widgets.dart';
import 'pi_cards.dart';

/// Developer mode → Connections: the Pi's address (checked live), the live
/// link, the printers, the POS link and the versions.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) => const DevPane(
    title: DevText.connectionsTitle,
    subtitle: DevText.connectionsSubtitle,
    children: [PiAddressCard(), _LiveLinkCard(), _PrintersCard(), _PosLinkCard(), _VersionsCard()],
  );
}

class _LiveLinkCard extends ConsumerWidget {
  const _LiveLinkCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fs = ref.watch(floorProvider);
    final log = ref.watch(devLogProvider);
    final last = log.lastOrNull;
    final drops = log.where((e) => e.kind == DevLogKind.connection && e.text.startsWith('Live link dropped')).length;
    final (color, state) = switch (fs.connection) {
      SseStatus.connected => (QuiccColors.statusPaid, 'Live'),
      SseStatus.connecting => (QuiccColors.statusFiring, 'Syncing — connecting again'),
      SseStatus.disconnected => (QuiccColors.statusVoided, 'Offline — retrying'),
    };
    return SettingsCard(
      title: DevText.liveLink,
      info: kLiveLinkInfo,
      subtitle: DevText.liveLinkLine,
      children: [
        Row(
          children: [
            StatusDot(color),
            QuiccSpace.gapSm,
            Text(
              state,
              style: QuiccType.text(QuiccType.heading, weight: FontWeight.w600, color: color),
            ),
          ],
        ),
        QuiccSpace.gapSm,
        KeyValueRow('Last event', last == null ? 'none yet' : '${clock(last.at)} · ${last.text}'),
        KeyValueRow('Last full refresh', fs.lastSyncAt == null ? 'not yet' : clock(fs.lastSyncAt), mono: true),
        KeyValueRow('Drops since start', '$drops', warn: drops > 0, mono: true),
        if (fs.error != null) KeyValueRow('Last refresh error', fs.error!, bad: true),
      ],
    );
  }
}

class _PrintersCard extends ConsumerWidget {
  const _PrintersCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printers = ref.watch(printerStatusProvider);
    final palette = context.palette;
    return SettingsCard(
      title: DevText.printers,
      info: kPrintersLiveInfo,
      subtitle: DevText.printersLine,
      children: [
        printers.when(
          loading: () => const Padding(padding: EdgeInsets.all(QuiccSpace.sm), child: LinearProgressIndicator()),
          error: (e, _) => Text(
            "Can't ask the Pi about its printers right now.",
            style: QuiccType.text(QuiccType.body, color: QuiccColors.statusVoided),
          ),
          data: (list) => list.isEmpty
              ? Text('The store has no printers yet.', style: QuiccType.text(QuiccType.body, color: palette.textMuted))
              : Column(
                  children: [
                    for (final p in list)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: QuiccSpace.xs),
                        child: Row(
                          children: [
                            StatusDot(p.up ? QuiccColors.statusPaid : QuiccColors.statusVoided),
                            QuiccSpace.gapSm,
                            SizedBox(
                              width: 180,
                              child: Text(p.name, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
                            ),
                            SizedBox(
                              width: 170,
                              child: Text(
                                p.hasIP ? p.ip : 'no address',
                                style: QuiccType.number(QuiccType.label, color: palette.textSecondary),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                p.up
                                    ? 'Up${p.upSince == null ? '' : ' since ${clock(p.upSince)}'}'
                                    : 'Down${p.lastError.isEmpty ? '' : ' — ${p.lastError}'}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: QuiccType.text(
                                  QuiccType.label,
                                  color: p.up ? palette.textSecondary : QuiccColors.statusVoided,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _PosLinkCard extends ConsumerWidget {
  const _PosLinkCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hub = ref.watch(floorProvider.select((s) => s.floor?.integration));
    return SettingsCard(
      title: DevText.pos,
      info: kPosLinkInfo,
      subtitle: DevText.posLine,
      children: [
        if (hub == null)
          Text('This Pi has no POS link.', style: QuiccType.text(QuiccType.body, color: context.palette.textMuted))
        else ...[
          KeyValueRow(
            'Hub',
            !hub.connected
                ? 'Not connected'
                : hub.ok
                ? 'Connected'
                : 'Connected, with problems',
            bad: !hub.connected,
            warn: hub.connected && !hub.ok,
          ),
          KeyValueRow('Order insert', '${hub.insertMode}${hub.insertLive ? ' (inserting now)' : ''}'),
          KeyValueRow('Last heard from', hub.lastSeenAt == null ? 'never' : dateClock(hub.lastSeenAt), mono: true),
          for (final p in hub.problems) KeyValueRow('Problem', p.text, bad: p.isSerious, warn: !p.isSerious),
        ],
      ],
    );
  }
}

class _VersionsCard extends ConsumerStatefulWidget {
  const _VersionsCard();

  @override
  ConsumerState<_VersionsCard> createState() => _VersionsCardState();
}

class _VersionsCardState extends ConsumerState<_VersionsCard> {
  late final Future<String> _version = installedVersionName();

  @override
  Widget build(BuildContext context) {
    final diag = ref.watch(piDiagProvider);
    final d = diag.diag;
    return SettingsCard(
      title: DevText.versions,
      info: kVersionsInfo,
      subtitle: DevText.versionsLine,
      children: [
        FutureBuilder<String>(
          future: _version,
          builder: (_, snap) => KeyValueRow('Quibase (this tablet)', snap.data ?? '…', mono: true),
        ),
        KeyValueRow(
          'Pi (agent)',
          d?.version.isNotEmpty == true ? d!.version : (diag.unsupported ? '2.0.0 or older' : 'unknown'),
          mono: true,
        ),
        KeyValueRow(
          'Pi link to Quicc website',
          d == null
              ? 'unknown'
              : d.connectedToMain
              ? 'Connected'
              : d.mainState.isEmpty
              ? 'unknown'
              : d.mainState,
          warn: d != null && !d.connectedToMain,
        ),
        KeyValueRow('Pi health', piHealthSummary(d)),
      ],
    );
  }
}
