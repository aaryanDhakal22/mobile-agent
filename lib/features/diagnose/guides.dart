import '../../core/device_platform.dart';
import '../../core/diag_models.dart';
import '../../core/friendly_error.dart';
import '../../core/time.dart';
import '../common/info_button.dart';
import '../illustrations/illustration.dart';
import 'checks.dart';
import 'texts.dart';

// The four troubleshooting guides as pure decision functions:
// `Guide.decide(snapshot, history, params)` looks at what the checks see now
// and what was already tried, and returns the next step, a switch to another
// guide, or a conclusion. Each guide is a ladder of actions, cheapest first;
// an action is offered once, and only while the evidence doesn't rule it out
// (a Pi that refuses connections has power, so "is the red light on?" is
// skipped). When the guide's problem is gone after an action, the last action
// gets the credit.

enum StepKind {
  /// The app does something by itself (switch address, test print).
  auto,

  /// Staff do something, then DONE — TEST AGAIN (re-checks for [GuideStep.timeout]).
  action,

  /// The app re-checks every [GuideStep.poll] until [GuideStep.timeout].
  wait,

  /// YES / NO about something the tablet can't sense.
  question,

  /// Read, then NEXT.
  info,

  /// One of [GuideStep.options].
  choice,

  /// Manager login for a new Pi.
  login,

  /// Shows this tablet's 6-digit pairing code.
  pairCode,

  /// Pick a printer (options = the printers).
  pickPrinter,
}

/// What an [StepKind.auto] step does.
enum StepEffect { useNewAddress, testPrint }

enum Outcome {
  ok('ok'),
  fixed('fixed'),
  needsPart('needs_part'),
  needsOwner('needs_owner'),
  notFixed('not_fixed'),
  info('info'),
  abandoned('abandoned');

  final String wire;
  const Outcome(this.wire);

  static Outcome byWire(String s) => Outcome.values.firstWhere((o) => o.wire == s, orElse: () => Outcome.info);

  /// Good news (green card).
  bool get good => this == ok || this == fixed || this == info;
}

class StepOption {
  final String id;
  final String label;
  const StepOption(this.id, this.label);
}

class GuideStep {
  final String id;
  final StepKind kind;
  final Illustration art;
  final IllustrationPart highlight;
  final bool blink;
  final String title;
  final String body;

  /// How often a wait / settling action re-checks, and for how long.
  final Duration poll;
  final Duration timeout;

  /// Credited when the problem is gone right after this step: why it was
  /// broken (report `cause`) and what that means in words.
  final String? cause;
  final String? fixedText;
  final StepEffect? effect;

  /// An extra button that opens an Android settings page.
  final DeviceSetting? opens;
  final List<StepOption> options;
  final InfoText? info;

  const GuideStep({
    required this.id,
    required this.kind,
    required this.art,
    required this.title,
    required this.body,
    this.highlight = IllustrationPart.none,
    this.blink = false,
    this.poll = const Duration(seconds: 10),
    this.timeout = Duration.zero,
    this.cause,
    this.fixedText,
    this.effect,
    this.opens,
    this.options = const [],
    this.info,
  });

  GuideStep.copy(
    StepCopy copy, {
    required this.id,
    required this.kind,
    required this.art,
    this.highlight = IllustrationPart.none,
    this.blink = false,
    this.poll = const Duration(seconds: 10),
    this.timeout = Duration.zero,
    this.cause,
    this.fixedText,
    this.effect,
    this.opens,
    this.options = const [],
    this.info,
  }) : title = copy.title,
       body = copy.body;

  /// After DONE the app keeps re-checking for a while (a restart takes time).
  bool get settles => kind == StepKind.action && timeout > Duration.zero;

  /// Can fix the problem by itself (gets the credit).
  bool get creditable => cause != null && (kind == StepKind.action || kind == StepKind.auto || kind == StepKind.wait);
}

/// One answered step. [answer]: yes | no | next | test_again | auto | timeout
/// | an option id. [result]: still_down | fixed | ok | failed | linked.
class StepRecord {
  final String id;
  final DateTime at;
  final String answer;
  final String result;
  const StepRecord(this.id, this.answer, {this.result = '', required this.at});

  Map<String, Object?> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'answer': answer,
    if (result.isNotEmpty) 'result': result,
  };

  factory StepRecord.fromJson(Map<String, dynamic> m) => StepRecord(
    '${m['id'] ?? ''}',
    '${m['answer'] ?? ''}',
    result: '${m['result'] ?? ''}',
    at: DateTime.tryParse('${m['at']}') ?? timeNow(),
  );
}

