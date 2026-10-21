import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Map<String, dynamic> _accepted(int n) => {
  'order': {
    'id': 'o-$n',
    'fulfillment': {'type': 'pickup'},
  },
  'status': {'state': 'accepted', 'batch_id': 7, 'kitchen_number': 1100 + n},
};

/// The agent's REST side: a 205-order current batch (two pages), counting
/// `GET /api/floor` as "a full refetch happened".
class FakeAgentRest {
  int floorGets = 0;
  final List<String> orderPages = [];

  http.Client client() => MockClient((req) async {
    switch (req.url.path) {
      case '/api/floor':
        floorGets++;
        return http.Response(floorJson, 200);
      case '/api/orders':
        final offset = int.parse(req.url.queryParameters['offset'] ?? '0');
        final limit = int.parse(req.url.queryParameters['limit'] ?? '50');
        orderPages.add('$offset+$limit');
        final all = List.generate(205, _accepted);
        final page = all.skip(offset).take(limit).toList();
        return http.Response(jsonEncode(page), 200);
      case '/api/orders/arrived':
        return http.Response('[]', 200);
      case '/api/drivers':
        return http.Response(driversJson, 200);
    }
    return http.Response('{"error":"nope"}', 404);
  });
}

void main() {
  test('SSE dropped by the agent → reconnect → full refetch (paged past 200 orders)', () async {
    SharedPreferences.setMockInitialValues({'agent_address': 'http://h:1', 'device_key': 'qagt_k'});
    final prefs = await SharedPreferences.getInstance();
    final rest = FakeAgentRest();

    var connections = 0;
    var floorGetsAtSecondConnect = -1;
    final sseClient = MockClient.streaming((req, _) async {
      connections++;
      if (connections == 1) {
        // One frame, then the agent closes the stream (tablet fell behind).
        return http.StreamedResponse(Stream.value(utf8.encode('event: drivers.updated\ndata: []\n\n')), 200);
      }
      if (connections == 2) floorGetsAtSecondConnect = rest.floorGets;
      return http.StreamedResponse(StreamController<List<int>>().stream, 200); // stays open
    });

    final c = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        agentClientProvider.overrideWith(
          (ref) => AgentClient(baseUrl: 'h:1', deviceKey: 'qagt_k', client: rest.client()),
        ),
        sseClientFactoryProvider.overrideWithValue(() => sseClient),
        sseBackoffProvider.overrideWithValue((_) => const Duration(milliseconds: 5)),
      ],
    );
    addTearDown(c.dispose);
    c.listen<FloorState>(floorProvider, (_, _) {}, fireImmediately: true);

    // Wait for the second connection and a refetch that started after it.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!(connections >= 2 && floorGetsAtSecondConnect >= 0 && rest.floorGets > floorGetsAtSecondConnect)) {
      if (DateTime.now().isAfter(deadline)) fail('no refetch after reconnect (connections=$connections)');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Let the in-flight refetch land.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final s = c.read(floorProvider);
    expect(s.loaded, isTrue);
    expect(s.kitchen, hasLength(205), reason: 'the oldest orders (page 2) are not dropped');
    expect(s.kitchen.first.status.kitchenNumber, 1100);
    expect(rest.orderPages, containsAllInOrder(['0+200', '200+200']));
    expect(s.drivers.map((d) => d.id), ['d-ana', 'd-lee', 'd-sam', 'd-joe']);
  });

  test('listAllOrders pages until a short page and stops at the cap', () async {
    final rest = FakeAgentRest();
    final client = AgentClient(baseUrl: 'h:1', deviceKey: 'k', client: rest.client());
    final all = await client.listAllOrders(batch: 'current', pageSize: 100);
    expect(all, hasLength(205));
    expect(rest.orderPages, ['0+100', '100+100', '200+100']);

    rest.orderPages.clear();
    final capped = await client.listAllOrders(batch: 'current', pageSize: 50, cap: 120);
    expect(capped, hasLength(120));
    expect(rest.orderPages, ['0+50', '50+50', '100+50']);
  });

  test('accept recheck reads the order back and stores it', () async {
    SharedPreferences.setMockInitialValues({'agent_address': 'http://h:1', 'device_key': 'qagt_k'});
    final prefs = await SharedPreferences.getInstance();
    final arrived = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
    final id = (arrived['order'] as Map)['id'] as String;
    final accepted = {
      'order': arrived['order'],
      'status': {...arrived['status'] as Map<String, dynamic>, 'state': 'accepted', 'kitchen_number': 1100},
    };
    final c = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        agentClientProvider.overrideWith(
          (ref) => AgentClient(
            baseUrl: 'h:1',
            deviceKey: 'qagt_k',
            client: MockClient((req) async {
              if (req.url.path == '/api/orders/$id') return http.Response(jsonEncode(accepted), 200);
              throw http.ClientException('offline'); // everything else (SSE / refresh) fails
            }),
          ),
        ),
        sseClientFactoryProvider.overrideWithValue(
          () => MockClient((_) async => throw http.ClientException('offline')),
        ),
        sseBackoffProvider.overrideWithValue((_) => const Duration(seconds: 30)),
      ],
    );
    addTearDown(c.dispose);
    c.listen<FloorState>(floorProvider, (_, _) {});
    final o = await c.read(floorProvider.notifier).recheck(id);
    expect(o!.state, OrderState.accepted);
    expect(c.read(floorProvider).orders[id]!.state, OrderState.accepted);
  });
}
