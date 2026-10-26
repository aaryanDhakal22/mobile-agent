import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_platform.dart';
import '../../core/diag_models.dart';
import '../../core/friendly_error.dart';
import '../../core/providers.dart';
import '../../core/sse.dart';
import '../../core/storage.dart';
import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import '../diagnose/diagnose_entry.dart';
import '../diagnose/texts.dart';
import '../setup/setup_entry.dart';
import '../../theme/quicc_type.dart';
import '../../theme/quicc_spacing.dart';

/// How long a printer must be down before its bar shows (a printer being
/// switched off and on shouldn't flash a warning).
const Duration kPrinterDownWarnAfter = Duration(seconds: 60);

/// Printers down for more than [kPrinterDownWarnAfter], from a Pi diag.
List<DiagPrinter> printersDownLong(PiDiag d, DateTime now) => [
  for (final p in d.printers)
    if (!p.up && (p.downSince == null || now.difference(p.downSince!) > kPrinterDownWarnAfter)) p,
];

/// Open, and no order for longer than the store's quiet limit. `open_now:
/// null` (no schedule set) never warns.
Duration? quietFor(PiDiag d, DateTime now) {
  if (d.openNow != true || d.lastArrivedAt == null) return null;
  final q = now.difference(d.lastArrivedAt!);
  return q > Duration(minutes: d.quietAlertMinutes) ? q : null;
}

/// The tablet checks that keep orders ringing (volume is its own bar).
bool tabletChecksNeedAttention(DeviceChecks c) => !c.notifications || !c.fullScreen || !c.battery || !c.installs;

/// Compact bars stacked at the top of Home: a printer down, no orders while
/// open, the alarm turned down, tablet settings that stop the ring. Each one
/// opens the guide (or screen) that fixes it.
class WarningBars extends ConsumerStatefulWidget {
  const WarningBars({super.key});

  @override
  ConsumerState<WarningBars> createState() => _WarningBarsState();
}

class _WarningBarsState extends ConsumerState<WarningBars> {
  DateTime? _snoozedUntil() {
    final raw = ref.read(storageProvider).getJson(AppStorage.kNoOrdersSnoozedUntil);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> _snooze() async {
    await ref
        .read(storageProvider)
        .setJson(
          AppStorage.kNoOrdersSnoozedUntil,
          DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String(),
        );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final piUp = ref.watch(floorProvider.select((s) => s.connection)) == SseStatus.connected;
    final diag = ref.watch(piDiagProvider);
    final device = ref.watch(deviceChecksProvider);
    final now = DateTime.now();
    final bars = <Widget>[];

    final d = diag.diag;
    // While the Pi is unreachable its own red banner says it all.
    if (piUp && diag.fresh && d != null) {
      final down = printersDownLong(d, now);
      if (down.isNotEmpty) {
        final p = down.first;
        bars.add(
          _Bar(
            icon: Icons.print_disabled_outlined,
            color: QuiccColors.statusVoided,
            text: down.length == 1 ? WarningText.printerDown(p.name) : WarningText.printersDown,
            actions: [
              _FixIt(
                () => openGuide(
                  context,
                  GuideId.printer,
                  params: down.length == 1 ? {'printer': p.id, 'printer_name': p.name, 'printer_ip': p.ip} : const {},
                ),
              ),
            ],
          ),
        );
      }
      final quiet = quietFor(d, now);
      final snoozed = _snoozedUntil();
      if (quiet != null && (snoozed == null || now.isAfter(snoozed))) {
        bars.add(
          _Bar(
            icon: Icons.hourglass_empty,
            color: QuiccColors.statusOpen,
            text: WarningText.noOrdersFor(quiet),
            info: WarningText.noOrdersInfo,
            actions: [
              TextButton(onPressed: _snooze, child: const Text(WarningText.snooze)),
              _FixIt(() => openGuide(context, GuideId.noOrders)),
            ],
          ),
        );
      }
    }

    if (device != null) {
      final pct = device.alarmPercent;
      if (device.alarmQuiet && pct != null) {
        bars.add(
          _Bar(
            icon: Icons.volume_down,
            color: QuiccColors.statusFiring,
            text: WarningText.alarmQuiet(pct),
            info: WarningText.alarmInfo,
          ),
        );
      }
      if (tabletChecksNeedAttention(device)) {
        bars.add(
          _Bar(
            icon: Icons.notifications_off_outlined,
            color: QuiccColors.statusFiring,
            text: WarningText.checksNeedAttention,
            actions: [
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TabletChecksScreen())),
                child: const Text(WarningText.open),
              ),
            ],
          ),
        );
      }
    }

    if (bars.isEmpty) return const SizedBox.shrink();
    if (bars.isEmpty) return const SizedBox.shrink();
    // Clear of the status bar, like the Pi banner above it.
    return SafeArea(
      bottom: false,
      left: false,
      right: false,
      child: Column(mainAxisSize: MainAxisSize.min, children: bars),
    );
  }
}

class _FixIt extends StatelessWidget {
  final VoidCallback onTap;
  const _FixIt(this.onTap);

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onTap,
    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10)),
    child: const Text(GuideText.fixIt),
  );
}

class _Bar extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final InfoText? info;
  final List<Widget> actions;
  const _Bar({required this.icon, required this.color, required this.text, this.info, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 6, 12, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.5))),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 26),
          QuiccSpace.gapMd,
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
            ),
          ),
          if (info != null) InfoButton(info!),
          for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
        ],
      ),
    );
  }
}