class Conclusion {
  final Outcome outcome;
  final String headline;

  /// What staff should do meanwhile (amber cards).
  final String meanwhile;
  final String? cause;
  final String? fixedBy;
  final String? note;

  /// False for conclusions that aren't a problem (showing a pairing code).
  final bool report;

  const Conclusion(
    this.outcome,
    this.headline, {
    this.meanwhile = '',
    this.cause,
    this.fixedBy,
    this.note,
    this.report = true,
  });

  Map<String, Object?> toJson() => {
    'outcome': outcome.wire,
    'headline': headline,
    'meanwhile': meanwhile,
    'cause': cause,
    'fixed_by': fixedBy,
    'note': note,
    'report': report,
  };

  factory Conclusion.fromJson(Map<String, dynamic> m) => Conclusion(
    Outcome.byWire('${m['outcome']}'),
    '${m['headline'] ?? ''}',
    meanwhile: '${m['meanwhile'] ?? ''}',
    cause: m['cause'] as String?,
    fixedBy: m['fixed_by'] as String?,
    note: m['note'] as String?,
    report: m['report'] != false,
  );
}

sealed class Decision {
  const Decision();
}

class NextStep extends Decision {
  final GuideStep step;
  const NextStep(this.step);
}

class Conclude extends Decision {
  final Conclusion conclusion;
  const Conclude(this.conclusion);
}

class SwitchGuide extends Decision {
  final GuideId to;
  const SwitchGuide(this.to);
}

/// Params a guide keeps in its session.
abstract final class GuideParams {
  /// The printer the printer guide is about.
  static const printer = 'printer';

  /// The new Pi's address (swap / relink).
  static const newPi = 'new_pi';
}

// =============================================================================
// Shared helpers
// =============================================================================

extension on List<StepRecord> {
  bool tried(String id) => any((r) => r.id == id);
  StepRecord? lastOf(String id) {
    for (var i = length - 1; i >= 0; i--) {
      if (this[i].id == id) return this[i];
    }
    return null;
  }

  String? answer(String id) => lastOf(id)?.answer;
}

abstract class Guide {
  const Guide();

  GuideId get id;

  /// The report's `scenario`.
  String get scenario;

  /// The printer guide re-dials the printers on every check.
  bool get probesPrinters => false;

  Decision decide(CheckSnapshot s, List<StepRecord> history, [Map<String, String> params = const {}]);

  /// Is the step [step] (a wait, or a settling action) done waiting?
  /// Default: the guide's problem is gone.
  bool satisfied(GuideStep step, CheckSnapshot s, Map<String, String> params) => resolved(s, params);

  /// The guide's problem is gone.
  bool resolved(CheckSnapshot s, Map<String, String> params);

  /// Every step this guide can show (for crediting and resuming).
  GuideStep? step(String id, [Map<String, String> params = const {}]);

  /// Params to remember now (e.g. which printer).
  Map<String, String> pin(CheckSnapshot s, Map<String, String> params) => const {};

  static Guide of(GuideId id) => switch (id) {
    GuideId.piUnreachable => const PiUnreachableGuide(),
    GuideId.printer => const PrinterGuide(),
    GuideId.noOrders => const NoOrdersGuide(),
    GuideId.piSwap => const PiSwapGuide(),
  };

  /// Walks [ladder] (already filtered by the evidence) for the first step not
  /// tried yet.
  GuideStep? firstUntried(List<GuideStep> ladder, List<StepRecord> history) {
    for (final st in ladder) {
      if (!history.tried(st.id)) return st;
    }
    return null;
  }

  /// "Fixed: …" crediting the last action that can fix things, or null when
  /// nothing was done (the problem went away by itself / wasn't there).
  Conclusion? fixedConclusion(List<StepRecord> history, Map<String, String> params) {
    for (var i = history.length - 1; i >= 0; i--) {
      final st = step(history[i].id, params);
      if (st != null && st.creditable) {
        final words = st.fixedText ?? st.title;
        return Conclusion(
          Outcome.fixed,
          _clip('${ConclusionText.fixedPrefix}$words'),
          cause: st.cause,
          fixedBy: st.id,
          note: st.id == 'use_new_address' ? ConclusionText.ipChangedNote : null,
        );
      }
    }
    return null;
  }
}

