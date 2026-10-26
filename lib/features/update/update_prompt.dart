import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import 'updater.dart';

/// Store tablets keep Google Play Protect on, and it asks about every new
/// build of a sideloaded app — the one tap an update still needs.
const kPlayProtectHint =
    'If Google Play Protect asks to scan Quibase, tap More details, then Install without scanning.';

/// "Update ready — install now?" (1.6.1). Only shows when Android needs a
/// tap for an install (or one failed), at a quiet moment — nothing ringing,
/// waiting or cooking — and not while LATER's snooze runs. It never locks
/// the tablet: the app stays usable around it and the new-order alert sits
/// above it (AlarmHost).
class UpdatePrompt extends ConsumerWidget {
  final Widget child;
  const UpdatePrompt({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(updaterProvider);
    final fs = ref.watch(floorProvider);
    final ringing = ref.watch(alarmProvider.select((a) => a.ringing));
    final asking = u.available && u.wantsTap && floorIsQuiet(fs, ringing);
    return Stack(
      children: [
        child,
        if (asking)
          Positioned.fill(
            child: Ticker(
              interval: const Duration(minutes: 1),
              builder: (context, now) => u.snoozed(now) ? const SizedBox.shrink() : _Prompt(u),
            ),
          ),
      ],
    );
  }
}

class _Prompt extends ConsumerWidget {
  final UpdateState u;
  const _Prompt(this.u);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final name = u.target?.versionName ?? '';
    final ctl = ref.read(updaterProvider.notifier);
    final (title, message, action) = switch (u.phase) {
      UpdatePhase.needPermission => (
        'Allow Quibase to update itself',
        'Android needs permission once: tap ALLOW INSTALLS, switch on "Allow from this source", then come back.',
        'ALLOW INSTALLS',
      ),
      UpdatePhase.failed => (
        'Update not finished',
        '${u.error?.short ?? 'Something went wrong'}. Quibase keeps working on the version it has.',
        'TRY AGAIN',
      ),
      _ => (
        'Quibase $name is ready',
        'Install now? It takes about a minute, and Quibase comes back paired and listening for orders by itself.',
        'INSTALL NOW',
      ),
    };
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            key: const ValueKey('update-prompt'),
            color: palette.bgElevated,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(QuiccSpace.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.system_update, size: 48, color: QuiccColors.brand400),
                  QuiccSpace.gapLg,
                  Text(title, style: QuiccType.text(QuiccType.title, weight: FontWeight.w700)),
                  QuiccSpace.gapSm,
                  Text(message, style: QuiccType.text(QuiccType.body, color: palette.textSecondary, height: 1.4)),
                  if (u.phase != UpdatePhase.needPermission) ...[
                    QuiccSpace.gapMd,
                    Text(
                      kPlayProtectHint,
                      style: QuiccType.text(QuiccType.label, color: palette.textMuted, height: 1.4),
                    ),
                  ],
                  if (u.phase == UpdatePhase.failed && (u.error?.details.isNotEmpty ?? false)) ...[
                    QuiccSpace.gapSm,
                    DetailsToggle(u.error!.details),
                  ],
                  QuiccSpace.gapXl,
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(
                        height: 56,
                        child: TextButton(key: const ValueKey('update-later'), onPressed: ctl.snooze, child: const Text('Later')),
                      ),
                      QuiccSpace.gapMd,
                      SizedBox(
                        height: 56,
                        child: FilledButton.icon(
                          key: const ValueKey('update-install'),
                          onPressed: ctl.tapInstall,
                          icon: const Icon(Icons.download_done),
                          label: Text(action),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
