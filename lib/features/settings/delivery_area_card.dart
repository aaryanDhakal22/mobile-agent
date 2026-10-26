import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/delivery_models.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'deliveries_settings_card.dart';
import 'settings_card.dart';

const kDeliveryAreaInfo = InfoText(
  'Delivery area and nearby',
  'Delivery radius: how far the store delivers, measured from the store. A delivery farther away '
      'gets the red "outside area" tag. Saved on the Quicc website too, so the website, the Pi and '
      'every tablet use the same circle.\n\n'
      'Nearby rule: when you press NEXT on the driver button, the tablet first checks whether a '
      'delivery nobody has yet is close to that driver\'s run. If one is, it opens Deliveries with '
      'that delivery glowing, so you can add it before he leaves.\n\n'
      '• Extra driving: close when adding it makes his run at most this many minutes longer.\n'
      '• Distance: close when it is within this many miles of one of his stops.\n'
      '• AUTO would bundle it: close when AUTO would put it in his run.\n'
      '• Off: NEXT never checks.',
);

const double _metersPerMile = 1609.344;

/// Store settings → Deliveries (2.2.0): the delivery radius (synced to main)
/// and the nearby rule for the driver button's NEXT. A Pi without them shows
/// the two rows greyed, "coming with the next Pi update".
class DeliveryAreaCard extends ConsumerStatefulWidget {
  const DeliveryAreaCard({super.key});

  @override
  ConsumerState<DeliveryAreaCard> createState() => _DeliveryAreaCardState();
}

class _DeliveryAreaCardState extends ConsumerState<DeliveryAreaCard> {
  /// Edits in progress (null = what the Pi has). Radius in tenths of a mile,
  /// distance in tenths of a mile.
  int? _radiusTenths;
  NearbyRule? _rule;
  int? _detour;
  int? _distanceTenths;
  bool _saving = false;

  void _undo() => setState(() {
    _radiusTenths = null;
    _rule = null;
    _detour = null;
    _distanceTenths = null;
  });