String _clip(String s) => s.length <= 120 ? s : '${s.substring(0, 119)}…';

// =============================================================================
// Swap steps: shared by (a) and (d)
// =============================================================================

abstract final class SwapSteps {
  static final unplug = GuideStep.copy(
    StepText.swapUnplug,
    id: 'swap_unplug',
    kind: StepKind.info,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.powerPort,
    info: GuideText.sdCard,
  );
  static final card = GuideStep.copy(
    StepText.swapCard,
    id: 'swap_card',
    kind: StepKind.info,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.sdSlot,
    blink: true,
    info: GuideText.sdCard,
  );
  static final plug = GuideStep.copy(
    StepText.swapPlug,
    id: 'swap_plug',
    kind: StepKind.info,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.powerLight,
    blink: true,
  );
  static final waitNew = GuideStep.copy(
    StepText.swapWaitNew,
    id: 'swap_wait_new',
    kind: StepKind.wait,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.activityLight,
    blink: true,
    poll: const Duration(seconds: 15),
    timeout: const Duration(minutes: 15),
  );
  static final login = GuideStep.copy(
    StepText.swapLogin,
    id: 'swap_login',
    kind: StepKind.login,
    art: Illustration.tablet,
  );
  static final ready = GuideStep.copy(
    StepText.swapReady,
    id: 'swap_ready',
    kind: StepKind.wait,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.networkPort,
    poll: const Duration(seconds: 10),
    timeout: const Duration(minutes: 3),
  );
  static final back = GuideStep.copy(
    StepText.swapBack,
    id: 'swap_back',
    kind: StepKind.info,
    art: Illustration.sdCard,
    highlight: IllustrationPart.card,
  );

  static final all = [unplug, card, plug, waitNew, login, ready, back];
  static GuideStep? byId(String id) => all.where((s) => s.id == id).firstOrNull;

  /// The swap began (the old card may be out).
  static bool started(List<StepRecord> h) =>
      h.tried('swap_unplug') || h.tried('sd_swap') || h.answer(PiSwapGuide.choice.id) == 'swap';

  /// The Pi is set up and ready after a link.
  static bool isReady(CheckSnapshot s) => s.piLinked && s.piMainOk && s.printers.every((p) => p.up);

  /// The swap sequence; null when it isn't running. Never offers the old
  /// card back once the new one linked (main revoked the old agent).
  static Decision? decide(CheckSnapshot s, List<StepRecord> h) {
    if (!started(h)) return null;
    for (final st in [unplug, card, plug]) {
      if (!h.tried(st.id)) return NextStep(st);
    }
    // A link (here, or in the setup wizard after the tablet was unpaired)
    // ends the search for the new card: no "put the original back" after it.
    final linked = h.lastOf('swap_login')?.result == 'linked';
    if (!linked) {
      final wait = h.lastOf('swap_wait_new');
      if (wait == null) return NextStep(waitNew);
      if (wait.answer == 'timeout') {
        if (!h.tried('swap_back')) return NextStep(back);
        return const Conclude(
          Conclusion(
            Outcome.needsOwner,
            ConclusionText.swapNeverStarted,
            meanwhile: ConclusionText.swapBackMeanwhile,
            cause: 'pi_hardware',
          ),
        );
      }
      return NextStep(login);
    }
    final r = h.lastOf('swap_ready');
    if (r == null) return NextStep(ready);
    final printersDown = s.printers.where((p) => !p.up).isNotEmpty;
    return Conclude(
      Conclusion(
        Outcome.needsPart,
        r.answer == 'timeout' && printersDown ? ConclusionText.swapWorkedPrinters : ConclusionText.swapWorked,
        cause: 'sd_card',
        fixedBy: 'sd_swap',
      ),
    );
  }
}

// =============================================================================
// (a) Can't reach the Pi
// =============================================================================

class PiUnreachableGuide extends Guide {
  const PiUnreachableGuide();

  @override
  GuideId get id => GuideId.piUnreachable;
  @override
  String get scenario => 'pi_unreachable';

