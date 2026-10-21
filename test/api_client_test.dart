import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';

import 'fixtures.dart';

void main() {
  test('normalizeAgentAddress', () {
    expect(normalizeAgentAddress(' 192.168.1.219:8080 '), 'http://192.168.1.219:8080');
    expect(normalizeAgentAddress('http://pi.lan:8080//'), 'http://pi.lan:8080');
    expect(normalizeAgentAddress('https://agent.example'), 'https://agent.example');
    expect(normalizeAgentAddress(''), '');
  });

  test('every floor request carries the device key', () async {
    late http.BaseRequest seen;
    final c = AgentClient(
      baseUrl: '10.0.0.5:8080',
      deviceKey: 'qagt_abc',
      client: MockClient((req) async {
        seen = req;
        return http.Response('[${arrivedPickupJson.trim()}]', 200);
      }),
    );
    final list = await c.listOrders(batch: 'current', limit: 200);
    expect(list.single.order.customerName, 'Erik Davis');
    expect(seen.headers[kDeviceKeyHeader], 'qagt_abc');
    expect(seen.url.toString(), 'http://10.0.0.5:8080/api/orders?batch=current&offset=0&limit=200');
  });

  test('accept sends prep_minutes; 502 = printer failure', () async {
    late String body;
    final c = AgentClient(
      baseUrl: 'h:1',
      deviceKey: 'k',
      client: MockClient((req) async {
        body = req.body;
        return http.Response(jsonEncode({'error': 'no printer reachable'}), 502);
      }),
    );
    await expectLater(
      c.accept('id-1', prepMinutes: 15),
      throwsA(isA<AgentException>().having((e) => e.isPrinterFailure, 'isPrinterFailure', isTrue)),
    );
    expect(jsonDecode(body), {'prep_minutes': 15});
  });

  test('401 device_required fires onDeviceRevoked', () async {
    var revoked = 0;
    final c = AgentClient(
      baseUrl: 'h:1',
      deviceKey: 'k',
      onDeviceRevoked: () => revoked++,
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({'error': 'pair this device first (or log in)', 'code': 'device_required'}), 401),
      ),
    );
    await expectLater(c.getFloor(), throwsA(isA<AgentException>().having((e) => e.isDeviceRevoked, 'revoked', isTrue)));
    expect(revoked, 1);
  });

  test('close batch 409 → BatchLeftoversException with the orders', () async {
    final c = AgentClient(
      baseUrl: 'h:1',
      deviceKey: 'k',
      client: MockClient((req) async {
        final force = (jsonDecode(req.body) as Map)['force'] as bool;
        if (!force) {
          return http.Response(
            jsonEncode({
              'error': 'batch has 1 unfinished order(s)',
              'code': 'batch_has_leftovers',
              'leftovers': [jsonDecode(onDeliveryJson)],
            }),
            409,
          );
        }
        return http.Response(
          jsonEncode({
            'closed': {
              'id': 7,
              'opened_at': '2026-05-12T10:00:00Z',
              'closed_at': '2026-05-12T23:00:00Z',
              'order_count': 1,
            },
            'auto_finished': [jsonDecode(onDeliveryJson)],
          }),
          200,
        );
      }),
    );
    try {
      await c.closeBatch(force: false);
      fail('expected leftovers');
    } on BatchLeftoversException catch (e) {
      expect(e.leftovers.single.status.kitchenNumber, 1104);
    }
    final r = await c.closeBatch(force: true);
    expect(r.closed.id, 7);
    expect(r.autoFinished, hasLength(1));
  });

  test('pair returns the key; invalid_code surfaces the code', () async {
    final ok = await AgentClient.pair(
      address: '192.168.1.219:8080',
      code: '123456',
      name: 'Counter',
      client: MockClient((req) async {
        expect(req.url.toString(), 'http://192.168.1.219:8080/api/pair');
        expect(jsonDecode(req.body), {'code': '123456', 'name': 'Counter'});
        return http.Response(jsonEncode({'device_id': 'dev-1', 'name': 'Counter', 'key': 'qagt_xyz'}), 201);
      }),
    );
    expect(ok.key, 'qagt_xyz');

    await expectLater(
      AgentClient.pair(
        address: 'h:1',
        code: '000000',
        name: 'Counter',
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'error': 'wrong or expired pairing code', 'code': 'invalid_code'}), 401),
        ),
      ),
      throwsA(isA<AgentException>().having((e) => e.code, 'code', 'invalid_code')),
    );
  });

  test('clock in / out hit the driver routes; 409 driver_not_available surfaces its code', () async {
    final seen = <String>[];
    final c = AgentClient(
      baseUrl: 'h:1',
      deviceKey: 'k',
      client: MockClient((req) async {
        seen.add('${req.method} ${req.url.path}');
        if (req.url.path.endsWith('/clock-in')) {
          return http.Response(
            jsonEncode({
              'id': 'd-lee',
              'name': 'Lee',
              'position': 5,
              'status': 'available',
              'clocked_in_at': '2026-05-12T18:00:00Z',
              'deliveries': 0,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'error': 'driver is not clocked in and available', 'code': 'driver_not_available'}),
          409,
        );
      }),
    );
    final d = await c.clockIn('d-lee');
    expect(d.isAvailable, isTrue);
    expect(d.clockedInAt, DateTime.utc(2026, 5, 12, 18));
    await expectLater(
      c.clockOut('d-sam'),
      throwsA(isA<AgentException>().having((e) => e.code, 'code', 'driver_not_available').having((e) => e.isConflict, 'conflict', isTrue)),
    );
    expect(seen, ['POST /api/drivers/d-lee/clock-in', 'POST /api/drivers/d-sam/clock-out']);
  });

  test('shifts are fetched for the last N days', () async {
    late Uri url;
    final c = AgentClient(
      baseUrl: 'h:1',
      deviceKey: 'k',
      client: MockClient((req) async {
        url = req.url;
        return http.Response(shiftsJson, 200);
      }),
    );
    final list = await c.listShifts(days: 7);
    expect(url.path, '/api/drivers/shifts');
    expect(url.queryParameters['days'], '7');
    expect(list.map((s) => s.driverName), ['Joe', 'Lee', 'Sam']);
  });
}
