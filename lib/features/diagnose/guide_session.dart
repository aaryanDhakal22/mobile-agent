import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/friendly_error.dart';
import '../../core/local_log.dart';
import '../../core/providers.dart';
import '../../core/storage.dart';
import '../../core/time.dart';
import 'checks.dart';
import 'guides.dart';
import 'report.dart';
import 'texts.dart';

/// A guide in progress, saved on the tablet (`guide_session_v1`) after every
/// change so it survives the app being closed or restarted — e.g. while the
/// Pi's SD card is swapped.
class GuideSession {
  final String id;
  final GuideId guide;

  /// Guides this one was switched from ("no orders" → "can't reach the Pi").
  final List<GuideId> path;
  final DateTime startedAt;
  final List<StepRecord> history;

  /// The step on screen (null while checking, or once concluded).
  final String? stepId;

  /// When the current wait (or an action's re-checking) began.
  final DateTime? waitStartedAt;

  /// DONE was pressed on an action that takes time; re-checking until its
  /// timeout.
  final bool settling;
  final Map<String, String> params;
  final Conclusion? conclusion;

  /// How the conclusion's report went: sent | saved | null (not yet / none).
  final String? sent;

  const GuideSession({
    required this.id,
    required this.guide,
    required this.startedAt,
    this.path = const [],
    this.history = const [],
    this.stepId,
    this.waitStartedAt,
    this.settling = false,
    this.params = const {},
    this.conclusion,
    this.sent,
  });

  bool get concluded => conclusion != null;