  static final tabletWifi = GuideStep.copy(
    StepText.tabletWifi,
    id: 'tablet_wifi',
    kind: StepKind.action,
    art: Illustration.tablet,
    highlight: IllustrationPart.wifi,
    blink: true,
    opens: DeviceSetting.wifi,
    poll: const Duration(seconds: 5),
    timeout: const Duration(seconds: 30),
    cause: 'tablet_wifi',
    fixedText: "the tablet's Wi-Fi was off",
  );
  static final useNewAddress = GuideStep.copy(
    StepText.useNewAddress,
    id: 'use_new_address',
    kind: StepKind.auto,
    art: Illustration.router,
    highlight: IllustrationPart.lights,
    effect: StepEffect.useNewAddress,
    cause: 'ip_changed',
    fixedText: 'the Pi had moved to a new address',
    info: GuideText.dhcp,
  );
  static final guestWifi = GuideStep.copy(
    StepText.guestWifi,
    id: 'guest_wifi',
    kind: StepKind.question,
    art: Illustration.tablet,
    highlight: IllustrationPart.wifi,
  );
  static final guestWifiFix = GuideStep.copy(
    StepText.guestWifiFix,
    id: 'guest_wifi_fix',
    kind: StepKind.action,
    art: Illustration.tablet,
    highlight: IllustrationPart.wifi,
    blink: true,
    opens: DeviceSetting.wifi,
    poll: const Duration(seconds: 5),
    timeout: const Duration(seconds: 30),
    cause: 'tablet_wrong_wifi',
    fixedText: 'the tablet was on the wrong Wi-Fi',
  );
  static final agentRestartWait = GuideStep.copy(
    StepText.agentRestartWait,
    id: 'agent_restart_wait',
    kind: StepKind.wait,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.activityLight,
    blink: true,
    poll: const Duration(seconds: 10),
    timeout: const Duration(seconds: 90),
    cause: 'agent_down',
    fixedText: 'the Quicc program on the Pi restarted',
  );
  static final piPowerLight = GuideStep.copy(
    StepText.piPowerLight,
    id: 'pi_power_light',
    kind: StepKind.question,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.powerLight,
    blink: true,
  );
  static final piPowerFix = GuideStep.copy(
    StepText.piPowerFix,
    id: 'pi_power_fix',
    kind: StepKind.action,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.powerPort,
    blink: true,
    poll: const Duration(seconds: 15),
    timeout: const Duration(minutes: 3),
    cause: 'pi_power',
    fixedText: 'the Pi had no power',
  );
  static final piCable = GuideStep.copy(
    StepText.piCable,
    id: 'pi_cable',
    kind: StepKind.action,
    art: Illustration.ethernetCable,
    highlight: IllustrationPart.plugs,
    blink: true,
    poll: const Duration(seconds: 10),
    timeout: const Duration(seconds: 40),
    cause: 'pi_cable',
    fixedText: "the Pi's network cable was loose",
  );
  static final piPowerCycle = GuideStep.copy(
    StepText.piPowerCycle,
    id: 'pi_power_cycle',
    kind: StepKind.action,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.powerPort,
    poll: const Duration(seconds: 15),
    timeout: const Duration(minutes: 3),
    cause: 'pi_frozen',
    fixedText: 'the Pi was stuck — a restart fixed it',
  );
  static final sdSwap = GuideStep.copy(
    StepText.sdSwap,
    id: 'sd_swap',
    kind: StepKind.info,
    art: Illustration.sdCard,
    highlight: IllustrationPart.card,
    info: GuideText.sdCard,
  );

  static final _all = [
    tabletWifi,
    useNewAddress,
    guestWifi,
    guestWifiFix,
    agentRestartWait,
    piPowerLight,
    piPowerFix,
    piCable,
    piPowerCycle,
    sdSwap,
  ];

  @override
  GuideStep? step(String id, [Map<String, String> params = const {}]) =>
      _all.where((s) => s.id == id).firstOrNull ?? SwapSteps.byId(id);

  @override
  bool resolved(CheckSnapshot s, Map<String, String> params) => s.piLinked;

  @override
  bool satisfied(GuideStep step, CheckSnapshot s, Map<String, String> params) => step.id == SwapSteps.waitNew.id
      ? s.newPi != null
      : step.id == SwapSteps.ready.id
      ? SwapSteps.isReady(s)
      : resolved(s, params);

