import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import '../dev/dev_widgets.dart';
import '../diagnose/report.dart';
import '../settings/settings_card.dart';
import 'update_prompt.dart' show kPlayProtectHint;
import 'updater.dart';

const kUpdatesInfo = InfoText(
  'Quibase updates',
  'The owner sends new versions of Quibase to the Pi, and the tablet downloads them by itself.\n\n'
      'It installs a new version right after Close batch, when nothing is ringing or cooking, and '
      'comes back by itself a minute later. Nothing ever locks the tablet, and an order can always '
      'be accepted.\n\n'
      'Android asks for one tap the first time Quibase installs itself; after that, Android needs no '
      'tap. Google Play Protect still asks about each new version: tap More details, then Install '
      'without scanning. If an update is waiting on a tap, Quibase asks "Install now?" when the '
      'store is quiet.\n\n'
      'INSTALL NOW installs a downloaded version straight away. CHECK NOW asks the Pi what it has.\n\n'
      'Reopen after an update: Android only lets Quibase bring its screen back by itself when it may '
      '"display over other apps". TURN ON opens that switch: turn it on for Quibase and come back.',
);

/// One line for where the update stands.
String updateStatusLine(UpdateState u) {
  final name = u.target?.versionName ?? '';
  return switch (u.phase) {
    UpdatePhase.none => u.lastCheck == null ? 'Up to date' : 'Up to date · checked ${clock(u.lastCheck)}',
    UpdatePhase.downloading =>
      'Downloading $name${u.progress == null ? '…' : ' · ${(u.progress! * 100).round()} %'}',
    UpdatePhase.ready => '$name downloaded — installs by itself after Close batch',
    UpdatePhase.installing => 'Installing $name…',
    UpdatePhase.needsTap => '$name is ready — tap INSTALL NOW',
    UpdatePhase.needPermission => '$name is ready — Android needs permission first',
    UpdatePhase.failed => '$name: ${u.error?.short ?? 'not installed'}',
  };
}

/// This tablet's Quibase: installed, what's waiting, INSTALL NOW / CHECK NOW.
/// On Store → Updates and developer mode → Config.
class UpdateStatusCard extends ConsumerStatefulWidget {
  const UpdateStatusCard({super.key});

  @override
  ConsumerState<UpdateStatusCard> createState() => _UpdateStatusCardState();
}

class _UpdateStatusCardState extends ConsumerState<UpdateStatusCard> {
  late final Future<String> _installed = installedVersionName();

  @override
  Widget build(BuildContext context) {
    final u = ref.watch(updaterProvider);
    final ctl = ref.read(updaterProvider.notifier);
    final canInstall = u.available && u.phase != UpdatePhase.downloading && u.phase != UpdatePhase.installing;
    return SettingsCard(
      title: 'This tablet',
      info: kUpdatesInfo,
      subtitle: 'New versions download by themselves and install after Close batch.',
      children: [
        FutureBuilder<String>(
          future: _installed,
          builder: (_, snap) => KeyValueRow('Installed', snap.data ?? '…', mono: true),
        ),
        KeyValueRow(
          'Status',
          updateStatusLine(u),
          key: const ValueKey('update-status'),
          warn: u.wantsTap,
          bad: u.phase == UpdatePhase.failed,
        ),
        KeyValueRow(
          'Install',
          u.silent ? 'No Android tap needed (Play Protect may still ask)' : 'The next update asks for one tap (Android)',
        ),
        Row(
          children: [
            Expanded(
              child: KeyValueRow(
                'Reopen after an update',
                u.reopen ? 'On' : 'Off — the tablet shows its home screen after an update',
                warn: !u.reopen,
              ),
            ),
            if (!u.reopen)
              TextButton(
                key: const ValueKey('update-reopen'),
                onPressed: ctl.turnOnReopen,
                child: const Text('TURN ON'),
              ),
          ],
        ),
        if (u.wantsTap || u.phase == UpdatePhase.installing)
          Padding(
            padding: const EdgeInsets.only(top: QuiccSpace.sm),
            child: Text(kPlayProtectHint, style: QuiccType.text(QuiccType.caption, color: context.palette.textMuted)),
          ),
        if (u.phase == UpdatePhase.downloading && u.progress != null) ...[
          QuiccSpace.gapSm,
          LinearProgressIndicator(value: u.progress, minHeight: 6),
        ],
        QuiccSpace.gapMd,
        Wrap(
          spacing: QuiccSpace.md,
          runSpacing: QuiccSpace.sm,
          children: [
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                key: const ValueKey('update-install-now'),
                onPressed: canInstall ? ctl.tapInstall : null,
                icon: const Icon(Icons.download_done),
                label: Text(u.phase == UpdatePhase.needPermission ? 'ALLOW INSTALLS' : 'INSTALL NOW'),
              ),
            ),
            SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                key: const ValueKey('update-check'),
                onPressed: ctl.check,
                icon: const Icon(Icons.refresh),
                label: const Text('CHECK NOW'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// What the Pi holds for the tablets (its cached Quibase).
class PiReleaseCard extends ConsumerStatefulWidget {
  const PiReleaseCard({super.key});

  @override
  ConsumerState<PiReleaseCard> createState() => _PiReleaseCardState();
}

class _PiReleaseCardState extends ConsumerState<PiReleaseCard> {
  Future<AppRelease?>? _onPi;

  @override
  void initState() {
    super.initState();
    _onPi = ref.read(agentClientProvider)?.appLatest();
  }

  @override
  Widget build(BuildContext context) {
    // Ask the Pi again whenever the tablet checked (CHECK NOW, every 10 min).
    ref.listen(updaterProvider.select((u) => u.lastCheck), (_, _) {
      setState(() => _onPi = ref.read(agentClientProvider)?.appLatest());
    });
    return _card();
  }

  Widget _card() => SettingsCard(
    title: 'The Pi',
    info: kUpdatesInfo,
    subtitle: 'The newest Quibase the Pi has for this store\'s tablets.',
    children: [
      FutureBuilder<AppRelease?>(
        future: _onPi,
        builder: (_, snap) {
          if (_onPi == null) return const KeyValueRow('On the Pi', 'Not paired');
          if (snap.connectionState != ConnectionState.done) return const KeyValueRow('On the Pi', 'asking…');
          if (snap.hasError) return const KeyValueRow('On the Pi', "Can't reach the Pi", bad: true);
          final r = snap.data;
          return KeyValueRow(
            'On the Pi',
            r == null ? 'No release waiting' : '${r.versionName.isEmpty ? '?' : r.versionName} (build ${r.versionCode})',
            mono: r != null,
          );
        },
      ),
    ],
  );
}

/// Store mode → Updates (1.6.1).
class UpdatesScreen extends StatelessWidget {
  const UpdatesScreen({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    padding: QuiccSpace.paneInsets,
    children: [
      const PaneHeader(title: 'Updates', subtitle: 'Quibase on this tablet'),
      Padding(
        padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
        child: Text(
          'New versions install by themselves right after Close batch. Nothing locks the tablet, '
          'and orders keep ringing.',
          style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
        ),
      ),
      const UpdateStatusCard(),
      const PiReleaseCard(),
    ],
  );
}
