import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/friendly_error.dart';

/// 2.0.3: join an already set-up Pi with the store manager login
/// (`POST /api/pair/manager`, Pi 2.4.2).
void main() {
  test('posts the login and the tablet name, returns the key', () async {
    late http.Request sent;
    final c = MockClient((r) async {
      sent = r;
      return http.Response(
        jsonEncode({
          'device_id': 'd1',
          'name': 'Counter tablet',
          'kind': 'tablet',
          'key': 'qagt_abc',
          'device_key': 'qagt_abc',
        }),
        201,
      );
    });
    final r = await AgentClient.pairWithManager(
      address: '10.0.0.5:8080',
      username: ' lombardispizza ',
      password: 'pw',
      name: ' Counter tablet ',
      client: c,
    );
    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/pair/manager');
    expect(jsonDecode(sent.body), {'username': 'lombardispizza', 'password': 'pw', 'tablet_name': 'Counter tablet'});
    expect(r.key, 'qagt_abc');
    expect(r.deviceId, 'd1');
  });

  test('a wrong login and a long wait read as friendly errors', () async {
    Future<AgentException> errorFor(int status, String code) async {
      final c = MockClient((_) async => http.Response(jsonEncode({'error': 'x', 'code': code}), status));
      try {
        await AgentClient.pairWithManager(address: '10.0.0.5', username: 'u', password: 'p', name: 'n', client: c);
      } on AgentException catch (e) {
        return e;
      }
      throw StateError('no error');
    }

    final bad = await errorFor(401, 'bad_login');
    expect(bad.code, 'bad_login');
    expect(FriendlyError.from(bad).title, 'Wrong username or password');
    expect(FriendlyError.from(await errorFor(429, 'too_many_attempts')).title, 'Too many tries');
    expect(
      FriendlyError.from(await errorFor(409, 'manager_login_unavailable')).whatToDo,
      contains('http://quiccpos-pi'),
    );
  });

  test('an older Pi has no such route', () async {
    final c = MockClient((_) async => http.Response('Method Not Allowed', 405));
    try {
      await AgentClient.pairWithManager(address: '10.0.0.5', username: 'u', password: 'p', name: 'n', client: c);
      fail('no error');
    } on AgentException catch (e) {
      expect(e.isMissingRoute, isTrue);
    }
  });
}