  @override
  Decision decide(CheckSnapshot s, List<StepRecord> h, [Map<String, String> params = const {}]) {
    final swap = SwapSteps.decide(s, h);
    if (swap != null) return swap;

    if (resolved(s, params)) {
      return Conclude(fixedConclusion(h, params) ?? const Conclusion(Outcome.info, ConclusionText.piReachableNow));
    }
    // A Pi answers at our address but isn't set up (wiped, or a fresh card):
    // it needs the manager login.
    if (s.piAnswers && !s.piLinked) return const SwitchGuide(GuideId.piSwap);

    final refused = s.piPort == PortState.refused;
    final ladder = <GuideStep>[
      if (s.tabletOnNetwork == false) tabletWifi,
      if (s.piElsewhere != null) useNewAddress,
      if (!s.anyPiFound && s.internet == true && s.tabletOnNetwork != false) guestWifi,
      if (h.answer(guestWifi.id) == 'no') guestWifiFix,
      if (refused) agentRestartWait,
      // A Pi that refuses connections is on and cabled.
      if (!refused) piPowerLight,
      if (h.answer(piPowerLight.id) == 'no') piPowerFix,
      // The last health showed SD trouble: the card goes right after power.
      if (s.sdSuspect) sdSwap,
      if (!refused) piCable,
      piPowerCycle,
      if (!s.sdSuspect) sdSwap,
    ];
    final next = firstUntried(ladder, h);
    if (next == null) {
      return Conclude(
        Conclusion(
          Outcome.needsOwner,
          ConclusionText.piStillDown,
          meanwhile: ConclusionText.piStillDownMeanwhile,
          cause: s.powerSuspect ? 'pi_power' : (refused ? 'agent_down' : 'pi_down'),
        ),
      );
    }
    // After sd_swap (NEXT) SwapSteps.decide takes over.
    return NextStep(next);
  }
}

// =============================================================================
// (b) Printer problem
// =============================================================================

class PrinterGuide extends Guide {
  const PrinterGuide();

  @override
  GuideId get id => GuideId.printer;
  @override
  String get scenario => 'printer';
  @override
  bool get probesPrinters => true;

  static DiagPrinter? target(CheckSnapshot s, Map<String, String> params) {
    final id = params[GuideParams.printer];
    final ps = s.printers.isNotEmpty ? s.printers : (s.lastDiag?.printers ?? const <DiagPrinter>[]);
    if (id != null) {
      return ps.where((p) => p.id == id).firstOrNull ?? DiagPrinter(id: id, name: params['printer_name'] ?? '');
    }
    final down = ps.where((p) => !p.up).toList();
    if (down.isNotEmpty) return down.first;
    if (ps.length == 1) return ps.first;
    return null;
  }

  @override
  Map<String, String> pin(CheckSnapshot s, Map<String, String> params) {
    if (params.containsKey(GuideParams.printer)) return const {};
    final t = target(s, params);
    return t == null ? const {} : {GuideParams.printer: t.id, 'printer_name': t.name, 'printer_ip': t.ip};
  }

  String _name(Map<String, String> params) => params['printer_name'] ?? '';

  static const _probe5s = Duration(seconds: 5);

