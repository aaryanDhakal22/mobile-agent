import 'package:flutter/material.dart';

import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../diagnose/diagnose_entry.dart';
import '../settings/pos_settings_cards.dart';
import '../update/updates_screen.dart';
import 'dev_texts.dart';
import 'dev_widgets.dart';
import 'pi_cards.dart';

/// Developer mode → Config: the feature switches (the POS ones live on POS
/// hub), this tablet's pairing, Quibase updates and About & diagnostics.
class DevConfigScreen extends StatelessWidget {
  const DevConfigScreen({super.key});

  @override
  Widget build(BuildContext context) => DevPane(
    title: DevText.configTitle,
    subtitle: DevText.configSubtitle,
    children: [
      const FeaturesSettingsCard(keys: kPosFeatureKeys, exclude: true),
      const TabletCard(),
      const UpdateStatusCard(),
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