  Future<void> _save(Floor f, {required bool radiusChanged, required int radiusTenths}) async {
    setState(() => _saving = true);
    try {
      await ref
          .read(floorProvider.notifier)
          .setDeliverySettings(
            DeliverySettings(
              soonReadyMinutes: f.soonReadyMinutes,
              deliveryTargetMinutes: f.deliveryTargetMinutes,
              nearbyRule: _rule ?? f.nearbyRule,
              nearbyDetourMinutes: _detour ?? f.nearbyDetourMinutes,
              nearbyDistanceMi: (_distanceTenths ?? (f.nearbyDistanceMi * 10).round()) / 10,
              deliveryRadiusM: radiusChanged ? (radiusTenths / 10 * _metersPerMile).round() : null,
            ),
          );
      if (!mounted) return;
      _undo();
      toast(context, 'Saved');
    } catch (e) {
      if (!mounted) return;
      final lead = e is AgentException && e.code == 'main_offline'
          ? "Not saved — the Pi couldn't reach the Quicc website to change the radius"
          : e is AgentException && e.code == 'main_unsupported'
          ? 'Not saved — the Quicc website needs an update for the radius'
          : 'Delivery area not saved';
      toastError(context, e, lead: lead, area: 'settings');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(floorProvider.select((s) => s.floor));
    final paired = ref.watch(agentClientProvider) != null;
    final palette = context.palette;
    if (f == null || f.nearbyRule == null) {
      return const SettingsCard(
        title: 'Delivery area and nearby',
        info: kDeliveryAreaInfo,
        children: [
          ComingSoonRow(
            key: ValueKey('coming-radius'),
            icon: Icons.radar,
            title: 'Delivery radius',
            explanation: 'How far the store delivers. Farther orders get the "outside area" tag.',
          ),
          ComingSoonRow(
            key: ValueKey('coming-nearby'),
            icon: Icons.near_me_outlined,
            title: 'Nearby rule',
            explanation: 'When NEXT on the driver button sends you to Deliveries for a close-by order first.',
          ),
        ],
      );
    }
    if (!paired) {
      return SettingsCard(
        title: 'Delivery area and nearby',
        info: kDeliveryAreaInfo,
        children: [Text('Pair this tablet with the Pi first.', style: TextStyle(color: palette.textMuted))],
      );
    }

    final savedRadius = ((f.store?.deliveryRadiusM ?? 8047) / _metersPerMile * 10).round();
    final radius = _radiusTenths ?? savedRadius;
    final rule = _rule ?? f.nearbyRule!;
    final detour = _detour ?? f.nearbyDetourMinutes;
    final savedDistance = (f.nearbyDistanceMi * 10).round();
    final distance = _distanceTenths ?? savedDistance;
    final radiusChanged = radius != savedRadius;
    final dirty =
        radiusChanged || rule != f.nearbyRule || detour != f.nearbyDetourMinutes || distance != savedDistance;
    final maxRadius = savedRadius > 200 ? savedRadius : 200;

    return SettingsCard(
      title: 'Delivery area and nearby',
      info: kDeliveryAreaInfo,
      subtitle: 'How far the store delivers, and when NEXT checks for a delivery close to the run.',
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Delivery radius', style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
                  Text(
                    'Farther deliveries get the "outside area" tag. Saved on the Quicc website too.',
                    style: TextStyle(color: palette.textSecondary),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 120,
              child: Text(
                '${(radius / 10).toStringAsFixed(1)} mi',
                key: const ValueKey('radius-value'),
                textAlign: TextAlign.center,
                style: QuiccType.number(QuiccType.heading, weight: FontWeight.w700, color: QuiccColors.brand400),
              ),
            ),
          ],
        ),
        Slider(
          key: const ValueKey('radius-slider'),
          min: 5,
          max: maxRadius.toDouble(),
          divisions: (maxRadius - 5) ~/ 5,
          value: radius.clamp(5, maxRadius).toDouble(),
          label: '${(radius / 10).toStringAsFixed(1)} mi',
          onChanged: _saving ? null : (v) => setState(() => _radiusTenths = (v / 5).round() * 5),
        ),
        QuiccSpace.gapMd,
        Text('Nearby rule', style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
        Text(
          'When NEXT first sends you to Deliveries for a delivery close to the run.',
          style: TextStyle(color: palette.textSecondary),
        ),
        QuiccSpace.gapSm,
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<NearbyRule>(
            key: const ValueKey('nearby-rule'),
            style: SegmentedButton.styleFrom(
              minimumSize: const Size(0, 56),
              textStyle: QuiccType.text(QuiccType.label, weight: FontWeight.w600),
            ),
            segments: const [
              ButtonSegment(value: NearbyRule.detour, icon: Icon(Icons.timer_outlined), label: Text('Extra driving')),
              ButtonSegment(value: NearbyRule.distance, icon: Icon(Icons.straighten), label: Text('Distance')),
              ButtonSegment(value: NearbyRule.bundle, icon: Icon(Icons.auto_awesome), label: Text('AUTO would bundle')),
              ButtonSegment(value: NearbyRule.off, icon: Icon(Icons.block), label: Text('Off')),
            ],
            selected: {rule},
            onSelectionChanged: _saving ? null : (v) => setState(() => _rule = v.first),
          ),
        ),
        QuiccSpace.gapMd,
        if (rule == NearbyRule.detour)
          SettingsStepper(
            key: const ValueKey('nearby-detour'),
            label: 'Extra driving',
            help: 'Close when it adds at most',
            value: detour,
            step: 1,
            min: DeliverySettings.minDetour,
            max: DeliverySettings.maxDetour,
            onChanged: (v) => setState(() => _detour = v),
          ),
        if (rule == NearbyRule.distance)
          SettingsStepper(
            key: const ValueKey('nearby-distance'),
            label: 'Distance',
            help: 'Close when it is within',
            value: distance,
            step: 1,
            min: (DeliverySettings.minDistanceMi * 10).round(),
            max: (DeliverySettings.maxDistanceMi * 10).round(),
            format: (v) => '${(v / 10).toStringAsFixed(1)} mi',
            onChanged: (v) => setState(() => _distanceTenths = v),
          ),
        if (rule == NearbyRule.bundle)
          Text(
            'Uses the same planner as AUTO, for the next driver only.',
            style: TextStyle(color: palette.textMuted),
          ),
        QuiccSpace.gapMd,
        Row(
          children: [
            SizedBox(
              height: 56,
              child: FilledButton(
                key: const ValueKey('delivery-area-save'),
                onPressed: (!dirty || _saving) ? null : () => _save(f, radiusChanged: radiusChanged, radiusTenths: radius),
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('SAVE'),
              ),
            ),
            QuiccSpace.gapMd,
            if (dirty) TextButton(onPressed: _saving ? null : _undo, child: const Text('UNDO')),
          ],
        ),
      ],
    );
  }
}