  List<GuideStep> _steps(Map<String, String> p) {
    final n = _name(p);
    return [
      GuideStep.copy(
        StepText.pickPrinter,
        id: 'pick_printer',
        kind: StepKind.pickPrinter,
        art: Illustration.receiptPrinter,
      ),
      GuideStep.copy(
        StepText.switchCheck,
        id: 'switch_check',
        kind: StepKind.action,
        art: Illustration.router,
        highlight: IllustrationPart.lights,
        blink: true,
        poll: _probe5s,
        timeout: const Duration(seconds: 45),
        cause: 'network_switch',
        fixedText: 'the network switch was off or unplugged',
      ),
      GuideStep.copy(
        StepText.printerPowerLight(n),
        id: 'printer_power_light',
        kind: StepKind.question,
        art: Illustration.receiptPrinter,
        highlight: IllustrationPart.powerLight,
        blink: true,
      ),
      GuideStep.copy(
        StepText.printerPowerFix(n),
        id: 'printer_power_fix',
        kind: StepKind.action,
        art: Illustration.receiptPrinter,
        highlight: IllustrationPart.powerPort,
        blink: true,
        poll: _probe5s,
        timeout: const Duration(seconds: 60),
        cause: 'printer_power',
        fixedText: 'the printer was off',
      ),
      GuideStep.copy(
        StepText.printerPaper(n),
        id: 'printer_paper',
        kind: StepKind.question,
        art: Illustration.receiptPrinter,
        highlight: IllustrationPart.lid,
      ),
      GuideStep.copy(
        StepText.printerPaperFix(n),
        id: 'printer_paper_fix',
        kind: StepKind.action,
        art: Illustration.receiptPrinter,
        highlight: IllustrationPart.paper,
        poll: _probe5s,
        timeout: const Duration(seconds: 30),
        cause: 'printer_paper',
        fixedText: 'the printer had no paper or its lid was open',
      ),
      GuideStep.copy(
        StepText.printerCable(n),
        id: 'printer_cable',
        kind: StepKind.action,
        art: Illustration.ethernetCable,
        highlight: IllustrationPart.plugs,
        blink: true,
        poll: _probe5s,
        timeout: const Duration(seconds: 30),
        cause: 'printer_cable',
        fixedText: "the printer's network cable was loose",
      ),
      GuideStep.copy(
        StepText.printerPowerCycle(n),
        id: 'printer_power_cycle',
        kind: StepKind.action,
        art: Illustration.receiptPrinter,
        highlight: IllustrationPart.powerLight,
        poll: _probe5s,
        timeout: const Duration(seconds: 60),
        cause: 'printer_frozen',
        fixedText: 'the printer was stuck — a restart fixed it',
      ),
      GuideStep.copy(
        StepText.testPrint(n),
        id: 'test_print',
        kind: StepKind.auto,
        art: Illustration.receiptPrinter,
        effect: StepEffect.testPrint,
      ),
      GuideStep.copy(
        StepText.slipCameOut(n),
        id: 'slip_came_out',
        kind: StepKind.question,
        art: Illustration.receiptPrinter,
        highlight: IllustrationPart.lid,
        info: GuideText.reprint,
      ),
      GuideStep.copy(
        StepText.paperOrientation(n),
        id: 'paper_orientation',
        kind: StepKind.action,
        art: Illustration.receiptPrinter,
        highlight: IllustrationPart.paper,
        blink: true,
        cause: 'printer_paper_backwards',
        fixedText: 'the paper roll was in backwards',
      ),
      GuideStep.copy(
        StepText.testPrint(n),
        id: 'test_print_2',
        kind: StepKind.auto,
        art: Illustration.receiptPrinter,
        effect: StepEffect.testPrint,
      ),
      GuideStep.copy(
        StepText.slipCameOut(n),
        id: 'slip_after_paper',
        kind: StepKind.question,
        art: Illustration.receiptPrinter,
        highlight: IllustrationPart.lid,
      ),
    ];
  }

  @override
  GuideStep? step(String id, [Map<String, String> params = const {}]) =>
      _steps(params).where((s) => s.id == id).firstOrNull;

  @override
  bool resolved(CheckSnapshot s, Map<String, String> params) {
    final t = target(s, params);
    return t != null && s.printerUp(t.id) == true;
  }

  @override
  Decision decide(CheckSnapshot s, List<StepRecord> h, [Map<String, String> params = const {}]) {
    if (!s.piAnswers) return const SwitchGuide(GuideId.piUnreachable);
    final st = {for (final x in _steps(params)) x.id: x};
    // A 2.0.0 Pi can't tell us about its printers.
    if (s.diag == null && s.printerProbe == null) {
      return const Conclude(Conclusion(Outcome.needsOwner, ConclusionText.piTooOld, cause: 'pi_outdated'));
    }
    final t = target(s, params);
    if (t == null) {
      if (s.printers.isEmpty) {
        return const Conclude(Conclusion(Outcome.needsOwner, ConclusionText.noPrinters, cause: 'no_printers'));
      }
      return NextStep(st['pick_printer']!);
    }
    final up = s.printerUp(t.id) == true;
    final name = t.name.isEmpty ? _name(params) : t.name;

    // The printer answers.
    if (up) {
      // …after something staff did: that fixed it.
      final fixed = fixedConclusion(h, params);
      if (fixed != null && fixed.fixedBy != 'paper_orientation') return Conclude(fixed);
      // It answered all along (or since a test): does paper actually come out?
      if (!h.tried('test_print')) return NextStep(st['test_print']!);
      if (!h.tried('slip_came_out')) return NextStep(st['slip_came_out']!);
      if (h.answer('slip_came_out') == 'yes') {
        return const Conclude(Conclusion(Outcome.info, ConclusionText.printerWorks, report: false));
      }
      if (!h.tried('paper_orientation')) return NextStep(st['paper_orientation']!);
      if (!h.tried('test_print_2')) return NextStep(st['test_print_2']!);
      if (!h.tried('slip_after_paper')) return NextStep(st['slip_after_paper']!);
      if (h.answer('slip_after_paper') == 'yes') {
        return Conclude(
          Conclusion(
            Outcome.fixed,
            _clip('${ConclusionText.fixedPrefix}${st['paper_orientation']!.fixedText}'),
            cause: 'printer_paper_backwards',
            fixedBy: 'paper_orientation',
          ),
        );
      }
      return Conclude(
        Conclusion(
          Outcome.needsOwner,
          _clip(ConclusionText.printerNoPrint(name)),
          meanwhile: ConclusionText.printerMeanwhile,
          cause: 'printer_broken',
        ),
      );
    }

    // The printer doesn't answer.
    final ps = s.printers;
    final allDown = ps.length >= 2 && ps.every((p) => !p.up);
    final ladder = <GuideStep>[
      if (allDown) st['switch_check']!,
      st['printer_power_light']!,
      if (h.answer('printer_power_light') == 'no') st['printer_power_fix']!,
      st['printer_paper']!,
      if (h.answer('printer_paper') == 'no') st['printer_paper_fix']!,
      st['printer_cable']!,
      st['printer_power_cycle']!,
    ];
    final next = firstUntried(ladder, h);
    if (next != null) return NextStep(next);
    return Conclude(
      Conclusion(
        Outcome.needsOwner,
        _clip(ConclusionText.printerDead(name, t.ip.isNotEmpty ? t.ip : (params['printer_ip'] ?? ''))),
        meanwhile: ConclusionText.printerMeanwhile,
        cause: 'printer_unreachable',
      ),
    );
  }
}

