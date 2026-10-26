import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'deliveries_settings_card.dart';
import 'settings_card.dart';
import 'settings_texts.dart';
import '../../theme/quicc_type.dart';
import '../../theme/quicc_spacing.dart';

/// One switch: wire key, label and a short line under it.
typedef SwitchSpec = ({String key, String label, String help});

/// Settings → Features: the six feature switches (`/api/settings/features`).
const List<SwitchSpec> kFeatureSwitches = [
  (key: 'pos_pull', label: 'POS orders pull-in', help: 'Phone and counter orders from the old POS show here'),
  (key: 'order_insert', label: 'Online order insert', help: 'Online cash pickups go into the old POS on accept'),
  (key: 'driver_writeback', label: 'Driver write-back', help: 'The old POS learns who took its deliveries'),
  (key: 'address_heal', label: 'Address heal', help: 'Addresses fixed here are fixed in the old POS'),
  (key: 'future_orders', label: 'Future orders', help: 'Orders for later ring when it is time to cook'),
  (key: 'paid_wave', label: 'Paid wave', help: 'A slow wave on paid tickets that aren\'t ready'),
];

/// Settings → Kitchen tickets: the six station-ticket switches
/// (`/api/settings/tickets`).
const List<SwitchSpec> kTicketSwitches = [
  (key: 'pos_delivery', label: 'POS delivery', help: 'Usually off — the old POS prints these'),
  (key: 'pos_takeout', label: 'POS takeout', help: 'Usually off — the old POS prints these'),
  (key: 'pos_counter', label: 'POS counter', help: 'Usually off — the old POS prints these'),
  (key: 'online_cash_pickup', label: 'Online cash pickup', help: 'Only while the hub puts them into the old POS'),
  (key: 'online_cash_delivery', label: 'Online cash delivery', help: 'Tickets + receipt'),
  (key: 'online_card', label: 'Online card (paid)', help: 'Tickets + receipt'),
];

/// A card of switches saved one by one: flips at once, goes back if the Pi
/// says no.
class _SwitchCard extends ConsumerStatefulWidget {
  final String title;
  final String subtitle;
  final InfoText info;
  final List<SwitchSpec> switches;
  final Map<String, bool> Function(FloorSettings) read;
  final Future<void> Function(FloorController floor, Map<String, bool> next) save;

  const _SwitchCard({
    required this.title,
    required this.subtitle,
    required this.info,
    required this.switches,
    required this.read,
    required this.save,
  });

  @override
  ConsumerState<_SwitchCard> createState() => _SwitchCardState();
}

class _SwitchCardState extends ConsumerState<_SwitchCard> {
  /// Flipped here, not yet confirmed by the Pi.
  final Map<String, bool> _pending = {};
  bool _needsUpdate = false;

