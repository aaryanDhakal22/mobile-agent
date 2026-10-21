import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/friendly_error.dart';
import '../../core/local_log.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/sse.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';

/// How often the tablet asks its agent for a newer Quibase.
const Duration kUpdateCheckInterval = Duration(minutes: 10);

/// The Android side of self-update (MainActivity's "quibase/install"
/// channel). Tests swap in a fake via [updatePlatformProvider].
class UpdatePlatform {
  static const _ch = MethodChannel('quibase/install');

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
  Future<void> install(String path) => _ch.invokeMethod('install', {'path': path});
}

final updatePlatformProvider = Provider<UpdatePlatform>((_) => UpdatePlatform());

/// True when [release] is newer than what's installed.
bool needsUpdate(int? installed, AppRelease? release) =>
    installed != null && release != null && release.versionCode > installed;

enum UpdatePhase { downloading, needPermission, installing, failed }

/// Forced self-update: when the agent has a newer Quibase than the one
/// installed, the whole app is locked behind "Updating Quibase" until it is
/// installed (releases are only pushed after close). Android still shows its
/// own one-tap install screen.
class UpdateGate extends ConsumerStatefulWidget {
  final Widget child;
  const UpdateGate({super.key, required this.child});

  @override
  ConsumerState<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends ConsumerState<UpdateGate> {
  AppRelease? _target;
  UpdatePhase _phase = UpdatePhase.downloading;
  double? _progress;
  FriendlyError? _error;
  String? _apkPath;
  bool _checking = false;
  Timer? _timer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(kUpdateCheckInterval, (_) => _check());
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    scheduleMicrotask(_check);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _onResume() {
    // Back from the installer or the "allow installs" settings screen.
    if (_target != null && _phase == UpdatePhase.needPermission) {
      unawaited(_install());
    } else {
      unawaited(_check());
    }
  }

  Future<void> _check() async {
    if (_checking || _target != null) return;
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    _checking = true;
    try {
      final platform = ref.read(updatePlatformProvider);
      final installed = await platform.installedVersion();
      if (installed == null) return;
      final rel = await client.appLatest();
      if (!needsUpdate(installed, rel) || !mounted) return;
      setState(() {
        _target = rel;
        _phase = UpdatePhase.downloading;
        _progress = null;
        _error = null;
      });
      await _download();
    } catch (_) {
      // Agent unreachable / old agent: try again on the next tick.
    } finally {
      _checking = false;
    }
  }

  Future<void> _download() async {
    final rel = _target!;
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    try {
      final dir = await ref.read(updatePlatformProvider).updatesDir();
      final file = File('$dir/quibase-${rel.versionCode}.apk');
      final sum = await client.downloadApk(
        file,
        onProgress: (got, total) {
          if (mounted && total > 0) setState(() => _progress = got / total);
        },
      );
      if (rel.sha256.isNotEmpty && sum != rel.sha256) {
        await file.delete().catchError((Object _) => file);
        _fail(
          FriendlyError(
            'The download was damaged',
            whatToDo: 'Tap TRY AGAIN',
            details: 'sha256 $sum, expected ${rel.sha256} (version ${rel.versionName})',
          ),
        );
        return;
      }
      _apkPath = file.path;
      await _install();
    } catch (e) {
      _fail(FriendlyError.from(e));
    }
  }

  void _fail(FriendlyError f) {
    if (!mounted) return;
    ref.read(localLogProvider).warn('update', '${f.title} · ${f.details}');
    setState(() {
      _phase = UpdatePhase.failed;
      _error = f;
    });
  }

  Future<void> _install() async {
    final platform = ref.read(updatePlatformProvider);
    final path = _apkPath;
    if (path == null) return _download();
    if (!await platform.canInstall()) {
      if (mounted) setState(() => _phase = UpdatePhase.needPermission);
      return;
    }
    if (mounted) setState(() => _phase = UpdatePhase.installing);
    try {
      await platform.install(path);
    } catch (e) {
      final f = FriendlyError.from(e);
      _fail(FriendlyError("Android couldn't open the installer", whatToDo: 'Tap TRY AGAIN', details: f.details));
    }
  }

  @override
  Widget build(BuildContext context) {
    // A reconnect to the agent is a good moment to look for an update.
    ref.listen(floorProvider.select((s) => s.connection), (prev, next) {
      if (next == SseStatus.connected && prev != SseStatus.connected) unawaited(_check());
    });
    final target = _target;
    return Stack(
      children: [
        widget.child,
        if (target != null) Positioned.fill(child: _lock(context, target)),
      ],
    );
  }

  Widget _lock(BuildContext context, AppRelease rel) {
    final (title, message) = switch (_phase) {
      UpdatePhase.downloading => ('Updating Quibase', 'Downloading version ${rel.versionName}…'),
      UpdatePhase.needPermission => (
        'Allow Quibase to update',
        'Android needs permission once: tap ALLOW INSTALLS, switch on "Allow from this source", then come back.',
      ),
      UpdatePhase.installing => (
        'Install the update',
        'Tap INSTALL on the screen that opened. Nothing is lost — the app comes back paired.',
      ),
      UpdatePhase.failed => ('Update not finished', _error == null ? 'Something went wrong.' : '${_error!.short}.'),
    };
    return Material(
      color: QuiccColors.brand900,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update, size: 72, color: QuiccColors.brand400),
                const SizedBox(height: 20),
                Text(
                  title,
                  style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Colors.white),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, color: Colors.white70, height: 1.4),
                ),
                if (_phase == UpdatePhase.failed && (_error?.details.isNotEmpty ?? false)) ...[
                  const SizedBox(height: 8),
                  DetailsToggle(_error!.details, color: Colors.white54),
                ],
                const SizedBox(height: 24),
                if (_phase == UpdatePhase.downloading)
                  SizedBox(
                    width: 360,
                    child: LinearProgressIndicator(value: _progress, minHeight: 8, color: QuiccColors.brand400),
                  ),
                if (_phase == UpdatePhase.needPermission)
                  FilledButton(
                    onPressed: () => ref.read(updatePlatformProvider).openInstallSettings(),
                    child: const Text('ALLOW INSTALLS'),
                  ),
                if (_phase == UpdatePhase.installing)
                  FilledButton(onPressed: _install, child: const Text('INSTALL NOW')),
                if (_phase == UpdatePhase.failed)
                  FilledButton(
                    onPressed: () {
                      setState(() {
                        _phase = UpdatePhase.downloading;
                        _progress = null;
                      });
                      unawaited(_apkPath == null ? _download() : _install());
                    },
                    child: const Text('TRY AGAIN'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