// =============================================================================
// (c) No orders coming in
// =============================================================================

class NoOrdersGuide extends Guide {
  const NoOrdersGuide();

  @override
  GuideId get id => GuideId.noOrders;
  @override
  String get scenario => 'no_orders';

  static final unlinked = GuideStep.copy(
    StepText.unlinked,
    id: 'unlinked',
    kind: StepKind.info,
    art: Illustration.raspberryPi,
  );
  static final routerLights = GuideStep.copy(
    StepText.routerLights,
    id: 'router_lights',
    kind: StepKind.question,
    art: Illustration.router,
    highlight: IllustrationPart.lights,
    blink: true,
  );
  static final routerRestart = GuideStep.copy(
    StepText.routerRestart,
    id: 'router_restart',
    kind: StepKind.action,
    art: Illustration.router,
    highlight: IllustrationPart.powerPort,
    blink: true,
    poll: const Duration(seconds: 15),
    timeout: const Duration(minutes: 4),
    cause: 'store_internet',
    fixedText: 'the internet router was stuck — a restart fixed it',
  );
  static final piCable = GuideStep.copy(
    StepText.piCable,
    id: 'pi_cable',
    kind: StepKind.action,
    art: Illustration.ethernetCable,
    highlight: IllustrationPart.plugs,
    blink: true,
    poll: const Duration(seconds: 10),
    timeout: const Duration(seconds: 60),
    cause: 'pi_cable',
    fixedText: "the Pi's network cable was loose",
  );
  static final piPowerCycle = GuideStep.copy(
    StepText.piPowerCycle,
    id: 'pi_power_cycle',
    kind: StepKind.action,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.powerPort,
    poll: const Duration(seconds: 15),
    timeout: const Duration(minutes: 3),
    cause: 'pi_network',
    fixedText: 'the Pi was stuck — a restart fixed it',
  );

  static final _all = [unlinked, routerLights, routerRestart, piCable, piPowerCycle];

  @override
  GuideStep? step(String id, [Map<String, String> params = const {}]) => _all.where((s) => s.id == id).firstOrNull;

  @override
  bool resolved(CheckSnapshot s, Map<String, String> params) => s.piLinked && s.piMainOk;