  Future<void> _flip(String key, bool on) async {
    final saved = widget.read(ref.read(floorProvider).settings);
    setState(() => _pending[key] = on);
    try {
      await widget.save(ref.read(floorProvider.notifier), {...saved, ..._pending});
      if (mounted) setState(() => _pending.remove(key));
    } catch (e) {
      if (!mounted) return;
      setState(() => _pending.remove(key));
      if (e is AgentException && e.code == kSettingsUnsupported) {
        setState(() => _needsUpdate = true);
      } else {
        toastError(context, e, lead: '${widget.title} not saved', area: 'settings');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final paired = ref.watch(agentClientProvider) != null;
    final saved = widget.read(ref.watch(floorProvider.select((s) => s.settings)));
    return SettingsCard(
      title: widget.title,
      info: widget.info,
      subtitle: widget.subtitle,
      children: [
        if (!paired)
          Text('Pair this tablet with the Pi first.', style: TextStyle(color: context.palette.textMuted))
        else if (_needsUpdate)
          Text(
            'This Pi needs an update for these switches.',
            style: QuiccType.text(QuiccType.body, color: context.palette.textSecondary),
          )
        else
          for (final sw in widget.switches)
            SwitchListTile(
              key: ValueKey('switch-${sw.key}'),
              contentPadding: EdgeInsets.zero,
              title: Text(sw.label, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
              subtitle: Text(sw.help, style: TextStyle(color: context.palette.textSecondary)),
              value: _pending[sw.key] ?? saved[sw.key] ?? false,
              onChanged: _pending.containsKey(sw.key) ? null : (on) => _flip(sw.key, on),
            ),
      ],
    );
  }
}

class FeaturesSettingsCard extends StatelessWidget {
  const FeaturesSettingsCard({super.key});

  @override
  Widget build(BuildContext context) => _SwitchCard(
    title: 'Features',
    subtitle: 'Turn the newer parts on or off. Saved on the Pi.',
    info: kFeaturesInfo,
    switches: kFeatureSwitches,
    read: (s) => s.features.toJson(),
    save: (floor, next) => floor.saveFeatures(FeatureToggles.fromJson(next)),
  );
}

class KitchenTicketsSettingsCard extends StatelessWidget {
  const KitchenTicketsSettingsCard({super.key});

  @override
  Widget build(BuildContext context) => _SwitchCard(
    title: 'Kitchen tickets',
    subtitle: 'Which orders print station tickets by themselves.',
    info: kTicketsInfo,
    switches: kTicketSwitches,
    read: (s) => s.tickets.toJson(),
    save: (floor, next) => floor.saveTickets(TicketToggles.fromJson(next)),
  );
}

/// The two default-time steppers (X pickup / dine-in, Y delivery), shared by
/// Settings and the setup wizard.
class DefaultTimesFields extends StatelessWidget {
  final DefaultTimes value;
  final ValueChanged<DefaultTimes> onChanged;
  const DefaultTimesFields({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SettingsStepper(
        key: const ValueKey('default-pickup'),
        label: 'Pickup & counter',
        help: 'Ready in (the first choice when accepting)',
        value: value.defaultPickupMinutes,
        step: 5,
        min: 5,
        max: DefaultTimes.maxMinutes,
        onChanged: (v) =>
            onChanged(DefaultTimes(defaultPickupMinutes: v, defaultDeliveryMinutes: value.defaultDeliveryMinutes)),
      ),
      QuiccSpace.gapSm,
      SettingsStepper(
        key: const ValueKey('default-delivery'),
        label: 'Delivery',
        help: 'Ready in (the first choice for deliveries)',
        value: value.defaultDeliveryMinutes,
        step: 5,
        min: 5,
        max: DefaultTimes.maxMinutes,
        onChanged: (v) =>
            onChanged(DefaultTimes(defaultPickupMinutes: value.defaultPickupMinutes, defaultDeliveryMinutes: v)),
      ),
    ],
  );
}

/// Settings → Default times (`PUT /api/settings/times`).
class DefaultTimesSettingsCard extends ConsumerStatefulWidget {
  const DefaultTimesSettingsCard({super.key});

  @override
  ConsumerState<DefaultTimesSettingsCard> createState() => _DefaultTimesSettingsCardState();
}

class _DefaultTimesSettingsCardState extends ConsumerState<DefaultTimesSettingsCard> {
  DefaultTimes? _edit;
  bool _saving = false;
  bool _needsUpdate = false;

  Future<void> _save(DefaultTimes t) async {
    setState(() => _saving = true);
    try {
      final saved = await ref.read(floorProvider.notifier).saveTimes(t);
      if (!mounted) return;
      setState(() => _edit = null);
      toast(context, 'Saved — pickup ${saved.defaultPickupMinutes} min, delivery ${saved.defaultDeliveryMinutes} min');
    } catch (e) {
      if (!mounted) return;
      if (e is AgentException && e.code == kSettingsUnsupported) {
        setState(() => _needsUpdate = true);
      } else {
        toastError(context, e, lead: 'Default times not saved', area: 'settings');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paired = ref.watch(agentClientProvider) != null;
    final saved = ref.watch(floorProvider.select((s) => s.settings.times));
    final t = _edit ?? saved;
    final dirty = t != saved;
    return SettingsCard(
      title: 'Default times',
      info: kTimesInfo,
      subtitle: 'Where the accept time picker starts.',
      children: [
        if (!paired)
          Text('Pair this tablet with the Pi first.', style: TextStyle(color: context.palette.textMuted))
        else if (_needsUpdate)
          Text(
            'This Pi needs an update for default times.',
            style: QuiccType.text(QuiccType.body, color: context.palette.textSecondary),
          )
        else ...[
          DefaultTimesFields(value: t, onChanged: (v) => setState(() => _edit = v)),
          QuiccSpace.gapMd,
          Row(
            children: [
              SizedBox(
                height: 56,
                child: FilledButton(
                  key: const ValueKey('times-save'),
                  onPressed: (!dirty || _saving) ? null : () => _save(t),
                  child: _saving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('SAVE'),
                ),
              ),
              QuiccSpace.gapMd,
              if (dirty)
                TextButton(onPressed: _saving ? null : () => setState(() => _edit = null), child: const Text('UNDO')),
            ],
          ),
        ],
      ],
    );
  }
}
