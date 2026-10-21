import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/storage.dart';
import 'setup_flow.dart';

/// Probes an agent address (`GET /api/session`) — overridden in tests.
final agentProbeProvider = Provider<Future<AgentProbe> Function(String address)>(
  (_) =>
      (address) => AgentClient.probe(address: address),
);

/// The setup wizard's progress (null = set up). Saved on every change under
/// `setup_progress_v1`; see [SetupFlow.resume] for how a restart picks up.
class SetupController extends Notifier<SetupProgress?> {
  @override
  SetupProgress? build() {
    final storage = ref.read(storageProvider);
    final paired = ref.read(pairingProvider) != null;
    SetupProgress? stored;
    try {
      final raw = storage.getJson(AppStorage.kSetupProgress);
      if (raw != null) stored = SetupProgress.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      stored = null;
    }
    final resumed = SetupFlow.resume(stored, paired: paired);
    if (resumed != null && resumed.isDone) return null;

    // The pairing went away (unpaired here, revoked by the Pi): back into
    // the wizard at "Find the Pi".
    ref.listen<Pairing?>(pairingProvider, (prev, next) {
      if (prev != null && next == null) {
        _set(SetupProgress.start(step: SetupStep.findPi, address: prev.address));
      }
    });
    return resumed;
  }

  void _set(SetupProgress? p) {
    state = p;
    final storage = ref.read(storageProvider);
    if (p == null) {
      unawaited(storage.remove(AppStorage.kSetupProgress));
    } else {
      unawaited(storage.setJson(AppStorage.kSetupProgress, jsonEncode(p.toJson())));
    }
  }

  SetupProgress get _p => state ?? SetupProgress.start();

  void next() => _set(SetupFlow.next(_p));
  void back() => _set(SetupFlow.back(_p));
  void goTo(SetupStep s) => _set(_p.copyWith(step: s));
  void update(SetupProgress Function(SetupProgress p) f) => _set(f(_p));

  void choosePi({required String address, required bool isNew, String store = ''}) =>
      _set(_p.copyWith(step: SetupStep.signIn, piAddress: address, piIsNew: isNew, piStore: store));

  void paired({LinkSummary? link, String store = ''}) => _set(SetupFlow.paired(_p, link: link, store: store));

  /// "Finish later": the app runs normally; Settings offers CONTINUE.
  void finishLater() => _set(_p.copyWith(finishedLater: true));
  void resumeLater() {
    if (state != null) _set(_p.copyWith(finishedLater: false));
  }

  /// Done: keep the final record (Done step) so a restart doesn't reopen it.
  void finish() => _set(_p.copyWith(step: SetupStep.done, finishedLater: false, finished: true));

  /// Settings → set this tablet up again from the start (after unpairing).
  void restart() => _set(SetupProgress.start());
}

final setupProvider = NotifierProvider<SetupController, SetupProgress?>(SetupController.new);

/// True while the wizard should be on screen instead of the app.
final setupActiveProvider = Provider<bool>((ref) {
  final p = ref.watch(setupProvider);
  final paired = ref.watch(pairingProvider) != null;
  if (!paired) return true;
  return p != null && p.active;
});
