import '../../core/json.dart';
import '../../core/models.dart';
import '../../core/time.dart';

/// The setup wizard's steps, in order. Everything up to [signIn] happens
/// before the tablet is paired; everything after needs the pairing.
enum SetupStep { welcome, findPi, signIn, tabletChecks, piReady, testRing, testPrint, drivers, times, chime, done }

extension SetupStepX on SetupStep {
  bool get beforePairing => index <= SetupStep.signIn.index;

  /// Shown in the progress bar ("Step 3 of 8"); welcome and done don't count.
  String get label => switch (this) {
    SetupStep.welcome => 'Welcome',
    SetupStep.findPi => 'Find the Pi',
    SetupStep.signIn => 'Sign in',
    SetupStep.tabletChecks => 'Tablet checks',
    SetupStep.piReady => 'Pi ready',
    SetupStep.testRing => 'Test ring',
    SetupStep.testPrint => 'Test print',
    SetupStep.drivers => 'Drivers',
    SetupStep.times => 'Default times',
    SetupStep.chime => 'Order chime',
    SetupStep.done => 'Done',
  };
}

/// What the link restored on a new Pi (shown on the "Pi ready" step).
class LinkSummary {
  final String store;
  final int orders;
  final int waiting;
  final int drivers;
  final int? kitchenNext;
  const LinkSummary({this.store = '', this.orders = 0, this.waiting = 0, this.drivers = 0, this.kitchenNext});

  factory LinkSummary.fromLink(LinkResult r, {String store = ''}) => LinkSummary(
    store: r.tenant.isNotEmpty ? r.tenant : store,
    orders: r.restoredOrders,
    waiting: r.waiting,
    drivers: r.drivers,
    kitchenNext: r.kitchenNext,
  );

  Map<String, Object?> toJson() => {
    'store': store,
    'orders': orders,
    'waiting': waiting,
    'drivers': drivers,
    'kitchen_next': kitchenNext,
  };

  factory LinkSummary.fromJson(Map<String, dynamic> j) => LinkSummary(
    store: jStr(j['store']),
    orders: jInt(j['orders']),
    waiting: jInt(j['waiting']),
    drivers: jInt(j['drivers']),
    kitchenNext: jIntOrNull(j['kitchen_next']),
  );
}

/// Where the wizard is, saved on every change so a closed app resumes there.
/// Never holds the manager password.
class SetupProgress {
  final SetupStep step;
  final String piAddress;
  final String piStore;
  final bool piIsNew;
  final LinkSummary? link;

  /// Test results: null = not tried.
  final bool? ringOk;
  final Map<String, bool> printOk;

  /// Tablet checks all passed when last looked at.
  final bool? checksOk;

  /// Left with "Finish later" — the app runs normally and Settings offers
  /// CONTINUE.
  final bool finishedLater;

  /// START TAKING ORDERS was tapped on the last screen.
  final bool finished;
  final DateTime startedAt;

  const SetupProgress({
    required this.step,
    this.piAddress = '',
    this.piStore = '',
    this.piIsNew = false,
    this.link,
    this.ringOk,
    this.printOk = const {},
    this.checksOk,
    this.finishedLater = false,
    this.finished = false,
    required this.startedAt,
  });

  factory SetupProgress.start({SetupStep step = SetupStep.welcome, String address = '', DateTime? now}) =>
      SetupProgress(step: step, piAddress: address, startedAt: now ?? timeNow());

  /// Set up: the last screen was confirmed.
  bool get isDone => finished;

  /// The wizard is on screen (not finished, not put off).
  bool get active => !finished && !finishedLater;

  SetupProgress copyWith({
    SetupStep? step,
    String? piAddress,
    String? piStore,
    bool? piIsNew,
    LinkSummary? link,
    bool clearLink = false,
    bool? ringOk,
    Map<String, bool>? printOk,
    bool? checksOk,
    bool? finishedLater,
    bool? finished,
  }) => SetupProgress(
    step: step ?? this.step,
    piAddress: piAddress ?? this.piAddress,
    piStore: piStore ?? this.piStore,
    piIsNew: piIsNew ?? this.piIsNew,
    link: clearLink ? null : (link ?? this.link),
    ringOk: ringOk ?? this.ringOk,
    printOk: printOk ?? this.printOk,
    checksOk: checksOk ?? this.checksOk,
    finishedLater: finishedLater ?? this.finishedLater,
    finished: finished ?? this.finished,
    startedAt: startedAt,
  );

