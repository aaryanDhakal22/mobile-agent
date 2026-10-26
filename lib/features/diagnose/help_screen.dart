import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/friendly_error.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import '../illustrations/illustration.dart';
import 'diagnose_entry.dart';
import 'guide_screen.dart';
import 'guide_session.dart';
import 'texts.dart';

/// The Help tab: the four guides and sending diagnostics to the owner. (The
/// checks and tests are in developer mode → Tests.)
class HelpPane extends ConsumerWidget {
  const HelpPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuild when a guide starts / ends so CONTINUE shows up.
    final view = ref.watch(guideControllerProvider);
    final unfinished = view.session != null && !view.session!.concluded
        ? view.session
        : resumableGuideSession(ref.read(storageProvider));

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      children: [
        const PaneHeader(
          title: GuideText.helpTitle,
          subtitle: GuideText.helpSubtitle,
          trailing: InfoButton(GuideText.guidesInfo),
        ),
        if (unfinished != null)
          ResumeGuideBanner(name: guideName(unfinished.guide), onContinue: () => resumeGuide(context)),
        LayoutBuilder(
          builder: (context, box) {
            final cols = box.maxWidth >= 760 ? 2 : 1;
            final w = (box.maxWidth - (cols - 1) * 16) / cols;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final g in GuideId.values)
                  SizedBox(
                    width: w,
                    child: _GuideCard(guide: g, onTap: () => openGuide(context, g)),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 28),
        // Checks, tests and pairing live in developer mode (1.6.0); Help
        // keeps the guides and the way to reach the owner.
        Align(
          alignment: Alignment.centerLeft,
          child: _ToolButton(
            icon: Icons.send_outlined,
            label: GuideText.sendDiag,
            info: GuideText.sendInfo,
            primary: true,
            onTap: () => showSendDiagnosticsDialog(context, ref),
          ),
        ),
      ],
    );
  }
}

(Illustration, IllustrationPart, String, String) _card(GuideId g) => switch (g) {
  GuideId.piUnreachable => (
    Illustration.raspberryPi,
    IllustrationPart.powerLight,
    GuideText.piUnreachableName,
    GuideText.piUnreachableWhen,
  ),
  GuideId.printer => (Illustration.receiptPrinter, IllustrationPart.none, GuideText.printerName, GuideText.printerWhen),
  GuideId.noOrders => (Illustration.router, IllustrationPart.lights, GuideText.noOrdersName, GuideText.noOrdersWhen),
  GuideId.piSwap => (Illustration.sdCard, IllustrationPart.none, GuideText.piSwapName, GuideText.piSwapWhen),
};

class _GuideCard extends StatelessWidget {
  final GuideId guide;
  final VoidCallback onTap;
  const _GuideCard({required this.guide, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (art, part, name, useWhen) = _card(guide);
    final palette = context.palette;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              IllustrationView(art, highlight: part, width: 140),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(useWhen, style: TextStyle(fontSize: 16, height: 1.35, color: palette.textSecondary)),
                    const SizedBox(height: 12),
                    const Row(
                      children: [
                        Text(
                          'START',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                            color: QuiccColors.brand400,
                          ),
                        ),
                        SizedBox(width: 4),
                        Icon(Icons.arrow_forward, color: QuiccColors.brand400, size: 20),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final InfoText? info;
  final bool primary;
  final VoidCallback onTap;
  const _ToolButton({required this.icon, required this.label, required this.onTap, this.info, this.primary = false});

  @override
  Widget build(BuildContext context) {
    const pad = EdgeInsets.symmetric(horizontal: 22, vertical: 20);
    const style = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
    final btn = primary
        ? FilledButton.icon(
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
            style: FilledButton.styleFrom(padding: pad, textStyle: style),
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
            style: OutlinedButton.styleFrom(padding: pad, textStyle: style),
          );
    if (info == null) return btn;
    return Row(mainAxisSize: MainAxisSize.min, children: [btn, InfoButton(info!)]);
  }
}
