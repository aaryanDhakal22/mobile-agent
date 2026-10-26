import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../settings/settings_card.dart';

/// No touch this long → back to Kitchen (1.7.1).
const Duration kIdleToKitchen = Duration(minutes: 1);

/// "Back to Kitchen after 1 min" — this tablet only, on by default.
class IdleKitchenNotifier extends Notifier<bool> {
  static const _k = 'idle_to_kitchen';

  @override
  bool build() => ref.watch(storageProvider).prefs.getBool(_k) ?? true;

  void set(bool on) {
    state = on;
    unawaited(ref.read(storageProvider).prefs.setBool(_k, on));
  }
}

final idleKitchenProvider = NotifierProvider<IdleKitchenNotifier, bool>(IdleKitchenNotifier.new);

/// Bumped on every touch / key anywhere in the app (the shell's listener,
/// above every route): the home screen restarts its idle minute.
final idleTouchProvider = StateProvider<int>((_) => 0);

/// Bumped when the idle return wants the driver button closed.
final fobCollapseProvider = StateProvider<int>((_) => 0);

const kIdleKitchenInfo = InfoText(
  'Back to Kitchen',
  'When nobody touches the tablet for a minute, it goes back to the Kitchen screen by itself: open '
      'order details, dialogs and other screens close, the driver button folds away, and developer mode '
      'locks.\n\n'
      'It waits while someone is typing, while a new order rings and while an update is being installed.\n\n'
      'Only this tablet.',
);

/// Store settings → Sound & look: the switch.
class IdleKitchenCard extends ConsumerWidget {
  const IdleKitchenCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(idleKitchenProvider);
    return SettingsCard(
      title: 'Back to Kitchen',
      info: kIdleKitchenInfo,
      subtitle: 'After a minute without a touch, the tablet shows Kitchen again.',
      children: [
        SwitchListTile(
          key: const ValueKey('idle-kitchen-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text('Back to Kitchen after 1 min', style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
          subtitle: Text(
            on
                ? 'On — open screens and dialogs close by themselves after 1 min without a touch.'
                : 'Off — the tablet stays where it was left.',
            style: QuiccType.text(QuiccType.caption, color: context.palette.textMuted),
          ),
          value: on,
          onChanged: ref.read(idleKitchenProvider.notifier).set,
        ),
      ],
    );
  }
}
