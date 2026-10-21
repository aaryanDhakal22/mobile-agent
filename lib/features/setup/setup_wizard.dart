import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/alert_player.dart';
import '../../core/device_platform.dart';
import '../../core/local_log.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../diagnose/diagnose_entry.dart';
import 'setup_controller.dart';
import 'setup_flow.dart';
import 'setup_texts.dart';
import 'setup_widgets.dart';
import 'steps/drivers_step.dart';
import 'steps/find_pi_step.dart';
import 'steps/pi_ready_step.dart';
import 'steps/sign_in_step.dart';
import 'steps/tablet_checks_step.dart';
import 'steps/test_print_step.dart';
import 'steps/test_ring_step.dart';

/// First-time setup, step by step: welcome → find the Pi → sign in (manager
/// login for a new Pi, a 6-digit code otherwise) → tablet checks → Pi ready →
/// test ring → test print → drivers → chime → done. Progress is saved on
/// every step (see SetupController); after pairing, "Finish later" lets the
/// counter take orders and Settings offers CONTINUE.
class SetupWizard extends ConsumerWidget {
  const SetupWizard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(setupProvider) ?? SetupProgress.start();
    final ctl = ref.read(setupProvider.notifier);
    final paired = ref.watch(pairingProvider) != null;
    final (pos, total) = SetupFlow.position(p.step);
    // The "orders waiting" strip (AlarmHost) sits over the top of the screen.
    final ringingStrip = ref.watch(alarmProvider.select((a) => a.ringing && !a.visible));

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (ringingStrip) const SizedBox(height: 56),
            Expanded(
              child: Column(
                children: [
                  if (p.step != SetupStep.welcome && p.step != SetupStep.done)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(40, 16, 40, 0),
                      child: Row(
                        children: [
                          if (SetupFlow.canGoBack(p))
                            IconButton(
                              tooltip: 'Back',
                              iconSize: 30,
                              onPressed: ctl.back,
                              icon: const Icon(Icons.arrow_back),
                            )
                          else
                            const SizedBox(width: 48),
                          const SizedBox(width: 8),
                          Text(
                            'Step $pos of $total · ${p.step.label}',
                            style: TextStyle(fontSize: 16, color: context.palette.textSecondary),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(value: pos / total, minHeight: 8),
                            ),
                          ),
                          if (paired && !p.step.beforePairing) ...[
                            const SizedBox(width: 16),
                            TextButton(
                              onPressed: ctl.finishLater,
                              child: const Text('FINISH LATER', style: TextStyle(fontSize: 16)),
                            ),
                          ],
                        ],
                      ),
                    ),
                  Expanded(child: _step(context, ref, p)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(BuildContext context, WidgetRef ref, SetupProgress p) {
    final ctl = ref.read(setupProvider.notifier);
    return switch (p.step) {
      SetupStep.welcome => const _WelcomeStep(),
      SetupStep.findPi => const FindPiStep(),
      SetupStep.signIn => const SignInStep(),
      SetupStep.tabletChecks => const _ChecksStep(),
      SetupStep.piReady => StepLayout(
        title: 'Is the Pi ready?',
        subtitle: 'The Pi checks itself and its printers. This can take up to 30 seconds.',
        info: SetupInfo.piReady,
        body: PiReadyPanel(link: p.link),
        primary: BigButton('CONTINUE', onPressed: ctl.next),
      ),
      SetupStep.testRing => StepLayout(
        title: 'Test the order ring',
        subtitle: 'Make sure everyone at the counter will hear a new order.',
        info: SetupInfo.testRing,
        body: TestRingPanel(onResult: (ok) => ctl.update((x) => x.copyWith(ringOk: ok))),
        primary: BigButton('CONTINUE', onPressed: ctl.next),
      ),
      SetupStep.testPrint => StepLayout(
        title: 'Test the printers',
        subtitle: 'Each printer prints a short TEST slip.',
        info: SetupInfo.testPrint,
        body: TestPrintPanel(
          onResult: (r) => ctl.update((x) => x.copyWith(printOk: r)),
          onFix: (g) => openGuideHook(context, g),
        ),
        primary: BigButton('CONTINUE', onPressed: ctl.next),
      ),
      SetupStep.drivers => StepLayout(
        title: 'Who drives tonight?',
        subtitle: 'Add your drivers and clock in the ones working now. You can skip this.',
        info: SetupInfo.drivers,
        body: const DriversPanel(),
        primary: BigButton('CONTINUE', onPressed: ctl.next),
        secondary: TextButton(
          onPressed: ctl.next,
          child: const Text('SKIP', style: TextStyle(fontSize: 17)),
        ),
      ),
      SetupStep.chime => StepLayout(
        title: 'Pick the order chime',
        subtitle: 'The sound a new order makes. Tap PLAY to hear it.',
        info: SetupInfo.chime,
        body: const _ChimeList(),
        primary: BigButton('CONTINUE', onPressed: ctl.next),
      ),
      SetupStep.done => const _DoneStep(),
    };
  }
}

class _WelcomeStep extends ConsumerWidget {
  const _WelcomeStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget bullet(IconData i, String t) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(i, size: 32, color: QuiccColors.brand400),
          const SizedBox(width: 16),
          Expanded(child: Text(t, style: const TextStyle(fontSize: 20))),
        ],
      ),
    );
    return StepLayout(
      title: "Let's set up this tablet",
      subtitle: 'It takes about 5 minutes. You need the store manager login.',
      info: SetupInfo.welcome,
      body: ListView(
        children: [
          bullet(Icons.router, 'Find the store\'s Pi on the Wi-Fi'),
          bullet(Icons.login, 'Sign in with the store manager login'),
          bullet(Icons.notifications_active, 'Make sure new orders always ring'),
          bullet(Icons.print, 'Test the printers'),
          bullet(Icons.delivery_dining, 'Add tonight\'s drivers'),
        ],
      ),
      primary: BigButton('START', onPressed: () => ref.read(setupProvider.notifier).next()),
    );
  }
}

