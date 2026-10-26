import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diag_models.dart';
import '../../core/format.dart';
import '../../core/friendly_error.dart';
import '../../core/providers.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'checks.dart';
import 'guide_screen.dart';
import 'monitors.dart';
import 'report.dart';
import 'send_dialog.dart';
import 'texts.dart';

export 'guide_screen.dart' show GuideScreen, PairAnotherTabletScreen;
export 'help_screen.dart' show HelpPane;
export 'monitors.dart' show DiagPoller, piDiagProvider, deviceChecksProvider;
export 'report.dart' show reportSenderProvider, ReportSender, ReportOutcome, DiagReport;
export 'send_dialog.dart' show showSendDiagnosticsDialog;

// Entry points into troubleshooting that other screens use. Implemented in
// this folder; this file is the stable surface.

/// Opens [guide] full-screen (FIX IT buttons, the Help tab). [params] e.g.
/// `{'printer': id}` for the printer guide.
Future<void> openGuide(BuildContext context, GuideId guide, {Map<String, String> params = const {}}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GuideScreen(start: guide, params: params),
      ),
    );

/// Points the shared FIX IT hook (common/widgets.dart, used by inline errors
/// and the setup screens) at [openGuide]. Called when Home first shows.
void installGuideHook() => openGuideHook = (context, guide) => openGuide(context, guide);

/// Re-opens the saved, unfinished guide (after a restart).
Future<void> resumeGuide(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GuideScreen()));

/// The Pi's health in a few words, from a diag.
String piHealthSummary(PiDiag? d) {
  if (d == null) return AboutText.unknown;
  final h = d.health;
  if (h.sdTrouble) return 'SD card errors';
  if (h.powerTrouble) return 'Power too weak';
  if (h.fileStale) return AboutText.unknown;
  return AboutText.healthGood;
}

/// Settings → "About & diagnostics": versions, Pi address, store, last sync,
/// Pi health, COPY DIAGNOSTICS and SEND DIAGNOSTICS TO THE OWNER.
class AboutDiagnosticsCard extends ConsumerStatefulWidget {
  const AboutDiagnosticsCard({super.key});

  @override
  ConsumerState<AboutDiagnosticsCard> createState() => _AboutDiagnosticsCardState();
}

class _AboutDiagnosticsCardState extends ConsumerState<AboutDiagnosticsCard> {
  late final Future<String> _version = installedVersionName();

  List<(String, String)> _rows(String version) {
    final pairing = ref.read(pairingProvider);
    final dState = ref.read(piDiagProvider);
    final d = dState.diag ?? readLastPiDiag(ref.read(storageProvider));
    final sync = ref.read(floorProvider).lastSyncAt;
    return [
      (AboutText.appVersion, version),
      (AboutText.piAddress, pairing?.address ?? AboutText.unknown),
      (
        AboutText.piVersion,
        d?.version.isNotEmpty == true ? d!.version : (dState.unsupported ? '2.0.0 or older' : AboutText.unknown),
      ),
      (AboutText.store, d?.storeName.isNotEmpty == true ? d!.storeName : AboutText.unknown),
      (AboutText.lastSync, sync == null ? AboutText.unknown : dateClock(sync)),
      (AboutText.piHealth, piHealthSummary(d)),
    ];
  }

  Future<void> _copy(String version) async {
    final pairing = ref.read(pairingProvider);
    final d = ref.read(piDiagProvider).diag ?? readLastPiDiag(ref.read(storageProvider));
    final lines = [
      'Quibase diagnostics — ${timeNow().toUtc().toIso8601String()}',
      for (final (k, v) in _rows(version)) '$k: $v',
      'Tablet: ${pairing?.deviceName ?? ''} (${pairing?.deviceId ?? ''})',
      if (d != null) ...[
        'Pi link to server: ${d.mainState}${d.mainReachable == false ? ' (server unreachable)' : ''}',
        'Pi problems: ${d.problems.isEmpty ? 'none' : d.problems.join(', ')}',
        for (final p in d.printers) 'Printer ${p.name} ${p.ip}: ${p.up ? 'up' : 'DOWN'}',
      ],
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) toast(context, ReportText.copied);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(piDiagProvider);
    ref.watch(pairingProvider);
    final palette = context.palette;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: FutureBuilder<String>(
          future: _version,
          builder: (context, snap) {
            final version = snap.data ?? '…';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LabelWithInfo(
                  label: Text(AboutText.title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  info: AboutText.info,
                ),
                const SizedBox(height: 12),
                for (final (k, v) in _rows(version))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 170,
                          child: Text(k, style: TextStyle(color: palette.textMuted)),
                        ),
                        Expanded(
                          child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _copy(version),
                      icon: const Icon(Icons.copy),
                      label: const Text(ReportText.copy),
                    ),
                    FilledButton.icon(
                      onPressed: () => showSendDiagnosticsDialog(context, ref),
                      icon: const Icon(Icons.send_outlined),
                      label: const Text(ReportText.sendToOwner),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A small card that says a guide is unfinished, with CONTINUE.
class ResumeGuideBanner extends StatelessWidget {
  final String name;
  final VoidCallback onContinue;
  const ResumeGuideBanner({super.key, required this.name, required this.onContinue});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    decoration: BoxDecoration(
      color: QuiccColors.brand400.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(QuiccRadius.md),
      border: Border.all(color: QuiccColors.brand400.withValues(alpha: 0.5)),
    ),
    child: Row(
      children: [
        const Icon(Icons.play_circle_outline, color: QuiccColors.brand400, size: 30),
        const SizedBox(width: 12),
        Expanded(
          child: Text('Unfinished: $name', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        ),
        FilledButton(onPressed: onContinue, child: const Text('CONTINUE')),
      ],
    ),
  );
}