  Map<String, Object?> toJson() => {
    'step': step.name,
    'pi_address': piAddress,
    'pi_store': piStore,
    'pi_is_new': piIsNew,
    'link': link?.toJson(),
    'ring_ok': ringOk,
    'print_ok': printOk,
    'checks_ok': checksOk,
    'finished_later': finishedLater,
    'finished': finished,
    'started_at': startedAt.toUtc().toIso8601String(),
  };

  static SetupProgress? fromJson(Map<String, dynamic> j) {
    final step = SetupStep.values.where((s) => s.name == j['step']).firstOrNull;
    if (step == null) return null;
    final printOk = <String, bool>{};
    if (j['print_ok'] is Map) {
      (j['print_ok'] as Map).forEach((k, v) {
        if (v is bool) printOk['$k'] = v;
      });
    }
    return SetupProgress(
      step: step,
      piAddress: jStr(j['pi_address']),
      piStore: jStr(j['pi_store']),
      piIsNew: j['pi_is_new'] == true,
      link: j['link'] is Map ? LinkSummary.fromJson(jMap(j['link'])) : null,
      ringOk: j['ring_ok'] is bool ? j['ring_ok'] as bool : null,
      printOk: printOk,
      checksOk: j['checks_ok'] is bool ? j['checks_ok'] as bool : null,
      finishedLater: j['finished_later'] == true,
      // Older records: reaching the last step counted as finished.
      finished: j['finished'] == true || (j['finished'] == null && step == SetupStep.done),
      startedAt: jDate(j['started_at']) ?? timeNow(),
    );
  }
}

/// The wizard's rules, kept pure for tests.
class SetupFlow {
  const SetupFlow._();

  static SetupProgress next(SetupProgress p) {
    if (p.step == SetupStep.done) return p;
    return p.copyWith(step: SetupStep.values[p.step.index + 1]);
  }

  /// Back never crosses sign-in once the tablet is paired (the pairing is
  /// done; going "back" to it would mean unpairing).
  static bool canGoBack(SetupProgress p) {
    if (p.step == SetupStep.welcome || p.step == SetupStep.done) return false;
    if (p.step == SetupStep.tabletChecks) return false;
    return true;
  }

  static SetupProgress back(SetupProgress p) => canGoBack(p) ? p.copyWith(step: SetupStep.values[p.step.index - 1]) : p;

  /// The tablet just paired (link or code): on to the checks.
  static SetupProgress paired(SetupProgress p, {LinkSummary? link, String store = ''}) => p.copyWith(
    step: SetupStep.tabletChecks,
    link: link,
    clearLink: link == null,
    piStore: link?.store.isNotEmpty == true ? link!.store : (store.isNotEmpty ? store : p.piStore),
  );

  /// Where to pick up after the app was closed (or the pairing went away):
  /// * nothing stored → paired tablets count as set up (upgrade from 1.2.0),
  ///   unpaired ones start at the welcome screen;
  /// * stopped before pairing → back to "Find the Pi" (never to the password
  ///   form — it's not stored), keeping the address;
  /// * past sign-in but no longer paired (revoked, unpaired) → "Find the Pi";
  /// * otherwise the same step.
  static SetupProgress? resume(SetupProgress? stored, {required bool paired, DateTime? now}) {
    if (stored == null) return paired ? null : SetupProgress.start(now: now);
    if (!paired) {
      if (stored.step == SetupStep.welcome) return stored.copyWith(finishedLater: false);
      return SetupProgress.start(step: SetupStep.findPi, address: stored.piAddress, now: now);
    }
    if (stored.step.beforePairing) {
      // Paired some other way (e.g. a test or an older build): continue after
      // sign-in.
      return stored.copyWith(step: SetupStep.tabletChecks);
    }
    return stored;
  }

  /// "Step 3 of 8" — pairing and post-pairing steps (welcome/done excluded).
  static (int, int) position(SetupStep s) {
    final counted = SetupStep.values.length - 2;
    final i = s.index.clamp(1, counted);
    return (i, counted);
  }
}
