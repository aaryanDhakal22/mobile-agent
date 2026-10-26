import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/device_platform.dart';
import '../../core/diag_models.dart';
import '../../core/providers.dart';
import '../../core/sse.dart';
import '../../core/time.dart';
import 'checks.dart';
import 'report.dart';

/// How often the Pi's `/api/diag` and the tablet checks are re-read while the
/// home screen is up.
const Duration kDiagPollInterval = Duration(seconds: 30);

/// How often the report outbox is retried.
const Duration kOutboxRetryInterval = Duration(minutes: 10);

class PiDiagState {
  /// The latest answer (kept when a later poll fails).
  final PiDiag? diag;

  /// When [diag] was fetched.
  final DateTime? at;

  /// The last poll failed (the Pi didn't answer).
  final bool failed;

  /// The Pi is too old for `/api/diag` (agent 2.0.0 answers 404).
  final bool unsupported;

  const PiDiagState({this.diag, this.at, this.failed = false, this.unsupported = false});

  /// [diag] is from the last poll (not a stale leftover).
  bool get fresh => diag != null && !failed;
}

/// The Pi's own view (`GET /api/diag`), polled every 30 s by [DiagPoller] and
/// on demand; saved on the tablet as the last-known diag at most every 5 min.
class PiDiagNotifier extends Notifier<PiDiagState> {
  bool _busy = false;

  @override
  PiDiagState build() {
    ref.watch(agentClientProvider);
    return const PiDiagState();
  }

  Future<void> refresh() async {
    final client = ref.read(agentClientProvider);
    if (client == null || _busy) return;
    _busy = true;
    try {
      final d = await client.getDiag(timeout: const Duration(seconds: 5));
      if (ref.read(agentClientProvider) != client) return;
      state = PiDiagState(diag: d, at: timeNow());
      await saveLastPiDiag(ref.read(storageProvider), d);
    } on AgentException catch (e) {
      if (ref.read(agentClientProvider) != client) return;
      state = e.isNotFound
          ? const PiDiagState(unsupported: true)
          : PiDiagState(diag: state.diag, at: state.at, failed: true);
    } catch (_) {
      state = PiDiagState(diag: state.diag, at: state.at, failed: true);
    } finally {
      _busy = false;
    }
  }

  /// Tests push a diag in.
  void set(PiDiag d) => state = PiDiagState(diag: d, at: timeNow());
}

final piDiagProvider = NotifierProvider<PiDiagNotifier, PiDiagState>(PiDiagNotifier.new);

/// Android's tablet checks (alarm volume, notifications, …), re-read every
/// 30 s and when the app comes back to the front. null off-device.
class DeviceChecksNotifier extends Notifier<DeviceChecks?> {
  @override
  DeviceChecks? build() => null;

  Future<void> refresh() async {
    try {
      final c = await ref.read(devicePlatformProvider).checks();
      state = c;
    } catch (_) {
      // Keep the last answer.
    }
  }

  void set(DeviceChecks? c) => state = c;
}

final deviceChecksProvider = NotifierProvider<DeviceChecksNotifier, DeviceChecks?>(DeviceChecksNotifier.new);

/// Runs the background polls while it's mounted (on the home screen): Pi diag
/// + tablet checks every 30 s and on resume; the report outbox on start, on
/// every reconnect to the Pi and every 10 min (and a report token is minted
/// while the Pi answers, so reports still reach the owner when it doesn't).
class DiagPoller extends ConsumerStatefulWidget {
  final Widget child;
  const DiagPoller({super.key, required this.child});

  @override
  ConsumerState<DiagPoller> createState() => _DiagPollerState();
}

class _DiagPollerState extends ConsumerState<DiagPoller> {
  Timer? _poll;
  Timer? _outbox;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(kDiagPollInterval, (_) => _refresh());
    _outbox = Timer.periodic(kOutboxRetryInterval, (_) => _flush());
    _life = AppLifecycleListener(onResume: _refresh);
    scheduleMicrotask(() {
      if (!mounted) return;
      _refresh();
      _flush();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _outbox?.cancel();
    _life.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    unawaited(ref.read(piDiagProvider.notifier).refresh());
    unawaited(ref.read(deviceChecksProvider.notifier).refresh());
  }

  void _flush() {
    if (!mounted) return;
    final sender = ref.read(reportSenderProvider);
    unawaited(sender.ensureToken().then((_) => sender.flushOutbox()).catchError((_) => 0));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SseStatus>(floorProvider.select((s) => s.connection), (prev, next) {
      if (next == SseStatus.connected && prev != SseStatus.connected) {
        _refresh();
        _flush();
      }
    });
    return widget.child;
  }
}
