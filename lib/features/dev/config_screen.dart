import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../diagnose/diagnose_entry.dart';
import '../diagnose/report.dart' show installedVersionName;
import '../settings/pos_settings_cards.dart';
import '../settings/settings_card.dart';
import 'dev_texts.dart';
import 'dev_widgets.dart';
import 'pi_cards.dart';

/// Developer mode → Config: the feature switches, this tablet's pairing,
/// Quibase updates and About & diagnostics.
class DevConfigScreen extends StatelessWidget {
  const DevConfigScreen({super.key});

  @override
  Widget build(BuildContext context) => DevPane(
    title: DevText.configTitle,
    subtitle: DevText.configSubtitle,
    children: [
      const FeaturesSettingsCard(),
      const TabletCard(),
      const _UpdateCard(),
      Padding(
        padding: const EdgeInsets.only(bottom: QuiccSpace.sm),
        child: Text(
          'Versions, the Pi\'s address and health in one place — COPY for a message, SEND for the owner.',
          style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
        ),
      ),
      const AboutDiagnosticsCard(),
    ],
  );
}

class _UpdateCard extends ConsumerStatefulWidget {
  const _UpdateCard();

  @override
  ConsumerState<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends ConsumerState<_UpdateCard> {
  late final Future<String> _installed = installedVersionName();
  Future<AppRelease?>? _onPi;

  void _check() {
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    setState(() => _onPi = client.appLatest());
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SettingsCard(
      title: DevText.update,
      info: kUpdateInfo,
      subtitle: DevText.updateLine,
      children: [
        FutureBuilder<String>(
          future: _installed,
          builder: (_, snap) => KeyValueRow('Installed', snap.data ?? '…', mono: true),
        ),
        if (_onPi != null)
          FutureBuilder<AppRelease?>(
            future: _onPi,
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) return const KeyValueRow('On the Pi', 'asking…');
              if (snap.hasError) return const KeyValueRow('On the Pi', "Can't reach the Pi", bad: true);
              final r = snap.data;
              return KeyValueRow(
                'On the Pi',
                r == null
                    ? 'No release waiting'
                    : '${r.versionName.isEmpty ? '?' : r.versionName} (build ${r.versionCode})',
                mono: r != null,
              );
            },
          ),
        QuiccSpace.gapSm,
        Row(
          children: [
            SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                key: const ValueKey('update-check'),
                onPressed: _check,
                icon: const Icon(Icons.system_update_alt),
                label: const Text('CHECK NOW'),
              ),
            ),
            QuiccSpace.gapMd,
            Expanded(
              child: Text(
                'A newer one locks the tablet until it is installed.',
                style: QuiccType.text(QuiccType.caption, color: palette.textMuted),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
