import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/diag_models.dart';
import 'package:mobile_agent/core/discovery.dart';
import 'package:mobile_agent/core/friendly_error.dart';
import 'package:mobile_agent/features/diagnose/checks.dart';
import 'package:mobile_agent/features/diagnose/guides.dart';
import 'package:mobile_agent/features/diagnose/texts.dart';

import 'diag_fakes.dart';

String stepOf(Decision d) => switch (d) {
  NextStep(:final step) => step.id,
  Conclude(:final conclusion) => 'conclude:${conclusion.outcome.wire}',
  SwitchGuide(:final to) => 'switch:${to.name}',
};

Conclusion concl(Decision d) => (d as Conclude).conclusion;

void main() {
  group('(a) can\'t reach the Pi', () {
    const g = PiUnreachableGuide();
    final down = snap(piDown: true);

    test('tablet Wi-Fi off → turn it on first', () {
      expect(stepOf(g.decide(snap(piDown: true, onNetwork: false), [])), 'tablet_wifi');
    });

    test('Pi already answers with nothing done → info, not "fixed"', () {
      final c = concl(g.decide(snap(), []));
      expect(c.outcome, Outcome.info);
      expect(c.headline, ConclusionText.piReachableNow);
    });

    test('ip changed → auto switch, then fixed crediting it (ip_changed + DHCP note)', () {
      const moved = DiscoveredPi(address: 'http://192.168.1.50:8080', linked: true);
      final d = g.decide(snap(piDown: true, discovered: [moved], elsewhere: moved), []);
      expect(stepOf(d), 'use_new_address');
      expect((d as NextStep).step.kind, StepKind.auto);
      final c = concl(g.decide(snap(), [rec('use_new_address', 'auto', 'ok')]));
      expect(c.outcome, Outcome.fixed);
      expect(c.cause, 'ip_changed');
      expect(c.fixedBy, 'use_new_address');
      expect(c.note, ConclusionText.ipChangedNote);
    });

    test('no Pi found but the tablet has internet → guest Wi-Fi question; NO → switch Wi-Fi', () {
      expect(stepOf(g.decide(down, [])), 'guest_wifi');
      expect(stepOf(g.decide(down, [rec('guest_wifi', 'no')])), 'guest_wifi_fix');
      expect(stepOf(g.decide(down, [rec('guest_wifi', 'yes')])), 'pi_power_light');
    });

    test('refused → wait for the agent, skipping the ruled-out power light and cable', () {
      final refused = snap(
        piDown: true,
        port: PortState.refused,
        discovered: const [DiscoveredPi(address: kSaved)],
      );
      expect(stepOf(g.decide(refused, [])), 'agent_restart_wait');
      final h = [rec('agent_restart_wait', 'timeout', 'still_down')];
      expect(stepOf(g.decide(refused, h)), 'pi_power_cycle', reason: 'a Pi that refuses has power and a cable');
    });

    test('power light NO → plug it in; fixed credits that', () {
      final found = snap(piDown: true, internet: false);
      expect(stepOf(g.decide(found, [])), 'pi_power_light');
      expect(stepOf(g.decide(found, [rec('pi_power_light', 'no')])), 'pi_power_fix');
      final c = concl(g.decide(snap(), [rec('pi_power_light', 'no'), rec('pi_power_fix', 'test_again', 'fixed')]));
      expect(c.outcome, Outcome.fixed);
      expect(c.cause, 'pi_power');
      expect(c.fixedBy, 'pi_power_fix');
    });

    test('credits the LAST action that could fix it', () {
      final h = [
        rec('pi_power_light', 'yes'),
        rec('pi_cable', 'test_again', 'still_down'),
        rec('pi_power_cycle', 'test_again', 'fixed'),
      ];
      final c = concl(g.decide(snap(), h));
      expect(c.fixedBy, 'pi_power_cycle');
      expect(c.cause, 'pi_frozen');
      expect(c.headline, startsWith(ConclusionText.fixedPrefix));
    });

    test('SD card is ranked right after the power light when the last health showed SD errors', () {
      final h = [rec('pi_power_light', 'yes')];
      final noInternet = snap(piDown: true, internet: false);
      expect(stepOf(g.decide(noInternet, h)), 'pi_cable', reason: 'no SD history: cable first');
      final sdBad = snap(piDown: true, internet: false, lastDiag: diagOf(health: const PiHealth(sdErrors: 12)));
      expect(stepOf(g.decide(sdBad, h)), 'sd_swap');
    });

    test('swap: steps in order, new card links → needs_part (sd_swap)', () {
      final s = snap(piDown: true, internet: false);
      var h = [
        rec('pi_power_light', 'yes'),
        rec('pi_cable', 'test_again', 'still_down'),
        rec('pi_power_cycle', 'test_again', 'still_down'),
      ];
      expect(stepOf(g.decide(s, h)), 'sd_swap');
      h = [...h, rec('sd_swap', 'next')];
      expect(stepOf(g.decide(s, h)), 'swap_unplug');
      h = [...h, rec('swap_unplug', 'next')];
      expect(stepOf(g.decide(s, h)), 'swap_card');
      h = [...h, rec('swap_card', 'next'), rec('swap_plug', 'next')];
      expect(stepOf(g.decide(s, h)), 'swap_wait_new');
      // The new card comes up (same IP even: unconfigured) — still not "fixed".
      final fresh = snap(session: newSession, internet: false);
      h = [...h, rec('swap_wait_new', 'auto', 'ok')];
      expect(stepOf(g.decide(fresh, h)), 'swap_login');
      h = [...h, rec('swap_login', 'auto', 'linked')];
      expect(stepOf(g.decide(snap(), h)), 'swap_ready');
      h = [...h, rec('swap_ready', 'auto', 'fixed')];
      final c = concl(g.decide(snap(), h));
      expect(c.outcome, Outcome.needsPart);
      expect(c.fixedBy, 'sd_swap');
      expect(c.cause, 'sd_card');
      expect(c.headline, ConclusionText.swapWorked);
    });

    test('swap: the new card never shows up → put the original back → needs_owner', () {
      final s = snap(piDown: true, internet: false);
      var h = [
        rec('sd_swap', 'next'),
        rec('swap_unplug', 'next'),
        rec('swap_card', 'next'),
        rec('swap_plug', 'next'),
        rec('swap_wait_new', 'timeout', 'still_down'),
      ];
      expect(stepOf(g.decide(s, h)), 'swap_back');
      h = [...h, rec('swap_back', 'next')];
      final c = concl(g.decide(s, h));
      expect(c.outcome, Outcome.needsOwner);
      expect(c.headline, ConclusionText.swapNeverStarted);
    });

    test('never offers the old card back after the new one linked', () {
      final h = [
        rec('sd_swap', 'next'),
        rec('swap_unplug', 'next'),
        rec('swap_card', 'next'),
        rec('swap_plug', 'next'),
        rec('swap_wait_new', 'auto', 'ok'),
        rec('swap_login', 'auto', 'linked'),
      ];
      expect(stepOf(g.decide(snap(piDown: true), h)), 'swap_ready');
      final timedOut = [...h, rec('swap_ready', 'timeout', 'still_down')];
      final d = g.decide(snap(piDown: true), timedOut);
      expect(concl(d).outcome, Outcome.needsPart);
    });

    test('a link made outside the guide (setup wizard) skips the wait — and never the swap-back', () {
      final h = [
        rec('sd_swap', 'next'),
        rec('swap_unplug', 'next'),
        rec('swap_card', 'next'),
        rec('swap_plug', 'next'),
        rec('swap_login', 'auto', 'linked'),
      ];
      expect(stepOf(g.decide(snap(), h)), 'swap_ready');
      final late = [...h, rec('swap_wait_new', 'timeout', 'still_down')];
      expect(stepOf(g.decide(snap(), late)), 'swap_ready');
    });

    test('ladder exhausted → needs_owner', () {
      final s = snap(piDown: true, internet: false);
      final h = [
        rec('pi_power_light', 'yes'),
        rec('pi_cable', 'test_again', 'still_down'),
        rec('pi_power_cycle', 'test_again', 'still_down'),
        rec('sd_swap', 'next'),
        rec('swap_unplug', 'next'),
        rec('swap_card', 'next'),
        rec('swap_plug', 'next'),
        rec('swap_wait_new', 'timeout', 'still_down'),
        rec('swap_back', 'next'),
      ];
      expect(concl(g.decide(s, h)).outcome, Outcome.needsOwner);
      // Without the swap in history the ladder itself still ends at the card.
      expect(stepOf(g.decide(s, h.sublist(0, 3))), 'sd_swap');
    });

    test('a wiped Pi at the saved address → the swap / login guide', () {
      expect(stepOf(g.decide(snap(session: newSession), [])), 'switch:piSwap');
    });
  });

  group('(b) printer', () {
    const g = PrinterGuide();

    test('Pi unreachable → switch to (a)', () {
      expect(stepOf(g.decide(snap(piDown: true), [])), 'switch:piUnreachable');
    });

    test('the down printer is picked; power light first', () {
      final s = snap(diag: diagOf(printers: [kitchen, down(receipt)]));
      expect(g.pin(s, const {})['printer'], 'p2');
      final p = {...g.pin(s, const {})};
      expect(stepOf(g.decide(s, [], p)), 'printer_power_light');
      expect(stepOf(g.decide(s, [rec('printer_power_light', 'no')], p)), 'printer_power_fix');
      expect(
        stepOf(g.decide(s, [rec('printer_power_light', 'yes')], p)),
        'printer_paper',
        reason: 'power OK → skip the fix',
      );
    });

    test('all printers down while the Pi is up → the network switch first', () {
      final s = snap(diag: diagOf(printers: [down(kitchen), down(receipt)]));
      expect(stepOf(g.decide(s, [], g.pin(s, const {}))), 'switch_check');
    });

    test('power-cycle brings it back → fixed, credited', () {
      final p = {'printer': 'p2', 'printer_name': 'Online'};
      final h = [
        rec('printer_power_light', 'yes'),
        rec('printer_paper', 'yes'),
        rec('printer_cable', 'test_again', 'still_down'),
        rec('printer_power_cycle', 'test_again', 'fixed'),
      ];
      final c = concl(g.decide(snap(), h, p));
      expect(c.outcome, Outcome.fixed);
      expect(c.fixedBy, 'printer_power_cycle');
    });

    test('a probe overrides the diag: up now', () {
      final s = snap(
        diag: diagOf(printers: [kitchen, down(receipt)]),
        probe: const [PrinterTestResult(id: 'p2', name: 'Online', ok: true)],
      );
      expect(s.printerUp('p2'), isTrue);
    });

    test('answers but prints nothing → test print → paper orientation → fixed', () {
      final p = {'printer': 'p1', 'printer_name': 'Kitchen'};
      final s = snap();
      expect(stepOf(g.decide(s, [], p)), 'test_print');
      var h = [rec('test_print', 'auto', 'ok')];
      expect(stepOf(g.decide(s, h, p)), 'slip_came_out');
      h = [...h, rec('slip_came_out', 'no')];
      expect(stepOf(g.decide(s, h, p)), 'paper_orientation');
      h = [...h, rec('paper_orientation', 'test_again', 'fixed')];
      expect(stepOf(g.decide(s, h, p)), 'test_print_2', reason: 'answering ≠ printing: test again');
      h = [...h, rec('test_print_2', 'auto', 'ok'), rec('slip_after_paper', 'yes')];
      final c = concl(g.decide(s, h, p));
      expect(c.outcome, Outcome.fixed);
      expect(c.fixedBy, 'paper_orientation');
    });

    test('slip came out first time → works, nothing to report', () {
      final p = {'printer': 'p1'};
      final c = concl(g.decide(snap(), [rec('test_print', 'auto', 'ok'), rec('slip_came_out', 'yes')], p));
      expect(c.outcome, Outcome.info);
      expect(c.report, isFalse);
    });

    test('exhausted → needs_owner naming the printer and its address', () {
      final s = snap(diag: diagOf(printers: [kitchen, down(receipt)]));
      final p = g.pin(s, const {});
      final h = [
        rec('printer_power_light', 'yes'),
        rec('printer_paper', 'yes'),
        rec('printer_cable', 'test_again', 'still_down'),
        rec('printer_power_cycle', 'test_again', 'still_down'),
      ];
      final c = concl(g.decide(s, h, p));
      expect(c.outcome, Outcome.needsOwner);
      expect(c.headline, contains('Online at 192.168.1.101'));
    });

    test('nothing down and several printers → pick one', () {
      expect(stepOf(g.decide(snap(), [])), 'pick_printer');
    });
  });

  group('(c) no orders', () {
    const g = NoOrdersGuide();

    test('Pi down → switch to (a)', () {
      expect(stepOf(g.decide(snap(piDown: true), [])), 'switch:piUnreachable');
    });

    test('unlinked → explain, then the swap / login guide', () {
      final s = snap(diag: diagOf(mainState: 'rejected'));
      expect(stepOf(g.decide(s, [])), 'unlinked');
      expect(stepOf(g.decide(s, [rec('unlinked', 'next')])), 'switch:piSwap');
    });

    test('everything works → info, not fixed', () {
      final c = concl(g.decide(snap(), []));
      expect(c.outcome, Outcome.info);
      expect(c.headline, ConclusionText.allOk);
    });

    test('store internet down → router lights → restart router → needs_owner (call the provider)', () {
      final s = snap(internet: false, mainFromTablet: false, diag: diagOf(mainState: 'connecting', reachable: false));
      expect(stepOf(g.decide(s, [])), 'router_lights');
      expect(stepOf(g.decide(s, [rec('router_lights', 'yes')])), 'router_restart');
      final c = concl(g.decide(s, [rec('router_lights', 'yes'), rec('router_restart', 'test_again', 'still_down')]));
      expect(c.outcome, Outcome.needsOwner);
      expect(c.cause, 'store_internet');
      expect(c.meanwhile, contains('phone'));
    });

    test('router restart fixes it → fixed (store_internet)', () {
      final c = concl(g.decide(snap(), [rec('router_lights', 'no'), rec('router_restart', 'test_again', 'fixed')]));
      expect(c.outcome, Outcome.fixed);
      expect(c.fixedBy, 'router_restart');
    });

    test('server down from both → owner told, no physical steps', () {
      final s = snap(mainFromTablet: false, diag: diagOf(mainState: 'connecting', reachable: false));
      final c = concl(g.decide(s, []));
      expect(c.outcome, Outcome.needsOwner);
      expect(c.cause, 'main_down');
    });

    test('tablet internet fine, Pi offline → Pi cable → restart → needs_owner', () {
      final s = snap(mainFromTablet: true, diag: diagOf(mainState: 'connecting', reachable: false));
      expect(stepOf(g.decide(s, [])), 'pi_cable');
      expect(stepOf(g.decide(s, [rec('pi_cable', 'test_again', 'still_down')])), 'pi_power_cycle');
      final c = concl(
        g.decide(s, [rec('pi_cable', 'test_again', 'still_down'), rec('pi_power_cycle', 'test_again', 'still_down')]),
      );
      expect(c.outcome, Outcome.needsOwner);
      expect(c.cause, 'pi_network');
    });
  });

  group('(d) Pi swap / re-pair', () {
    const g = PiSwapGuide();

    test('asks what is needed; "pair another tablet" shows the code, unreported', () {
      expect(stepOf(g.decide(snap(), [])), 'd_choice');
      expect(stepOf(g.decide(snap(), [rec('d_choice', 'pair')])), 'pair_code');
      final c = concl(g.decide(snap(), [rec('d_choice', 'pair'), rec('pair_code', 'next')]));
      expect(c.report, isFalse);
    });

    test('swap: the steps, then needs_part', () {
      expect(stepOf(g.decide(snap(), [rec('d_choice', 'swap')])), 'swap_unplug');
      final h = [
        rec('d_choice', 'swap'),
        rec('swap_unplug', 'next'),
        rec('swap_card', 'next'),
        rec('swap_plug', 'next'),
        rec('swap_wait_new', 'auto', 'ok'),
        rec('swap_login', 'auto', 'linked'),
        rec('swap_ready', 'auto', 'fixed'),
      ];
      expect(concl(g.decide(snap(), h)).outcome, Outcome.needsPart);
    });

    test('a new Pi is already waiting → straight to the login, then fixed (relink)', () {
      final s = snap(session: newSession);
      expect(stepOf(g.decide(s, [])), 'swap_login');
      final h = [rec('swap_login', 'auto', 'linked')];
      expect(stepOf(g.decide(snap(), h)), 'swap_ready');
      final c = concl(g.decide(snap(), [...h, rec('swap_ready', 'auto', 'fixed')]));
      expect(c.outcome, Outcome.fixed);
      expect(c.fixedBy, 'relink');
    });

    test('from "unlinked": wait for the Pi to wipe itself, then login', () {
      final rejected = snap(diag: diagOf(mainState: 'rejected'));
      expect(stepOf(g.decide(rejected, [rec('unlinked', 'next')])), 'relink_wait');
      expect(
        stepOf(g.decide(snap(session: newSession), [rec('unlinked', 'next'), rec('relink_wait', 'auto', 'ok')])),
        'swap_login',
      );
    });

    test('wait steps are satisfied by a new Pi on the network', () {
      final st = SwapSteps.waitNew;
      expect(g.satisfied(st, snap(), const {}), isFalse);
      expect(
        g.satisfied(
          st,
          snap(piDown: true, discovered: const [DiscoveredPi(address: 'http://10.0.0.9:8080')]),
          const {},
        ),
        isTrue,
      );
    });
  });

  test('every guide step has a title, a body, and resolves by id', () {
    for (final id in GuideId.values) {
      final g = Guide.of(id);
      expect(g.scenario, isNotEmpty);
      final d = g.decide(snap(piDown: true, internet: false), const []);
      if (d is NextStep) {
        expect(d.step.title, isNotEmpty);
        expect(d.step.body, isNotEmpty);
        expect(g.step(d.step.id)?.id, d.step.id);
      }
    }
  });

  test('outcome wire names match report v1', () {
    expect(Outcome.values.map((o) => o.wire), [
      'ok',
      'fixed',
      'needs_part',
      'needs_owner',
      'not_fixed',
      'info',
      'abandoned',
    ]);
  });
}
