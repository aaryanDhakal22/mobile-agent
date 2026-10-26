import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/floor_state.dart';
import '../../core/friendly_error.dart';
import '../../core/local_log.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/sse.dart';
import '../../core/time.dart';

/// How often the tablet asks its agent for a newer Quibase.
const Duration kUpdateCheckInterval = Duration(minutes: 10);

/// LATER on the "Update ready" prompt hides it this long.
const Duration kUpdateSnooze = Duration(hours: 2);

/// An install Android never answered (no result, no restart) counts as
/// failed after this long.
const Duration kInstallTimeout = Duration(minutes: 2);

/// After this many failed silent attempts, INSTALL NOW opens Android's own
/// install screen instead.
const int kSessionFailuresBeforeScreen = 2;

/// What Android said about an install (InstallChannel.kt `status`).
enum InstallResult { committed, success, pendingUserAction, aborted, failed }

InstallResult installResultFrom(String s) => switch (s) {
  'committed' => InstallResult.committed,
  'success' => InstallResult.success,
  'pending_user_action' => InstallResult.pendingUserAction,
  'aborted' => InstallResult.aborted,
  _ => InstallResult.failed,
};

/// The Android side of self-update (InstallChannel.kt, "quibase/install").
/// Tests swap in a fake via [updatePlatformProvider].
class UpdatePlatform {
  static const _ch = MethodChannel('quibase/install');
  final _results = StreamController<(InstallResult, String)>.broadcast();