  GuideSession copyWith({
    GuideId? guide,
    List<GuideId>? path,
    List<StepRecord>? history,
    String? Function()? stepId,
    DateTime? Function()? waitStartedAt,
    bool? settling,
    Map<String, String>? params,
    Conclusion? Function()? conclusion,
    String? Function()? sent,
  }) => GuideSession(
    id: id,
    guide: guide ?? this.guide,
    startedAt: startedAt,
    path: path ?? this.path,
    history: history ?? this.history,
    stepId: stepId == null ? this.stepId : stepId(),
    waitStartedAt: waitStartedAt == null ? this.waitStartedAt : waitStartedAt(),
    settling: settling ?? this.settling,
    params: params ?? this.params,
    conclusion: conclusion == null ? this.conclusion : conclusion(),
    sent: sent == null ? this.sent : sent(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'guide': guide.name,
    'path': [for (final g in path) g.name],
    'started_at': startedAt.toUtc().toIso8601String(),
    'history': [for (final r in history) r.toJson()],
    'step': stepId,
    'wait_started_at': waitStartedAt?.toUtc().toIso8601String(),
    'settling': settling,
    'params': params,
    'conclusion': conclusion?.toJson(),
    'sent': sent,
  };

  static GuideId? _guide(Object? s) => GuideId.values.where((g) => g.name == s).firstOrNull;

  static GuideSession? fromJson(Map<String, dynamic> m) {
    final g = _guide(m['guide']);
    if (g == null) return null;
    return GuideSession(
      id: '${m['id'] ?? uuidV4()}',
      guide: g,
      path: [for (final p in (m['path'] as List? ?? const [])) ?_guide(p)],
      startedAt: DateTime.tryParse('${m['started_at']}') ?? timeNow(),
      history: [
        for (final r in (m['history'] as List? ?? const []))
          if (r is Map) StepRecord.fromJson(Map<String, dynamic>.from(r)),
      ],
      stepId: m['step'] as String?,
      waitStartedAt: DateTime.tryParse('${m['wait_started_at']}'),
      settling: m['settling'] == true,
      params: {for (final e in (m['params'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'},
      conclusion: m['conclusion'] is Map
          ? Conclusion.fromJson(Map<String, dynamic>.from(m['conclusion'] as Map))
          : null,
      sent: m['sent'] as String?,
    );
  }
}

/// Reads the saved session (null when none, or unreadable).
GuideSession? readGuideSession(AppStorage storage) {
  try {
    final raw = storage.getJson(AppStorage.kGuideSession);
    if (raw == null) return null;
    final m = jsonDecode(raw);
    return m is Map<String, dynamic> ? GuideSession.fromJson(m) : null;
  } catch (_) {
    return null;
  }
}

/// A saved session worth resuming: unfinished and started in the last 6 hours.
GuideSession? resumableGuideSession(AppStorage storage, {DateTime? now}) {
  final s = readGuideSession(storage);
  if (s == null || s.concluded) return null;
  if ((now ?? timeNow()).difference(s.startedAt) > const Duration(hours: 6)) return null;
  return s;
}

/// What the guide screen shows.
class GuideView {
  final GuideSession? session;

  /// The latest checks (null until the first run finishes).
  final CheckSnapshot? snapshot;
  final bool checking;

  /// A failed auto step / login, in plain words.
  final FriendlyError? error;

  const GuideView({this.session, this.snapshot, this.checking = false, this.error});

  GuideStep? get step {
    final s = session;
    if (s == null || s.stepId == null) return null;
    return Guide.of(s.guide).step(s.stepId!, s.params);
  }

  GuideView copyWith({
    GuideSession? Function()? session,
    CheckSnapshot? snapshot,
    bool? checking,
    FriendlyError? Function()? error,
  }) => GuideView(
    session: session == null ? this.session : session(),
    snapshot: snapshot ?? this.snapshot,
    checking: checking ?? this.checking,
    error: error == null ? this.error : error(),
  );
}

/// Runs a guide: re-checks, records answers, asks [Guide.decide] for the next
/// step, and reports every conclusion to the owner.
class GuideController extends Notifier<GuideView> {
  bool _busy = false;
  DateTime Function() now = timeNow;

  @override
  GuideView build() => GuideView(session: readGuideSession(ref.read(storageProvider)));

  Guide get _guide => Guide.of(state.session!.guide);
  LocalLog get _log => ref.read(localLogProvider);

  /// Starts [guide] (or picks up the unfinished session of the same guide).
  Future<void> start(GuideId guide, {Map<String, String> params = const {}}) async {
    final saved = readGuideSession(ref.read(storageProvider));
    if (saved != null && !saved.concluded && saved.guide == guide && params.isEmpty) {
      return resume();
    }
    // Another guide was left unfinished: it counts as abandoned.
    if (saved != null && !saved.concluded && saved.history.isNotEmpty) {
      unawaited(_report(saved, const Conclusion(Outcome.abandoned, ConclusionText.abandoned)));
    }
    final s = GuideSession(
      id: uuidV4(),
      guide: guide,
      startedAt: now(),
      params: {...params, _kDeviceAtStart: ref.read(pairingProvider)?.deviceId ?? ''},
    );
    _log.add('guide', 'start ${Guide.of(guide).scenario}');
    await _save(s);
    state = GuideView(session: s);
    await _recheckAndDecide();
  }

  /// Back on the guide screen after a restart: check again, then carry on
  /// where it was (a wait keeps counting from when it started).
  Future<void> resume() async {
    final s = readGuideSession(ref.read(storageProvider));
    state = GuideView(session: s);
    if (s == null || s.concluded) return;
    final st = state.step;
    if (st != null && (st.kind == StepKind.wait || s.settling)) return poll();
    if (st == null || st.kind == StepKind.auto) return _recheckAndDecide();
    final snap = await _check();
    if (snap != null && await _adoptOutsideLink()) await _decide(snap);
  }

  // --- answers -------------------------------------------------------------------

  /// YES / NO / NEXT / a choice: recorded, then the next step (from the
  /// latest checks — nothing physical changed).
  Future<void> answer(String answer) async {
    final s = state.session, st = state.step;
    if (s == null || st == null || _busy) return;
    var params = s.params;
    if (st.kind == StepKind.pickPrinter) {
      final p = state.snapshot?.printers.where((x) => x.id == answer).firstOrNull;
      params = {...params, GuideParams.printer: answer, 'printer_name': p?.name ?? '', 'printer_ip': p?.ip ?? ''};
    }
    _log.add('guide', '${st.id}: $answer');
    await _save(s.copyWith(history: [...s.history, _rec(st.id, answer)], params: params));
    final snap = state.snapshot;
    // A printer pick changes what the checks look at.
    if (snap == null || st.kind == StepKind.pickPrinter) return _recheckAndDecide();
    await _decide(snap);
  }

  /// DONE — TEST AGAIN on an action.
  Future<void> testAgain() async {
    final s = state.session, st = state.step;
    if (s == null || st == null || _busy) return;
    if (st.settles) {
      await _save(s.copyWith(settling: true, waitStartedAt: () => now()));
      return poll();
    }
    final snap = await _check();
    if (snap == null) return;
    final ok = _guide.satisfied(st, snap, s.params);
    _log.add('guide', '${st.id}: test_again → ${ok ? 'fixed' : 'still_down'}');
    await _save(
      state.session!.copyWith(
        history: [...state.session!.history, _rec(st.id, 'test_again', ok ? 'fixed' : 'still_down')],
      ),
    );
    await _decide(snap);
  }

  /// One re-check of a wait (or a settling action). The guide screen calls it
  /// every [GuideStep.poll]; it moves on by itself when the wait is over.
  Future<void> poll() async {
    final s0 = state.session, st = state.step;
    if (s0 == null || st == null || _busy) return;
    final waiting = st.kind == StepKind.wait || s0.settling;
    if (!waiting) return;
    final snap = await _check();
    if (snap != null && await _adoptOutsideLink()) return _decide(snap);
    final s = state.session;
    if (snap == null || s == null || s.stepId != st.id) return;
    final since = s.waitStartedAt ?? now();
    if (s.waitStartedAt == null) await _save(s.copyWith(waitStartedAt: () => since));
    final newPi = snap.newPi;
    if (newPi != null) {
      await _save(state.session!.copyWith(params: {...state.session!.params, GuideParams.newPi: newPi.address}));
    }
    final settling = state.session!.settling;
    if (_guide.satisfied(st, snap, state.session!.params)) {
      final result = _guide.resolved(snap, state.session!.params) ? 'fixed' : 'ok';
      _log.add('guide', '${st.id}: done waiting → $result');
      await _save(
        state.session!.copyWith(
          history: [...state.session!.history, _rec(st.id, settling ? 'test_again' : 'auto', result)],
          settling: false,
        ),
      );
      return _decide(snap);
    }
    if (now().difference(since) >= st.timeout) {
      _log.add('guide', '${st.id}: timed out');
      await _save(
        state.session!.copyWith(
          history: [...state.session!.history, _rec(st.id, settling ? 'test_again' : 'timeout', 'still_down')],
          settling: false,
        ),
      );
      return _decide(snap);
    }
  }

  /// The swap / relink login. Throws the agent's error (the screen shows it
  /// with [FriendlyError] and retries `needs_internet` by itself).
  Future<void> login({required String username, required String password}) async {
    final s = state.session, st = state.step;
    if (s == null || st == null) return;
    final address = s.params[GuideParams.newPi] ?? state.snapshot?.newPi?.address;
    if (address == null) throw StateError('No new Pi found yet');
    final storage = ref.read(storageProvider);
    final pairing = ref.read(pairingProvider);
    final name = (pairing?.deviceName ?? '').isNotEmpty
        ? pairing!.deviceName
        : (storage.lastDeviceName.isNotEmpty ? storage.lastDeviceName : 'Counter tablet');
    await ref.read(pairingProvider.notifier).link(address: address, username: username, password: password, name: name);
    _log.add('guide', '${st.id}: linked at $address');
    // The old token belonged to the old Pi's store link; mint afresh.
    await storage.clearReportToken();
    await _save(state.session!.copyWith(history: [...state.session!.history, _rec(st.id, 'auto', 'linked')]));
    await _recheckAndDecide();
  }

  /// BACK: undo the last answer and show that step again. Never across a
  /// link (the old Pi's key is gone) or a wait.
  Future<void> back() async {
    final s = state.session;
    if (s == null || s.history.isEmpty || _busy || !canGoBack) return;
    final last = s.history.last;
    await _save(
      s.copyWith(
        history: s.history.sublist(0, s.history.length - 1),
        stepId: () => last.id,
        waitStartedAt: () => null,
        settling: false,
      ),
    );
    state = state.copyWith(error: () => null);
  }

  bool get canGoBack {
    final s = state.session;
    if (s == null || s.history.isEmpty || s.concluded || s.settling) return false;
    final last = s.history.last;
    if (last.result == 'linked') return false;
    final st = Guide.of(s.guide).step(last.id, s.params);
    return st != null && (st.kind == StepKind.question || st.kind == StepKind.info || st.kind == StepKind.choice);
  }

  /// Exit before the end: reported as `abandoned` once anything was done.
  Future<void> exit() async {
    final s = state.session;
    if (s == null) return;
    if (!s.concluded && s.history.isNotEmpty) {
      _log.add('guide', 'left ${_guide.scenario} after ${s.history.length} steps');
      unawaited(_report(s, const Conclusion(Outcome.abandoned, ConclusionText.abandoned)));
    }
    await clear();
  }

  /// Done with the conclusion card.
  Future<void> clear() async {
    await ref.read(storageProvider).remove(AppStorage.kGuideSession);
    state = const GuideView();
  }

  // --- internals -----------------------------------------------------------------

  StepRecord _rec(String id, String answer, [String result = '']) => StepRecord(id, answer, result: result, at: now());

  Future<void> _save(GuideSession s) async {
    state = state.copyWith(session: () => s);
    await ref.read(storageProvider).setJson(AppStorage.kGuideSession, jsonEncode(s.toJson()));
  }

  Future<CheckSnapshot?> _check() async {
    if (_busy) return null;
    _busy = true;
    state = state.copyWith(checking: true);
    try {
      final snap = await ref.read(checksRunnerProvider).run(probePrinters: _guide.probesPrinters);
      state = state.copyWith(snapshot: snap, checking: false);
      final pin = _guide.pin(snap, state.session!.params);
      if (pin.isNotEmpty) await _save(state.session!.copyWith(params: {...state.session!.params, ...pin}));
      return snap;
    } catch (e) {
      state = state.copyWith(checking: false);
      _log.error('guide', 'checks failed: $e');
      return null;
    } finally {
      _busy = false;
    }
  }

  /// Mid-swap the new card can come up at the old address; the tablet's old
  /// key is refused there, the app unpairs and the setup wizard links the new
  /// Pi. Back in the guide, that counts as the swap's login.
  Future<bool> _adoptOutsideLink() async {
    final s = state.session;
    final pairing = ref.read(pairingProvider);
    if (s == null || pairing == null || !SwapSteps.started(s.history)) return false;
    if (s.history.any((r) => r.id == SwapSteps.login.id && r.result == 'linked')) return false;
    final before = s.params[_kDeviceAtStart] ?? '';
    if (pairing.deviceId.isEmpty || pairing.deviceId == before) return false;
    _log.add('guide', 'the Pi was linked outside the guide (setup wizard)');
    await _save(s.copyWith(history: [...s.history, _rec(SwapSteps.login.id, 'auto', 'linked')], settling: false));
    return true;
  }

  Future<void> _recheckAndDecide() async {
    final snap = await _check();
    if (snap != null) await _decide(snap);
  }

  Future<void> _decide(CheckSnapshot snap, {int depth = 0}) async {
    final s = state.session;
    if (s == null) return;
    final d = _guide.decide(snap, s.history, s.params);
    switch (d) {
      case SwitchGuide(:final to):
        if (depth > 3) return _conclude(snap, const Conclusion(Outcome.needsOwner, ConclusionText.piStillDown));
        _log.add('guide', 'switch ${_guide.scenario} → ${Guide.of(to).scenario}');
        await _save(s.copyWith(guide: to, path: [...s.path, s.guide], stepId: () => null));
        return _decide(snap, depth: depth + 1);
      case Conclude(:final conclusion):
        return _conclude(snap, conclusion);
      case NextStep(:final step):
        final fresh = s.stepId != step.id;
        await _save(
          s.copyWith(
            stepId: () => step.id,
            settling: false,
            waitStartedAt: () => step.kind == StepKind.wait ? (fresh ? now() : (s.waitStartedAt ?? now())) : null,
          ),
        );
        state = state.copyWith(error: () => null);
        if (step.kind == StepKind.auto) await _runAuto(step, snap);
    }
  }

  Future<void> _runAuto(GuideStep st, CheckSnapshot snap) async {
    var result = 'ok';
    try {
      switch (st.effect) {
        case StepEffect.useNewAddress:
          final to = snap.piElsewhere;
          if (to == null) {
            result = 'failed';
          } else {
            await ref.read(pairingProvider.notifier).setAddress(to.address);
            _log.warn('guide', 'Pi moved: ${snap.savedAddress} → ${to.address}');
          }
        case StepEffect.testPrint:
          final c = ref.read(agentClientProvider);
          final id = state.session!.params[GuideParams.printer];
          final r = c == null ? null : await c.testPrinters(printerId: id);
          result = r != null && r.isNotEmpty && r.every((x) => x.ok) ? 'ok' : 'failed';
        case null:
          break;
      }
    } catch (e) {
      result = 'failed';
      state = state.copyWith(error: () => FriendlyError.from(e));
      _log.error('guide', '${st.id}: $e');
    }
    _log.add('guide', '${st.id}: $result');
    await _save(state.session!.copyWith(history: [...state.session!.history, _rec(st.id, 'auto', result)]));
    await _recheckAndDecide();
  }

  Future<void> _conclude(CheckSnapshot snap, Conclusion c) async {
    final s = state.session!;
    _log.add('guide', 'conclusion ${_guide.scenario}: ${c.outcome.wire} ${c.cause ?? ''} ${c.headline}');
    await _save(s.copyWith(conclusion: () => c, stepId: () => null, settling: false, waitStartedAt: () => null));
    if (!c.report) return;
    final sent = await _report(state.session!, c, snap: snap);
    if (state.session?.id == s.id) await _save(state.session!.copyWith(sent: () => sent.name));
  }

  Future<ReportOutcome> _report(GuideSession s, Conclusion c, {CheckSnapshot? snap}) async {
    final sender = ref.read(reportSenderProvider);
    final r = await sender.buildReport(
      kind: 'guide',
      scenario: Guide.of(s.guide).scenario,
      outcome: c.outcome.wire,
      headline: c.headline,
      cause: c.cause,
      fixedBy: c.fixedBy,
      note: c.note,
      steps: s.history,
      checks: (snap ?? state.snapshot)?.toReport(),
    );
    return sender.send(r);
  }
}

/// The paired device id when the guide started — a different one later means
/// the Pi was linked again (maybe in the setup wizard, after an SD swap).
const String _kDeviceAtStart = 'device_at_start';

final guideControllerProvider = NotifierProvider<GuideController, GuideView>(GuideController.new);
