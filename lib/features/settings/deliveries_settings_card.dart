import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/delivery_models.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import 'settings_card.dart';
import 'settings_texts.dart';
import '../../theme/quicc_type.dart';
import '../../theme/quicc_spacing.dart';

/// Settings → Deliveries: AUTO's delivery target and "soon ready" minutes
/// (`PUT /api/settings/deliveries`), shown from the floor and saved on the Pi.
class DeliveriesSettingsCard extends ConsumerStatefulWidget {
  const DeliveriesSettingsCard({super.key});

  @override
  ConsumerState<DeliveriesSettingsCard> createState() => _DeliveriesSettingsCardState();
}

class _DeliveriesSettingsCardState extends ConsumerState<DeliveriesSettingsCard> {
  /// What staff are editing (null = showing what the Pi has).
  int? _target;
  int? _soon;
  bool _saving = false;
  bool _needsUpdate = false;

  Future<void> _save(int target, int soon) async {
    setState(() => _saving = true);
    try {
      final s = await ref
          .read(floorProvider.notifier)
          .setDeliverySettings(DeliverySettings(soonReadyMinutes: soon, deliveryTargetMinutes: target));
      if (!mounted) return;
      setState(() {
        _target = null;
        _soon = null;
      });
      toast(context, 'Saved — target ${s.deliveryTargetMinutes} min, soon ready ${s.soonReadyMinutes} min');
    } catch (e) {
      if (!mounted) return;
      if (e is AgentException && e.code == kPoolsUnsupported) {
        setState(() => _needsUpdate = true);
      } else {
        toastError(context, e, lead: 'Delivery settings not saved', area: 'settings');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final floor = ref.watch(floorProvider.select((s) => s.floor));
    final paired = ref.watch(agentClientProvider) != null;
    final savedTarget = floor?.deliveryTargetMinutes ?? kDefaultDeliveryTargetMinutes;
    final savedSoon = floor?.soonReadyMinutes ?? kDefaultSoonReadyMinutes;
    final target = _target ?? savedTarget;
    final soon = _soon ?? savedSoon;
    final dirty = target != savedTarget || soon != savedSoon;

    return SettingsCard(
      title: 'AUTO runs',
      info: kDeliveriesInfo,
      subtitle: 'How AUTO plans the driver runs.',
      children: [
        if (!paired)
          Text('Pair this tablet with the Pi first.', style: TextStyle(color: context.palette.textMuted))
        else if (_needsUpdate)
          Text(
            'This Pi needs an update for delivery settings.',
            style: QuiccType.text(QuiccType.body, color: context.palette.textSecondary),
          )
        else ...[
          SettingsStepper(
            key: const ValueKey('delivery-target'),
            label: 'Delivery target',
            help: 'Most minutes from order to door',
            value: target,
            step: 5,
            min: DeliverySettings.minTarget,
            max: DeliverySettings.maxTarget,
            onChanged: (v) => setState(() => _target = v),
          ),
          QuiccSpace.gapSm,
          SettingsStepper(
            key: const ValueKey('soon-ready'),
            label: 'Soon ready',
            help: 'Also plan food ready within',
            value: soon,
            step: 1,
            min: DeliverySettings.minSoonReady,
            max: DeliverySettings.maxSoonReady,
            onChanged: (v) => setState(() => _soon = v),
          ),
          QuiccSpace.gapMd,
          Row(
            children: [
              SizedBox(
                height: 56,
                child: FilledButton(
                  onPressed: (!dirty || _saving) ? null : () => _save(target, soon),
                  child: _saving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('SAVE'),
                ),
              ),
              QuiccSpace.gapMd,
              if (dirty)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _target = null;
                          _soon = null;
                        }),
                  child: const Text('UNDO'),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A big − value + control (Deliveries, Default times).
class SettingsStepper extends StatelessWidget {
  final String label;
  final String help;
  final int value;
  final int step;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  /// How the value reads (default "N min").
  final String Function(int value)? format;
  const SettingsStepper({
    super.key,
    required this.label,
    required this.help,
    required this.value,
    required this.step,
    required this.min,
    required this.max,
    required this.onChanged,
    this.format,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
            Text(help, style: TextStyle(color: context.palette.textSecondary)),
          ],
        ),
      ),
      IconButton.outlined(
        tooltip: 'Less',
        iconSize: 28,
        onPressed: value <= min ? null : () => onChanged((value - step).clamp(min, max)),
        icon: const Icon(Icons.remove),
      ),
      SizedBox(
        width: 96,
        child: Text(
          format?.call(value) ?? '$value min',
          textAlign: TextAlign.center,
          style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700, color: QuiccColors.brand400),
        ),
      ),
      IconButton.outlined(
        tooltip: 'More',
        iconSize: 28,
        onPressed: value >= max ? null : () => onChanged((value + step).clamp(min, max)),
        icon: const Icon(Icons.add),
      ),
    ],
  );
}
