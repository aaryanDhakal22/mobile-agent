import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/home/pi_unreachable_banner.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';

class _StaticFloor extends FloorController {
  final FloorState initial;
  _StaticFloor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}

  void push(FloorState s) => state = s;
}

ThemeData _theme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

void main() {
  test('link posts the manager login + tablet name and returns the paired key', () async {
    late http.Request seen;
    final r = await AgentClient.link(
      address: '10.0.0.5:8080',
      username: ' lombardispizza ',
      password: 'pw',
      tabletName: 'Counter tablet',
      client: MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({
            'ok': true,
            'tenant': "Lombardi's",
            'device_id': 'd-1',
            'device_key': 'qagt_new',
            'device_name': 'Counter tablet',
            'restored': {'orders': 12, 'waiting': 2, 'drivers': 4, 'kitchen_next': 1131},
          }),
          200,
        );
      }),
    );
    expect(seen.url.toString(), 'http://10.0.0.5:8080/api/setup/link');
    expect(jsonDecode(seen.body), {'username': 'lombardispizza', 'password': 'pw', 'tablet_name': 'Counter tablet'});
    expect(r.key, 'qagt_new');
    expect(r.restoredOrders, 12);
    expect(r.waiting, 2);
    expect(r.kitchenNext, 1131);
  });

  test('link surfaces needs_internet so the screen can retry', () async {
    await expectLater(
      AgentClient.link(
        address: 'h:1',
        username: 'u',
        password: 'p',
        tabletName: 't',
        client: MockClient(
          (_) async => http.Response(jsonEncode({'error': 'no internet', 'code': 'needs_internet'}), 502),
        ),
      ),
      throwsA(isA<AgentException>().having((e) => e.code, 'code', 'needs_internet')),
    );
  });

  test('probe: only an unconfigured agent with linking is "new"', () {
    expect(AgentProbe.fromJson({'state': 'unconfigured', 'link_available': true}).isNew, isTrue);
    expect(AgentProbe.fromJson({'state': 'unconfigured'}).isNew, isFalse);
    expect(AgentProbe.fromJson({'state': 'locked', 'link_available': true}).isNew, isFalse);
  });

  testWidgets('the red banner shows only after 20 s without the Pi', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final floor = _StaticFloor(const FloorState(connection: SseStatus.connected));
    final c = ProviderContainer(overrides: [floorProvider.overrideWith(() => floor)]);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: _theme(),
          home: const Scaffold(body: PiUnreachableBanner()),
        ),
      ),
    );
    expect(find.textContaining("Can't reach the Pi"), findsNothing);

    floor.push(const FloorState(connection: SseStatus.disconnected));
    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining("Can't reach the Pi"), findsNothing, reason: 'a short blip stays quiet');
    await tester.pump(const Duration(seconds: 16));
    expect(find.textContaining("Can't reach the Pi"), findsOneWidget);

    floor.push(const FloorState(connection: SseStatus.connected));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining("Can't reach the Pi"), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