  UpdatePlatform() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'status') {
        final m = (call.arguments as Map?) ?? const {};
        _results.add((installResultFrom('${m['status']}'), '${m['message'] ?? ''}'));
      }
      return null;
    });
  }

  /// Install results as they come from Android.
  Stream<(InstallResult, String)> get results => _results.stream;

  /// The installed versionCode, or null where the channel doesn't exist
  /// (tests, desktop) — then updates are skipped.
  Future<int?> installedVersion() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('version');
      final v = m?['versionCode'];
      return v is int ? v : null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<String> updatesDir() async => (await _ch.invokeMethod<String>('updatesDir'))!;
  Future<bool> canInstall() async => (await _ch.invokeMethod<bool>('canInstall')) ?? false;
  Future<void> openInstallSettings() => _ch.invokeMethod('openInstallSettings');

  /// True once Quibase installed itself (Android 12+): updates need no tap.
  Future<bool> canInstallSilently() async {
    try {
      return (await _ch.invokeMethod<bool>('canInstallSilently')) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The silent path: a PackageInstaller session (result on [results]).
  Future<void> installSession(String path) => _ch.invokeMethod('installSession', {'path': path});

  /// Opens Android's confirm screen for a pending_user_action result.
  Future<bool> confirm() async => (await _ch.invokeMethod<bool>('confirm')) ?? false;

  /// The old path: Android's own install screen.
  Future<void> installWithScreen(String path) => _ch.invokeMethod('install', {'path': path});
}

final updatePlatformProvider = Provider<UpdatePlatform>((_) => UpdatePlatform());

/// True when [release] is newer than what's installed.
bool needsUpdate(int? installed, AppRelease? release) =>
    installed != null && release != null && release.versionCode > installed;

/// Deletes every downloaded APK in [dir] except [keep] (older releases).
Future<void> pruneOldApks(Directory dir, String keep) async {
  try {
    await for (final f in dir.list()) {
      if (f is File && f.path != keep && f.path.endsWith('.apk')) {
        await f.delete().catchError((Object _) => f);
      }
    }
  } catch (_) {
    // Only cache space: never block an update on it.
  }
}

enum UpdatePhase {
  /// Nothing newer on the Pi.
  none,
  downloading,

  /// Downloaded and checked; installs by itself after Close batch.
  ready,
  installing,

  /// Android wants one tap (the first update Quibase installs itself).
  needsTap,

  /// Android doesn't let Quibase install apps yet (a settings switch).
  needPermission,
  failed,
}

@immutable
class UpdateState {
  final AppRelease? target;
  final UpdatePhase phase;
  final double? progress;
  final FriendlyError? error;
  final String? apkPath;

  /// LATER on the prompt: no prompt until then.
  final DateTime? snoozedUntil;

  /// Quibase is its own installer, so the next install needs no tap.
  final bool silent;
  final DateTime? lastCheck;

  const UpdateState({
    this.target,
    this.phase = UpdatePhase.none,
    this.progress,
    this.error,
    this.apkPath,
    this.snoozedUntil,
    this.silent = false,
    this.lastCheck,
  });

  bool get available => target != null;

  /// The "Update ready — install now?" prompt has something to ask.
  bool get wantsTap =>
      phase == UpdatePhase.needsTap || phase == UpdatePhase.needPermission || phase == UpdatePhase.failed;

  bool snoozed(DateTime now) => snoozedUntil != null && now.isBefore(snoozedUntil!);

  UpdateState copyWith({
    UpdatePhase? phase,
    double? progress,
    FriendlyError? error,
    String? apkPath,
    DateTime? snoozedUntil,
    bool? silent,
    DateTime? lastCheck,
    bool clearError = false,
    bool clearSnooze = false,
  }) => UpdateState(
    target: target,
    phase: phase ?? this.phase,
    progress: progress ?? this.progress,
    error: clearError ? null : (error ?? this.error),
    apkPath: apkPath ?? this.apkPath,
    snoozedUntil: clearSnooze ? null : (snoozedUntil ?? this.snoozedUntil),
    silent: silent ?? this.silent,
    lastCheck: lastCheck ?? this.lastCheck,
  );
}

/// Nothing ringing, waiting or cooking: a safe moment to install.
bool floorIsQuiet(FloorState fs, bool ringing) => !ringing && fs.arrived.isEmpty && fs.kitchen.isEmpty;

/// The open batch has had no orders yet: the store closed the night's batch
/// and hasn't taken an order since — an update installs then.
bool batchIsFresh(FloorState fs) => fs.floor != null && fs.currentBatchOrders.isEmpty;

/// Quibase self-update (1.6.1). Runs headless (started in main.dart), so it
/// also works with the screen off:
///
///   * asks the Pi for a newer Quibase on start, every 10 min, on resume and
///     on every reconnect, and downloads it quietly (sha256-checked);
///   * installs it by itself right after Close batch — when the open batch
///     has had no orders yet and nothing is ringing, waiting or cooking;
///   * silently once Quibase installed itself (Android 12+). Otherwise
///     Android wants one tap: [UpdateState.wantsTap] and the prompt
///     (UpdatePrompt) asks "Update ready — install now?" at the next quiet
///     moment; LATER hides it for [kUpdateSnooze]. Never locks the tablet.
///   * [installNow] (Store → Updates, developer Config) installs at once.
class Updater extends Notifier<UpdateState> {
  Timer? _tick;
  Timer? _installTimer;
  StreamSubscription<(InstallResult, String)>? _results;
  AppLifecycleListener? _lifecycle;
  bool _checking = false;
  int _sessionFailures = 0;

  @override
  UpdateState build() {
    // Checks only while paired (an unpaired tablet has no Pi to ask).
    ref.listen(agentClientProvider, (_, client) {
      _tick?.cancel();
      _tick = client == null ? null : Timer.periodic(kUpdateCheckInterval, (_) => unawaited(check()));
      if (client != null) scheduleMicrotask(() => unawaited(check()));
    }, fireImmediately: true);
    _results = ref.read(updatePlatformProvider).results.listen(_onResult);
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    ref.listen<FloorState>(floorProvider, (prev, next) {
      if (next.connection == SseStatus.connected && prev?.connection != SseStatus.connected) unawaited(check());
      _maybeInstall();
    });
    ref.listen(alarmProvider.select((a) => a.ringing), (_, _) => _maybeInstall());
    ref.onDispose(() {
      _tick?.cancel();
      _installTimer?.cancel();
      _results?.cancel();
      _lifecycle?.dispose();
    });
    return const UpdateState();
  }

  LocalLog get _log => ref.read(localLogProvider);

  void _onResume() {
    // Back from Android's install screen or the "allow installs" switch.
    if (state.phase == UpdatePhase.needPermission) {
      unawaited(installNow());
    } else {
      unawaited(check());
    }
  }

  /// Asks the Pi; a withdrawn (or no longer newer) release is dropped.
  Future<void> check() async {
    if (_checking) return;
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    _checking = true;
    try {
      final platform = ref.read(updatePlatformProvider);
      final installed = await platform.installedVersion();
      if (installed == null) return;
      final rel = await client.appLatest();
      final silent = await platform.canInstallSilently();
      state = state.copyWith(silent: silent, lastCheck: timeNow());
      if (!needsUpdate(installed, rel)) {
        if (state.target != null) {
          _log.add('update', 'release withdrawn on the Pi');
          state = UpdateState(silent: silent, lastCheck: state.lastCheck);
        }
        return;
      }
      if (state.target?.versionCode == rel!.versionCode && state.phase != UpdatePhase.failed) return;
      if (state.target?.versionCode != rel.versionCode) {
        _sessionFailures = 0;
        state = UpdateState(target: rel, phase: UpdatePhase.downloading, silent: silent, lastCheck: state.lastCheck);
      }
      if (state.apkPath == null) await _download();
    } catch (_) {
      // Pi unreachable / old Pi: try again on the next tick.
    } finally {
      _checking = false;
    }
  }

  Future<void> _download() async {
    final rel = state.target;
    final client = ref.read(agentClientProvider);
    if (rel == null || client == null) return;
    state = state.copyWith(phase: UpdatePhase.downloading, clearError: true);
    try {
      final dir = await ref.read(updatePlatformProvider).updatesDir();
      final file = File('$dir/quibase-${rel.versionCode}.apk');
      final sum = await client.downloadApk(
        file,
        onProgress: (got, total) {
          if (total > 0 && identical(state.target, rel)) state = state.copyWith(progress: got / total);
        },
      );
      if (!identical(state.target, rel)) return; // withdrawn / replaced meanwhile
      if (rel.sha256.isNotEmpty && sum != rel.sha256) {
        await file.delete().catchError((Object _) => file);
        return _fail(
          FriendlyError(
            'The download was damaged',
            whatToDo: 'Tap TRY AGAIN',
            details: 'sha256 $sum, expected ${rel.sha256} (version ${rel.versionName})',
          ),
        );
      }
      await pruneOldApks(Directory(dir), file.path);
      state = state.copyWith(phase: UpdatePhase.ready, apkPath: file.path);
      _log.add('update', 'Quibase ${rel.versionName} (${rel.versionCode}) downloaded; installs after Close batch');
      _maybeInstall();
    } catch (e) {
      if (identical(state.target, rel)) _fail(FriendlyError.from(e));
    }
  }

  /// The automatic install: a downloaded release, right after Close batch,
  /// at a quiet moment.
  void _maybeInstall() {
    if (state.phase != UpdatePhase.ready) return;
    final fs = ref.read(floorProvider);
    if (!batchIsFresh(fs) || !floorIsQuiet(fs, ref.read(alarmProvider).ringing)) return;
    _log.add('update', 'batch closed and the floor is quiet: installing ${state.target?.versionName}');
    unawaited(installNow());
  }

  /// Installs the downloaded release now (silently when Android allows it).
  Future<void> installNow() async {
    final path = state.apkPath;
    if (state.target == null) return;
    if (path == null) return _download();
    final platform = ref.read(updatePlatformProvider);
    if (!await platform.canInstall()) {
      state = state.copyWith(phase: UpdatePhase.needPermission);
      return;
    }
    state = state.copyWith(phase: UpdatePhase.installing, clearError: true);
    _installTimer?.cancel();
    _installTimer = Timer(kInstallTimeout, () {
      if (state.phase == UpdatePhase.installing) {
        _fail(const FriendlyError("Android didn't finish the install", whatToDo: 'Tap INSTALL NOW to try again'));
      }
    });
    try {
      if (_sessionFailures >= kSessionFailuresBeforeScreen) {
        await platform.installWithScreen(path);
        _installTimer?.cancel();
        state = state.copyWith(phase: UpdatePhase.needsTap);
      } else {
        await platform.installSession(path);
      }
    } catch (e) {
      _sessionFailures++;
      _fail(FriendlyError("Android couldn't start the install", whatToDo: 'Tap TRY AGAIN', details: FriendlyError.from(e).details));
    }
  }

  /// INSTALL NOW on the prompt: Android's confirm screen when it asked for
  /// one, else a fresh attempt.
  Future<void> tapInstall() async {
    if (state.phase == UpdatePhase.needPermission) {
      return ref.read(updatePlatformProvider).openInstallSettings();
    }
    if (state.phase == UpdatePhase.needsTap && await ref.read(updatePlatformProvider).confirm()) {
      state = state.copyWith(phase: UpdatePhase.installing);
      return;
    }
    return installNow();
  }

  /// LATER on the prompt.
  void snooze() {
    _log.add('update', 'install put off for ${kUpdateSnooze.inHours} h');
    state = state.copyWith(snoozedUntil: timeNow().add(kUpdateSnooze));
  }

  void _onResult((InstallResult, String) r) {
    final (result, message) = r;
    if (state.target == null) return;
    switch (result) {
      case InstallResult.committed:
      case InstallResult.success: // the process ends right after this
        break;
      case InstallResult.pendingUserAction:
        _installTimer?.cancel();
        _log.add('update', 'Android wants a tap for this install');
        state = state.copyWith(phase: UpdatePhase.needsTap, clearSnooze: true);
      case InstallResult.aborted:
        _installTimer?.cancel();
        state = state.copyWith(phase: UpdatePhase.needsTap);
        _log.add('update', 'install cancelled');
      case InstallResult.failed:
        _sessionFailures++;
        _fail(FriendlyError('The update did not install', whatToDo: 'Tap TRY AGAIN', details: message));
    }
  }

  void _fail(FriendlyError f) {
    _installTimer?.cancel();
    _log.warn('update', '${f.title} · ${f.details}');
    state = state.copyWith(phase: UpdatePhase.failed, error: f);
  }
}

final updaterProvider = NotifierProvider<Updater, UpdateState>(Updater.new);
