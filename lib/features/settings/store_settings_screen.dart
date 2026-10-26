import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import '../setup/setup_entry.dart';
import 'auto_accept_card.dart';
import 'chime_picker.dart';
import 'delivery_area_card.dart';
import 'deliveries_settings_card.dart';
import 'pos_settings_cards.dart';
import 'receipt_settings_card.dart';
import 'settings_card.dart';
import 'settings_texts.dart';

/// Store mode → Settings (1.6.0): what the store decides, in groups.
/// The Pi, pairing, feature switches and diagnostics live in developer mode.
class StoreSettingsScreen extends StatelessWidget {
  const StoreSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: QuiccSpace.paneInsets,
      children: const [
        PaneHeader(
          title: 'Settings',
          subtitle: 'How this store works. Most of it is saved on the Pi for every tablet.',
        ),
        ContinueSetupCard(),
        SettingsGroup(
          key: ValueKey('group-deliveries'),
          title: 'Deliveries',
          caption: 'How AUTO plans runs, and which deliveries count as close to a run.',
          children: [DeliveryAreaCard(), DeliveriesSettingsCard()],
        ),
        SettingsGroup(
          key: ValueKey('group-times'),
          title: 'New orders',
          caption: 'Auto-accept, and where the time picker starts when you accept an order.',
          children: [AutoAcceptCard(), DefaultTimesSettingsCard()],
        ),
        SettingsGroup(
          key: ValueKey('group-tickets'),
          title: 'Kitchen tickets',
          caption: 'Which orders print station tickets by themselves.',
          children: [KitchenTicketsSettingsCard()],
        ),
        SettingsGroup(
          key: ValueKey('group-receipts'),
          title: 'Receipts',
          caption: 'How the kitchen tickets and the customer receipt look on paper.',
          children: [ReceiptSettingsCard()],
        ),
        SettingsGroup(
          key: ValueKey('group-look'),
          title: 'Sound & look',
          caption: 'Only this tablet.',
          children: [
            SettingsCard(
              title: 'Order chime',
              info: kChimeInfo,
              subtitle: 'Rings until every new order is accepted.',
              children: [ChimePicker()],
            ),
            ThemeSettingsCard(),
            MotionSettingsCard(),
          ],
        ),
      ],
    );
  }
}

class ThemeSettingsCard extends ConsumerWidget {
  const ThemeSettingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return SettingsCard(
      title: 'Light or dark',
      info: kThemeInfo,
      subtitle: 'Dark is easier on the eyes in a dim kitchen.',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<ThemeMode>(
            style: SegmentedButton.styleFrom(
              minimumSize: const Size(0, 56),
              textStyle: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
            ),
            segments: const [
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('System')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
          ),
        ),
      ],
    );
  }
}

/// Motion on / off and the animation speed (0.5× – 2×). The slider shows
/// speed (right = faster); [MotionSettings.speed] stores the duration factor,
/// its inverse.
class MotionSettingsCard extends ConsumerWidget {
  const MotionSettingsCard({super.key});

  static String speedLabel(double v) =>
      '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}×';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(motionProvider);
    final notifier = ref.read(motionProvider.notifier);
    final androidOff = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final speed = (1 / s.speed).clamp(MotionSettings.minSpeed, MotionSettings.maxSpeed);
    final palette = context.palette;
    return SettingsCard(
      title: 'Motion',
      info: kMotionInfo,
      subtitle: 'Moving menus and highlights. Off = quick fades.',
      children: [
        SwitchListTile(
          key: const ValueKey('motion-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text('Motion', style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
          subtitle: Text(
            androidOff
                ? 'Android\'s "Remove animations" is on, so Quibase keeps to quick fades.'
                : s.enabled
                ? 'On — things move to show what changed.'
                : 'Off — quick fades instead.',
            style: QuiccType.text(QuiccType.caption, color: palette.textMuted),
          ),
          value: s.enabled,
          onChanged: notifier.setEnabled,
        ),
        QuiccSpace.gapSm,
        Row(
          children: [
            Text('Animation speed', style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
            const Spacer(),
            Text(
              speedLabel(speed),
              style: QuiccType.number(QuiccType.body, color: s.enabled ? QuiccColors.brand400 : palette.textMuted),
            ),
          ],
        ),
        Row(
          children: [
            Text('Slower', style: QuiccType.text(QuiccType.caption, color: palette.textMuted)),
            Expanded(
              child: Slider(
                key: const ValueKey('motion-speed'),
                min: MotionSettings.minSpeed,
                max: MotionSettings.maxSpeed,
                divisions: 6,
                value: speed,
                label: speedLabel(speed),
                onChanged: s.enabled ? (v) => notifier.setSpeed(1 / v) : null,
              ),
            ),
            Text('Faster', style: QuiccType.text(QuiccType.caption, color: palette.textMuted)),
          ],
        ),
        Text(
          '1× is how it was designed. 2× is twice as fast.',
          style: QuiccType.text(QuiccType.caption, color: palette.textMuted),
        ),
      ],
    );
  }
}