class _ChecksStep extends ConsumerStatefulWidget {
  const _ChecksStep();

  @override
  ConsumerState<_ChecksStep> createState() => _ChecksStepState();
}

class _ChecksStepState extends ConsumerState<_ChecksStep> {
  DeviceChecks? _c;

  Future<void> _continue() async {
    final ok = _c?.allGood ?? true;
    if (!ok && !await confirmChecksIncomplete(context)) return;
    final ctl = ref.read(setupProvider.notifier);
    ctl.update((p) => p.copyWith(checksOk: ok));
    ctl.next();
  }

  @override
  Widget build(BuildContext context) => StepLayout(
    title: 'Make sure orders always ring',
    subtitle: 'Tap each button and allow it, then come back here.',
    info: SetupInfo.checks,
    body: TabletChecksPanel(onChanged: (c) => _c = c),
    primary: BigButton('CONTINUE', onPressed: _continue),
  );
}

/// The chimes with PLAY and a selected mark.
class _ChimeList extends ConsumerWidget {
  const _ChimeList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(alertSoundProvider);
    return ListView(
      children: [
        for (final s in AlertSound.values)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              onTap: () => ref.read(alertSoundProvider.notifier).set(s),
              leading: Icon(
                s == current ? Icons.radio_button_checked : Icons.radio_button_off,
                color: s == current ? QuiccColors.brand400 : null,
                size: 30,
              ),
              title: Text(s.label, style: const TextStyle(fontSize: 20)),
              trailing: OutlinedButton.icon(
                onPressed: () async {
                  ref.read(alertSoundProvider.notifier).set(s);
                  await AlertPlayer.start(s, preview: true);
                  await Future<void>.delayed(const Duration(seconds: 3));
                  await AlertPlayer.stop(preview: true);
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('PLAY'),
              ),
            ),
          ),
      ],
    );
  }
}

class _DoneStep extends ConsumerWidget {
  const _DoneStep();

  /// Tells the owner how the setup went (main pages only when something
  /// didn't pass). Never blocks: an unsent report waits in the outbox.
  static Future<void> _report(WidgetRef ref, SetupProgress p) async {
    final badPrinters = p.printOk.entries.where((e) => !e.value).length;
    final problems = [
      if (p.checksOk == false) 'tablet checks not done',
      if (p.ringOk == false) 'chime not heard',
      if (badPrinters > 0) '$badPrinters printer${badPrinters == 1 ? '' : 's'} did not print',
    ];
    final log = ref.read(localLogProvider);
    try {
      final sender = ref.read(reportSenderProvider);
      final r = await sender.buildReport(
        kind: 'setup',
        scenario: 'setup',
        outcome: problems.isEmpty ? 'ok' : 'not_fixed',
        headline: problems.isEmpty ? 'Tablet set up' : 'Tablet set up — ${problems.join(', ')}',
        note: p.link == null ? 'joined with a pairing code' : 'new Pi linked (${p.link!.orders} orders restored)',
      );
      await sender.send(r);
    } catch (e) {
      // Reporting is best-effort.
      log.warn('setup', 'setup report not sent: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(setupProvider) ?? SetupProgress.start();
    final printers = p.printOk;
    final printersOk = printers.isNotEmpty && printers.values.every((v) => v);
    Widget line(bool? ok, String good, String bad, String skipped) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            ok == null ? Icons.remove_circle_outline : (ok ? Icons.check_circle : Icons.warning_amber),
            color: ok == null ? context.palette.textMuted : (ok ? QuiccColors.statusPaid : QuiccColors.statusFiring),
            size: 30,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(ok == null ? skipped : (ok ? good : bad), style: const TextStyle(fontSize: 19))),
        ],
      ),
    );
    return StepLayout(
      title: 'All set',
      subtitle: 'This tablet is ready to take orders.',
      body: ListView(
        children: [
          line(true, 'Connected to ${p.piStore.isEmpty ? 'the Pi' : p.piStore}', '', ''),
          line(
            p.checksOk,
            'Tablet checks done',
            'Some tablet checks are not done (Settings → Tablet checks)',
            'Tablet checks skipped',
          ),
          line(p.ringOk, 'The order chime works', 'The chime was not heard — turn the volume up', 'Ring not tested'),
          line(
            printers.isEmpty ? null : printersOk,
            'All printers printed',
            'Some printers did not print (Help → Printer problems)',
            'Printers not tested',
          ),
        ],
      ),
      primary: BigButton(
        'START TAKING ORDERS',
        icon: Icons.check,
        onPressed: () {
          unawaited(_report(ref, p));
          ref.read(setupProvider.notifier).finish();
        },
      ),
    );
  }
}
