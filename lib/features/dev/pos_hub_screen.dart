import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_type.dart';
import '../settings/callout_cards.dart';
import '../settings/pos_settings_cards.dart';
import '../settings/settings_card.dart';
import 'dev_texts.dart';
import 'dev_widgets.dart';

/// Developer mode → POS hub (1.6.1): the link to the old POS (SoftTouch) and
/// the switches for what the hub does with it.
class PosHubScreen extends StatelessWidget {
  const PosHubScreen({super.key});

  @override
  Widget build(BuildContext context) => const DevPane(
    title: DevText.posHubTitle,
    subtitle: DevText.posHubSubtitle,
    children: [
      PosLinkCard(),
      FeaturesSettingsCard(
        keys: kPosFeatureKeys,
        title: 'POS switches',
        subtitle: 'What the hub does with the old POS. Saved on the Pi.',
      ),
      FinishingOrdersCard(),
    ],
  );
}

class PosLinkCard extends ConsumerWidget {
  const PosLinkCard({super.key});

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

