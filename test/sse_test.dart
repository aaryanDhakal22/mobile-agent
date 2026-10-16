import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/sse.dart';

import 'fixtures.dart';

List<SseEvent> feed(SseLineParser p, String stream) {
  final out = <SseEvent>[];
  for (final line in const LineSplitter().convert(stream)) {
    final ev = p.addLine(line);
    if (ev != null) out.add(ev);
  }
  return out;
}

void main() {
  group('SseLineParser', () {
    test('event + data dispatch on blank line', () {
      final evs = feed(SseLineParser(), 'event: order.updated\ndata: {"a":1}\n\n');
      expect(evs, hasLength(1));
      expect(evs.single.event, 'order.updated');
      expect(evs.single.data, '{"a":1}');
      expect(evs.single.json, {'a': 1});
    });

    test('keepalive comments are ignored', () {
      final p = SseLineParser();
      final evs = feed(p, ': keepalive\n\n: keepalive\n\nevent: drivers.updated\ndata: []\n\n');
      expect(evs.map((e) => e.event), ['drivers.updated']);
    });

    test('multi-line data joins with newline; no-space and CRLF forms', () {
      final p = SseLineParser();
      expect(p.addLine('event:batch.closed\r'), isNull);
      expect(p.addLine('data:{"closed":'), isNull);
      expect(p.addLine('data: {"id":1}}'), isNull);
      final ev = p.addLine('\r')!;
      expect(ev.event, 'batch.closed');
      expect(ev.data, '{"closed":\n{"id":1}}');
    });

    test('frame without data is dropped; event name resets between frames', () {
      final evs = feed(SseLineParser(), 'event: order.arrived\n\ndata: x\n\n');
      expect(evs, hasLength(1));
      expect(evs.single.event, 'message');
      expect(evs.single.json, isNull);
    });

    test('a real order.arrived frame round-trips into a StoredOrder', () {
      final body = jsonEncode({...jsonDecode(arrivedPickupJson) as Map, '_traceparent': '00-x-y-01'});
      final evs = feed(SseLineParser(), 'event: order.arrived\ndata: $body\n\n');
      final so = StoredOrder.fromJson(evs.single.json! as Map<String, dynamic>);
      expect(so.state, OrderState.arrived);
      expect(so.order.items.first.size, '12 Medium');
    });

    test('reset drops a half-read frame', () {
      final p = SseLineParser();
      p.addLine('event: order.updated');
      p.addLine('data: {"partial":');
      p.reset();
      expect(p.addLine(''), isNull);
    });
  });

  test('sseBackoff grows exponentially and caps', () {
    expect(sseBackoff(0), const Duration(seconds: 1));
    expect(sseBackoff(1), const Duration(seconds: 2));
    expect(sseBackoff(3), const Duration(seconds: 8));
    expect(sseBackoff(50), const Duration(seconds: 30));
  });

  group('applySseEvent', () {
    final arrivedMap = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
    final base = const FloorState().withSnapshot(
      floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
      current: [StoredOrder.fromJson(jsonDecode(onDeliveryJson) as Map<String, dynamic>)],
      arrived: const [],
      drivers: const [],
      at: DateTime(2026),
    );

    test('order.arrived adds to the queue', () {
      final up = applySseEvent(base, SseEvent('order.arrived', jsonEncode(arrivedMap)));
      expect(up.refetch, isFalse);
      expect(up.state.arrived.single.order.customerName, 'Erik Davis');
    });

    test('order.updated replaces the stored copy', () {
      var s = applySseEvent(base, SseEvent('order.arrived', jsonEncode(arrivedMap))).state;
      final accepted = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
      (accepted['status'] as Map)['state'] = 'accepted';
      (accepted['status'] as Map)['kitchen_number'] = 1105;
      s = applySseEvent(s, SseEvent('order.updated', jsonEncode(accepted))).state;
      expect(s.arrived, isEmpty);
      expect(s.kitchen.single.status.kitchenNumber, 1105);
    });

    test('order.escalated bumps the counter and records the wait', () {
      final m = {...arrivedMap, 'waiting_seconds': 240};
      final s = applySseEvent(base, SseEvent('order.escalated', jsonEncode(m))).state;
      expect(s.escalations, base.escalations + 1);
      expect(s.waitingSeconds[s.arrived.single.id], 240);
    });

    test('drivers.updated replaces the roster in queue order', () {
      final s = applySseEvent(base, SseEvent('drivers.updated', driversJson)).state;
      expect(s.drivers.map((d) => d.id), ['d-ana', 'd-lee', 'd-sam', 'd-joe']);
      expect(s.drivers[1].status, DriverStatus.off);
      expect(s.drivers[0].clockedInAt, DateTime.utc(2026, 5, 12, 15, 58));
      expect(s.nextDriver!.name, 'Ana');
      expect(s.outWith('d-sam').single.status.kitchenNumber, 1104);
    });

    test('batch.closed switches to the opened batch and asks for a refetch', () {
      final up = applySseEvent(
        base,
        SseEvent(
          'batch.closed',
          jsonEncode({
            'closed': {
              'id': 7,
              'opened_at': '2026-05-12T10:00:00Z',
              'closed_at': '2026-05-12T23:00:00Z',
              'order_count': 12,
            },
            'opened': {'id': 8, 'opened_at': '2026-05-12T23:00:00Z', 'order_count': 0},
          }),
        ),
      );
      expect(up.refetch, isTrue);
      expect(up.state.currentBatchId, 8);
    });

    test('unknown events and bad payloads are ignored', () {
      expect(identical(applySseEvent(base, const SseEvent('command', '{}')).state, base), isTrue);
      expect(identical(applySseEvent(base, const SseEvent('order.updated', 'not json')).state, base), isTrue);
      expect(identical(applySseEvent(base, const SseEvent('drivers.updated', '{}')).state, base), isTrue);
    });
  });

  group('applySseEvent — stale arrivals', () {
    final arrivedMap = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
    final id = (arrivedMap['order'] as Map)['id'] as String;
    final base = const FloorState().withSnapshot(
      floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
      current: const [],
      arrived: const [],
      drivers: const [],
      at: DateTime(2026),
    );
    Map<String, dynamic> inState(String state) => {
      'order': arrivedMap['order'],
      'status': {...arrivedMap['status'] as Map<String, dynamic>, 'state': state, 'kitchen_number': 1100},
    };

    test('an SSE arrival with the stored status lands in the current batch at once', () {
      final s = applySseEvent(base, SseEvent('order.arrived', jsonEncode(arrivedMap))).state;
      expect(s.currentBatchOrders.map((o) => o.id), [id]);
      // An older agent that sends no batch_id: still shown in the open batch.
      final bare = {
        'order': arrivedMap['order'],
        'status': {'state': 'arrived'},
      };
      final s2 = applySseEvent(base, SseEvent('order.arrived', jsonEncode(bare))).state;
      expect(s2.currentBatchOrders.map((o) => o.id), [id]);
    });

    for (final later in ['accepted', 'ready', 'on_delivery', 'delivered', 'cancelled']) {
      test('order.arrived / order.escalated never flip a $later order back to arrived', () {
        final held = applySseEvent(base, SseEvent('order.updated', jsonEncode(inState(later)))).state;
        expect(held.orders[id]!.state.wire, later);

        final a = applySseEvent(held, SseEvent('order.arrived', jsonEncode(arrivedMap))).state;
        expect(identical(a, held), isTrue);
        expect(a.arrived, isEmpty);

        final e = applySseEvent(
          held,
          SseEvent('order.escalated', jsonEncode({...arrivedMap, 'waiting_seconds': 240})),
        ).state;
        expect(identical(e, held), isTrue, reason: 'no flip, no loud alarm');
        expect(e.escalations, held.escalations);
      });
    }

    test('order.updated back to arrived (failed print reverted) still applies', () {
      final held = applySseEvent(base, SseEvent('order.updated', jsonEncode(inState('accepted')))).state;
      final s = applySseEvent(held, SseEvent('order.updated', jsonEncode(arrivedMap))).state;
      expect(s.arrived.single.id, id);
    });
  });

  group('AgentEventStream', () {
    String frame(String event, Object data) => 'event: $event\ndata: ${jsonEncode(data)}\n\n';

    /// Serves one canned response per connection attempt, in order; the
    /// stream body ends (the agent closed it) after its frames.
    http.Client Function() fakeServer(List<http.StreamedResponse Function()> responses, List<http.BaseRequest> seen) {
      var i = 0;
      return () => MockClient.streaming((req, _) async {
        seen.add(req);
        if (i >= responses.length) {
          // Hold the last connection open (never-ending body).
          return http.StreamedResponse(StreamController<List<int>>().stream, 200);
        }
        return responses[i++]();
      });
    }

    http.StreamedResponse ok(String body) => http.StreamedResponse(Stream.value(utf8.encode(body)), 200);

    test('reconnects (and fires onConnected → refetch) when the agent closes the stream', () async {
      final seen = <http.BaseRequest>[];
      final events = <String>[];
      final statuses = <SseStatus>[];
      var connected = 0;
      final done = Completer<void>();
      final stream = AgentEventStream(
        baseUrl: '10.0.0.5:8080',
        deviceKey: 'qagt_k',
        onEvent: (e) => events.add(e.event),
        onStatus: statuses.add,
        onConnected: () {
          connected++;
          if (connected == 3 && !done.isCompleted) done.complete();
        },
        onDeviceRevoked: () => fail('not revoked'),
        backoff: (_) => const Duration(milliseconds: 5),
        clientFactory: fakeServer([
          // 1st: one frame, then the agent drops us (fell behind).
          () => ok(frame('drivers.updated', const [])),
          // 2nd: refused (agent restarting).
          () => http.StreamedResponse(Stream.value(utf8.encode('{"error":"down"}')), 503),
          // 3rd: another frame, closed again.
          () => ok(frame('order.updated', const {})),
          // 4th: stays open.
        ], seen),
      );
      stream.start();
      await done.future.timeout(const Duration(seconds: 5));
      stream.stop();

      expect(connected, 3, reason: 'every successful (re)connect asks for a refetch');
      expect(events, ['drivers.updated', 'order.updated']);
      expect(seen.length, greaterThanOrEqualTo(4));
      expect(seen.first.url.toString(), 'http://10.0.0.5:8080/api/events');
      expect(seen.first.headers['X-Agent-Device-Key'], 'qagt_k');
      expect(statuses, containsAllInOrder([SseStatus.connected, SseStatus.disconnected, SseStatus.connected]));
    });

    test('401 device_required stops for good and reports the revoke', () async {
      final seen = <http.BaseRequest>[];
      final revoked = Completer<void>();
      final stream = AgentEventStream(
        baseUrl: 'h:1',
        deviceKey: 'k',
        onEvent: (_) {},
        onStatus: (_) {},
        onConnected: () => fail('never connects'),
        onDeviceRevoked: revoked.complete,
        backoff: (_) => const Duration(milliseconds: 5),
        clientFactory: fakeServer([
          () => http.StreamedResponse(
            Stream.value(utf8.encode('{"error":"pair this tablet","code":"device_required"}')),
            401,
          ),
        ], seen),
      );
      stream.start();
      await revoked.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, hasLength(1), reason: 'no reconnect after a revoke');
      stream.stop();
    });
  });
}
