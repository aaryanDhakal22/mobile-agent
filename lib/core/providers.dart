import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_client.dart';
import 'agent_config.dart';
import 'alert_player.dart';
import 'models.dart';
import 'printer_models.dart';
import 'sse_client.dart';

/// Theme mode — toggled by the `q` logo on the nav rail. No persistence in
/// v1; resets to dark on each launch.
final themeModeProvider = StateProvider<ThemeMode>((_) => ThemeMode.dark);

/// Which chime plays on order arrival. Cashier picks from the Settings
/// dropdown. No persistence in v1 — resets to `default` each launch.
final alertSoundProvider =
    StateProvider<AlertSound>((_) => AlertSound.defaultSound);

/// Session-local base URL. Edits live until the app is killed (no persistence
/// in v1 — see CLAUDE.md).
final agentBaseUrlProvider = StateProvider<String>((_) => AgentConfig.defaultBaseUrl);

final agentClientProvider = Provider<AgentClient>((ref) {
  final base = ref.watch(agentBaseUrlProvider);
  final client = AgentClient(base);
  ref.onDispose(client.dispose);
  return client;
});

/// Arrived queue notifier — fetches from the agent but also exposes
/// optimistic [remove] and [prepend] so the UI can react without waiting for
/// a round-trip. Used on accept (remove instantly) and on SSE arrival
/// (prepend instantly).
class ArrivedOrdersNotifier extends AsyncNotifier<List<StoredOrder>> {
  @override
  Future<List<StoredOrder>> build() async {
    final client = ref.watch(agentClientProvider);
    return client.listArrived();
  }

  void remove(int orderId) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncValue.data(
      current.where((o) => o.order.orderId != orderId).toList(growable: false),
    );
  }

  void prepend(StoredOrder order) {
    final current = state.valueOrNull ?? const [];
    if (current.any((o) => o.order.orderId == order.order.orderId)) return;
    state = AsyncValue.data([order, ...current]);
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      return ref.read(agentClientProvider).listArrived();
    });
  }
}

final arrivedOrdersProvider =
    AsyncNotifierProvider<ArrivedOrdersNotifier, List<StoredOrder>>(
  ArrivedOrdersNotifier.new,
);

final autoAcceptProvider = FutureProvider<bool>((ref) async {
  final client = ref.watch(agentClientProvider);
  return client.getAutoAccept();
});

/// SSE stream of freshly-arrived orders. Reconnects forever — the stream
/// itself never errors out. Watched at the app root so it's active for the
/// lifetime of the process.
final arrivedEventStreamProvider = StreamProvider<StoredOrder>((ref) {
  final base = ref.watch(agentBaseUrlProvider);
  return arrivedEventStream(base);
});

/// First-page order history. History tab invalidates this provider when it
/// wants fresh data (e.g. pull-to-refresh).
final orderHistoryProvider = FutureProvider<List<StoredOrder>>((ref) async {
  final client = ref.watch(agentClientProvider);
  return client.listOrders(limit: 50);
});

/// Polls `GET /api/printers` every 5 s. Errors are surfaced as AsyncValue
/// errors but do NOT terminate the stream — the next tick tries again and
/// transitions back to data on success. Auto-disposes when the Printer pane
/// is not mounted, so we aren't pinging the agent from hidden tabs.
final printerStatusStreamProvider =
    StreamProvider.autoDispose<List<PrinterStatus>>((ref) {
  final client = ref.watch(agentClientProvider);
  late StreamController<List<PrinterStatus>> controller;
  Timer? timer;

  Future<void> tick() async {
    try {
      final snap = await client.listPrinters();
      if (!controller.isClosed) controller.add(snap);
    } catch (e, st) {
      if (!controller.isClosed) controller.addError(e, st);
    }
  }

  controller = StreamController<List<PrinterStatus>>(
    onListen: () {
      tick();
      timer = Timer.periodic(const Duration(seconds: 5), (_) => tick());
    },
    onCancel: () {
      timer?.cancel();
      return controller.close();
    },
  );

  ref.onDispose(() {
    timer?.cancel();
    if (!controller.isClosed) controller.close();
  });

  return controller.stream;
});
