import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import '../home/idle_kitchen.dart';
import '../setup/setup_entry.dart';
import 'auto_accept_card.dart';
import 'auto_assign_card.dart';
import 'callout_cards.dart';
import 'chime_picker.dart';
import 'colors_card.dart';
import 'delivery_area_card.dart';
import 'deliveries_settings_card.dart';
import 'drivers_settings_card.dart';
import 'pos_settings_cards.dart';
import 'receipt_settings_card.dart';
import 'settings_card.dart';
import 'settings_texts.dart';

/// One group of store settings: a row on the Settings list, and its page.
class StoreSettingsGroup {
  final String id;
  final String title;
  final IconData icon;

  /// The row's line under the name.
  final String summary;

  /// The page's line under the title.
  final String caption;
  final List<Widget> children;
  const StoreSettingsGroup({
    required this.id,
    required this.title,
    required this.icon,
    required this.summary,
    required this.caption,
    required this.children,
  });
}

/// The groups, in list order.
const List<StoreSettingsGroup> kStoreSettingsGroups = [
  StoreSettingsGroup(
    id: 'deliveries',
    title: 'Deliveries',
    icon: Icons.delivery_dining_outlined,
    summary: 'Delivery area, AUTO, nearby rule, auto-assign',
    caption: 'How AUTO plans runs, which deliveries count as close to a run, and auto-assign.',
    children: [DeliveryAreaCard(), DeliveriesSettingsCard(), AutoAssignCard()],
  ),
  StoreSettingsGroup(
    id: 'drivers',
    title: 'Drivers',
    icon: Icons.badge_outlined,
    summary: 'Your drivers, Driver #, phones, shifts',
    caption: 'Your drivers, their Driver # and phones, and the shifts.',
    children: [DriversSettingsCard()],
  ),
  StoreSettingsGroup(
    id: 'times',
    title: 'New orders',
    icon: Icons.notifications_active_outlined,
    summary: 'Auto-accept, default prep times',
    caption: 'Auto-accept, and where the time picker starts when you accept an order.',
    children: [AutoAcceptCard(), DefaultTimesSettingsCard()],
  ),
  StoreSettingsGroup(
    id: 'tickets',
    title: 'Kitchen tickets',
    icon: Icons.receipt_long_outlined,
    summary: 'Which orders print station tickets',
    caption: 'Which orders print station tickets by themselves.',
    children: [KitchenTicketsSettingsCard()],
  ),
  StoreSettingsGroup(
    id: 'receipts',
    title: 'Receipts',
    icon: Icons.print_outlined,
    summary: 'How tickets and receipts look on paper',
    caption: 'How the kitchen tickets and the customer receipt look on paper.',
    children: [ReceiptSettingsCard()],
  ),
  StoreSettingsGroup(
    id: 'callout',
    title: 'Order callout',
    icon: Icons.campaign_outlined,
    summary: 'The store speaker calls ready orders',
    caption: 'The store speaker calls ready counter orders by ticket number.',
    children: [OrderCalloutCard()],
  ),
  StoreSettingsGroup(
    id: 'colors',
    title: 'Colors',
    icon: Icons.palette_outlined,
    summary: 'Accent, ticket colours by type',
    caption: "The store's colours — every tablet and the Pi's web page.",
    children: [StoreColorsCard()],
  ),
  StoreSettingsGroup(
    id: 'look',
    title: 'Sound & look',
    icon: Icons.tune,
    summary: 'Chime, light or dark, motion — this tablet',
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
      IdleKitchenCard(),
    ],
  ),
];

/// Store mode → Settings (1.6.0): what the store decides, in groups. 2.0.5
/// (owner): a list like Android's Settings — tap a group to open its page,
/// the back arrow (or Android's back) returns to the list. The Pi, pairing,
/// feature switches and diagnostics live in developer mode.
class StoreSettingsScreen extends StatefulWidget {
  const StoreSettingsScreen({super.key});

  @override
  State<StoreSettingsScreen> createState() => _StoreSettingsScreenState();
}

class _StoreSettingsScreenState extends State<StoreSettingsScreen> {
  StoreSettingsGroup? _open;

  void _show(StoreSettingsGroup? g) => setState(() => _open = g);

  @override
  Widget build(BuildContext context) {
    final g = _open;
    final page = g == null ? _list(context) : _page(context, g);
    return PopScope(
      canPop: g == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _show(null);
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: KeyedSubtree(key: ValueKey(g?.id ?? 'settings-list'), child: page),
      ),
    );
  }

  Widget _list(BuildContext context) => ListView(
    padding: QuiccSpace.paneInsets,
    children: [
      const PaneHeader(
        title: 'Settings',
        subtitle: 'How this store works. Most of it is saved on the Pi for every tablet.',
      ),
      const ContinueSetupCard(),
      Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final (i, grp) in kStoreSettingsGroups.indexed) ...[
              if (i > 0) Divider(height: 1, indent: 72, color: context.palette.borderSoft),
              ListTile(
                key: ValueKey('group-${grp.id}'),
                minTileHeight: 76,
                contentPadding: const EdgeInsets.symmetric(horizontal: QuiccSpace.lg),
                leading: Icon(grp.icon, size: 30, color: QuiccColors.brand400),
                title: Text(grp.title, style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700)),
                subtitle: Text(
                  grp.summary,
                  style: QuiccType.text(QuiccType.label, color: context.palette.textSecondary),
                ),
                trailing: Icon(Icons.chevron_right, color: context.palette.textMuted),
                onTap: () => _show(grp),
              ),
            ],
          ],
        ),
      ),
    ],
  );

  Widget _page(BuildContext context, StoreSettingsGroup g) => ListView(
    key: ValueKey('settings-page-${g.id}'),
    padding: QuiccSpace.paneInsets,
    children: [
      Row(
        children: [
          IconButton(
            key: const ValueKey('settings-back'),
            tooltip: 'Back to Settings',
            iconSize: 32,
            onPressed: () => _show(null),
            icon: const Icon(Icons.arrow_back),
          ),
          QuiccSpace.gapSm,
          Expanded(child: PaneHeader(title: g.title, subtitle: g.caption)),
        ],
      ),
      QuiccSpace.gapMd,
      ...g.children,
    ],
  );
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
