import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_client.dart';
import 'agent_config.dart';
import 'models.dart';
import 'sse_client.dart';

/// Session-local base URL. Edits live until the app is killed (no persistence
/// in v1 — see CLAUDE.md).
final agentBaseUrlProvider = StateProvider<String>((_) => AgentConfig.defaultBaseUrl);

final agentClientProvider = Provider<AgentClient>((ref) {
  final base = ref.watch(agentBaseUrlProvider);
  final client = AgentClient(base);
  ref.onDispose(client.dispose);
  return client;
});

final arrivedOrdersProvider = FutureProvider<List<StoredOrder>>((ref) async {
  final client = ref.watch(agentClientProvider);
  return client.listArrived();
});

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