  @override
  Decision decide(CheckSnapshot s, List<StepRecord> h, [Map<String, String> params = const {}]) {
    if (!s.piAnswers) return const SwitchGuide(GuideId.piUnreachable);
    if (s.piToMain == 'rejected' || s.session?.state == 'unconfigured') {
      if (!h.tried(unlinked.id)) return NextStep(unlinked);
      return const SwitchGuide(GuideId.piSwap);
    }
    if (resolved(s, params)) {
      return Conclude(
        fixedConclusion(h, params) ??
            const Conclusion(Outcome.info, ConclusionText.allOk, meanwhile: ConclusionText.allOkMeanwhile),
      );
    }
    // The Pi's link to the server is down (or unknown and not connected).
    if (s.internet == false) {
      final next = firstUntried([routerLights, routerRestart], h);
      if (next != null) return NextStep(next);
      return const Conclude(
        Conclusion(
          Outcome.needsOwner,
          ConclusionText.storeInternet,
          meanwhile: ConclusionText.storeInternetMeanwhile,
          cause: 'store_internet',
        ),
      );
    }
    // The tablet has internet. If the server doesn't answer the tablet either
    // (and the Pi can't reach it), the problem is the server.
    if (s.mainFromTablet == false && s.piReachesMain == false) {
      return const Conclude(
        Conclusion(
          Outcome.needsOwner,
          ConclusionText.serverDown,
          meanwhile: ConclusionText.serverDownMeanwhile,
          cause: 'main_down',
        ),
      );
    }
    final next = firstUntried([piCable, piPowerCycle], h);
    if (next != null) return NextStep(next);
    return const Conclude(
      Conclusion(
        Outcome.needsOwner,
        ConclusionText.piNoInternet,
        meanwhile: ConclusionText.piNoInternetMeanwhile,
        cause: 'pi_network',
      ),
    );
  }
}

// =============================================================================
// (d) Pi swap / re-pair
// =============================================================================

class PiSwapGuide extends Guide {
  const PiSwapGuide();

  @override
  GuideId get id => GuideId.piSwap;
  @override
  String get scenario => 'pi_swap';

  static final choice = GuideStep.copy(
    StepText.dChoice,
    id: 'd_choice',
    kind: StepKind.choice,
    art: Illustration.raspberryPi,
    options: const [StepOption('swap', StepText.dChoiceSwap), StepOption('pair', StepText.dChoicePair)],
    info: GuideText.sdCard,
  );
  static final pairCode = GuideStep.copy(
    StepText.pairCode,
    id: 'pair_code',
    kind: StepKind.pairCode,
    art: Illustration.tablet,
  );
  static final relinkWait = GuideStep.copy(
    StepText.relinkWait,
    id: 'relink_wait',
    kind: StepKind.wait,
    art: Illustration.raspberryPi,
    highlight: IllustrationPart.activityLight,
    blink: true,
    poll: const Duration(seconds: 10),
    timeout: const Duration(minutes: 3),
  );

  @override
  GuideStep? step(String id, [Map<String, String> params = const {}]) =>
      [choice, pairCode, relinkWait].where((s) => s.id == id).firstOrNull ?? SwapSteps.byId(id);

  @override
  bool resolved(CheckSnapshot s, Map<String, String> params) => SwapSteps.isReady(s);

  @override
  bool satisfied(GuideStep step, CheckSnapshot s, Map<String, String> params) =>
      step.id == SwapSteps.waitNew.id || step.id == relinkWait.id ? s.newPi != null : SwapSteps.isReady(s);

  @override
  Decision decide(CheckSnapshot s, List<StepRecord> h, [Map<String, String> params = const {}]) {
    // "Pair another tablet".
    if (h.answer(choice.id) == 'pair') {
      if (!h.tried(pairCode.id)) return NextStep(pairCode);
      return const Conclude(Conclusion(Outcome.info, ConclusionText.paired, report: false));
    }
    // Swapping the card (from here or from the Pi guide).
    final swap = SwapSteps.decide(s, h);
    if (swap != null) return swap;

    // Re-linking a Pi that was unlinked / wiped (no card swap).
    final relinking = h.tried(relinkWait.id) || h.tried(SwapSteps.login.id);
    final needsLink = s.newPi != null || s.piToMain == 'rejected' || h.tried(NoOrdersGuide.unlinked.id);
    if (relinking || (!h.tried(choice.id) && needsLink)) {
      if (!h.tried(SwapSteps.login.id) || h.lastOf(SwapSteps.login.id)!.result != 'linked') {
        if (s.newPi == null && params[GuideParams.newPi] == null && !h.tried(relinkWait.id)) {
          return NextStep(relinkWait);
        }
        final w = h.lastOf(relinkWait.id);
        if (w != null && w.answer == 'timeout' && s.newPi == null && params[GuideParams.newPi] == null) {
          return const Conclude(Conclusion(Outcome.needsOwner, ConclusionText.piStillDown, cause: 'unlinked'));
        }
        return NextStep(SwapSteps.login);
      }
      if (!h.tried(SwapSteps.ready.id)) return NextStep(SwapSteps.ready);
      return const Conclude(Conclusion(Outcome.fixed, ConclusionText.relinked, cause: 'unlinked', fixedBy: 'relink'));
    }
    return NextStep(choice);
  }
}
