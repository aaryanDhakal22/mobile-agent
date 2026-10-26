import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/delivery_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'settings_card.dart';

const kAutoAssignInfo = InfoText(
  'Auto-assign deliveries',
  'When a driver is back or a delivery is ready, the next driver gets it (up to 3 that go together). '
      'They tap SEND OUT themselves.\n\n'
      'The driver button opens on his card with a chime, so he sees what is his. Nobody is ever sent out '
      'by the Pi.\n\n'
      'Off: deliveries wait on the left of Deliveries until someone puts them in a driver\'s box (or AUTO).',
);

/// Store settings → Deliveries (2.2.1): the Pi's simple auto-assign switch
/// (`auto_assign` in /api/floor, saved with PUT /api/settings/deliveries).
/// An older Pi shows it greyed, "coming with the next Pi update".
class AutoAssignCard extends ConsumerStatefulWidget {
  const AutoAssignCard({super.key});

  @override
  ConsumerState<AutoAssignCard> createState() => _AutoAssignCardState();
}

class _AutoAssignCardState extends ConsumerState<AutoAssignCard> {
  bool _saving = false;

  Future<void> _set(bool on) async {
    final f = ref.read(floorProvider).floor;
    if (f == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(floorProvider.notifier)
          .setDeliverySettings(
            DeliverySettings(
              soonReadyMinutes: f.soonReadyMinutes,
              deliveryTargetMinutes: f.deliveryTargetMinutes,
              autoAssign: on,
            ),
          );
      if (mounted) toast(context, on ? 'Auto-assign is on' : 'Auto-assign is off');
    } catch (e) {
      if (mounted) toastError(context, e, lead: 'Auto-assign not changed', area: 'settings');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = ref.watch(floorProvider.select((s) => s.floor?.autoAssign));
    final palette = context.palette;
    return SettingsCard(
      title: 'Auto-assign',
      info: kAutoAssignInfo,
      children: [
        if (on == null)
          const ComingSoonRow(
            key: ValueKey('coming-auto-assign'),
            icon: Icons.assignment_ind_outlined,
            title: 'Auto-assign deliveries',
            explanation: 'The next driver gets the deliveries that are ready; he taps SEND OUT himself.',
          )
        else
          SwitchListTile(
            key: const ValueKey('auto-assign-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text('Auto-assign deliveries', style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
            subtitle: Text(
              on
                  ? 'On — the next driver gets up to 3 that go together; he taps SEND OUT.'
                  : 'Off — deliveries wait until someone puts them in a box.',
              style: TextStyle(color: palette.textSecondary),
            ),
            value: on,
            onChanged: _saving ? null : _set,
          ),
      ],
    );
  }
}
