// Quibase 1.9.1 (with agent 2.3.7): a driver's phone (Pushover device name)
// in the driver dialog with SEND TEST, and a red island pill when a SEND
// OUT's route didn't reach the phone (SSE `driver.route` ok:false).
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
import 'package:mobile_agent/features/common/island.dart';
import 'package:mobile_agent/features/drivers/drivers_pane.dart';
import 'package:mobile_agent/features/integration/integration_alerts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'delivery_fixtures.dart';
import 'fixtures.dart';

const _paired = {'agent_address': 'http://10.0.0.5:8080', 'device_key': 'qagt_k', 'device_name': 'Counter'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// A Pi answering [handler]; keeps every request.
class _Pi {
  final List<http.Request> requests = [];
  http.Response Function(http.Request req) handler;
  _Pi([http.Response Function(http.Request req)? handler]) : handler = handler ?? ((_) => _json(const {}));

  AgentClient client() => AgentClient(
    baseUrl: 'http://10.0.0.5:8080',
    deviceKey: 'qagt_k',
    client: MockClient((req) async {
      requests.add(req);
      return handler(req);
    }),
  );

  List<String> get paths => [for (final r in requests) '${r.method} ${r.url.path}'];
  Map<String, dynamic> bodyOf(String path) =>
      jsonDecode(requests.lastWhere((r) => '${r.method} ${r.url.path}' == path).body) as Map<String, dynamic>;
}

class _FakeFloor extends FloorController {
  final FloorState initial;
  _FakeFloor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}
}

FloorState _floorState(List<Driver> drivers) => const FloorState(connection: SseStatus.connected).withSnapshot(
  floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
  current: const [],
  arrived: const [],
  drivers: drivers,
  at: DateTime.utc(2026, 10, 27, 18),
);

/// The Drivers screen under the island (as in the app), over [pi].
Future<ProviderContainer> _pump(WidgetTester tester, _Pi pi, List<Driver> drivers) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(_paired);
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      agentClientProvider.overrideWithValue(pi.client()),
      floorProvider.overrideWith(() => _FakeFloor(_floorState(drivers))),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: darkTheme(),
        home: const IslandHost(child: Scaffold(body: DriversPane())),
      ),
    ),
  );
  await _settle(tester);
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Unmounts and lets the pills' timers finish.
Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 10));
}

const _abdul = Driver(id: 'd-abdul', name: 'Abdul', status: DriverStatus.off, pushoverDevice: 'abdul');
const _ana = Driver(id: 'd-ana', name: 'Ana', status: DriverStatus.off);

final _device = find.byKey(const ValueKey('driver-pushover-device'));
final _sendTest = find.byKey(const ValueKey('driver-send-test'));

bool _testEnabled(WidgetTester tester) => tester.widget<ButtonStyleButton>(_sendTest).onPressed != null;

SseEvent _route(Map<String, Object?> data) => SseEvent('driver.route', jsonEncode(data));

void main() {
  group('Driver.pushoverDevice', () {
    test('parse, serialize and read back', () {
      final d = Driver.fromJson({'id': 'd-1', 'name': 'Abdul', 'status': 'off', 'pushover_device': ' abdul '});
      expect(d.pushoverDevice, 'abdul');
      final back = Driver.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);
      expect(back.pushoverDevice, 'abdul');
      expect(back.id, 'd-1');
      expect(back.name, 'Abdul');
      expect(back.status, DriverStatus.off);
    });

    test('missing (an older Pi, or none set) → "" and left out', () {
      final d = Driver.fromJson({'id': 'd-1', 'name': 'Ana'});
      expect(d.pushoverDevice, '');
      expect(d.toJson().containsKey('pushover_device'), isFalse);
      expect(Driver.fromJson(d.toJson()).pushoverDevice, '');
    });
  });

  group('pushoverDeviceError (the Pi\'s rule)', () {
    test('empty and 1–25 of [A-Za-z0-9_-] are fine', () {
      expect(pushoverDeviceError(''), isNull);
      expect(pushoverDeviceError('   '), isNull);
      expect(pushoverDeviceError('abdul'), isNull);
      expect(pushoverDeviceError('Abdul_Phone-2'), isNull);
      expect(pushoverDeviceError('a' * 25), isNull);
    });

    test('26 characters, spaces and other characters are not', () {
      expect(pushoverDeviceError('a' * 26), isNotNull);
      expect(pushoverDeviceError('abdul phone'), isNotNull);
      expect(pushoverDeviceError('abdul.phone'), isNotNull);
      expect(pushoverDeviceError('abdül'), isNotNull);
    });
  });

  group('API', () {
    test('create and patch carry pushover_device ("" clears it)', () async {
      final pi = _Pi((req) => _json({'id': 'd-9', 'name': 'Abdul', 'pushover_device': 'abdul'}));
      final c = pi.client();
      final d = await c.createDriver('Abdul', pushoverDevice: ' abdul ');
      expect(d.pushoverDevice, 'abdul');
      expect(pi.bodyOf('POST /api/drivers'), {'name': 'Abdul', 'pushover_device': 'abdul'});
      await c.createDriver('Ana', pushoverDevice: '');
      expect(pi.bodyOf('POST /api/drivers'), {'name': 'Ana'});
      await c.updateDriver('d-9', pushoverDevice: 'abdul2');
      expect(pi.bodyOf('PATCH /api/drivers/d-9'), {'pushover_device': 'abdul2'});
      await c.updateDriver('d-9', pushoverDevice: '');
      expect(pi.bodyOf('PATCH /api/drivers/d-9'), {'pushover_device': ''});
      await c.updateDriver('d-9', name: 'Abe');
      expect(pi.bodyOf('PATCH /api/drivers/d-9'), {'name': 'Abe'});
    });

    Future<RouteTest> answer(int status, Object? body) => _Pi(
      (_) => body == null ? http.Response('404 page not found', status) : _json(body, status),
    ).client().testRoute('d-abdul');

    test('testRoute: each answer of the Pi → a RouteTest and its words', () async {
      expect(await answer(200, {'ok': true}), RouteTest.sent);
      expect(await answer(409, {'error': 'no device', 'code': 'no_device'}), RouteTest.noDevice);
      expect(
        await answer(502, {'error': 'device name is invalid', 'code': 'device_not_found'}),
        RouteTest.deviceNotFound,
      );
      expect(await answer(502, {'error': 'x', 'code': 'pushover_rejected'}), RouteTest.pushoverFailed);
      expect(await answer(502, {'error': 'x', 'code': 'pushover_unreachable'}), RouteTest.pushoverFailed);
      expect(await answer(503, {'error': 'x', 'code': 'not_configured'}), RouteTest.notConfigured);
      expect(await answer(404, null), RouteTest.unsupported, reason: 'an older Pi');
      expect(await answer(405, null), RouteTest.unsupported);

      expect(RouteTest.sent.message('Abdul'), 'Test route sent to Abdul');
      expect(RouteTest.sent.ok, isTrue);
      expect(
        RouteTest.deviceNotFound.message('Abdul'),
        "Abdul's phone isn't set up in Pushover (check the device name)",
      );
      expect(RouteTest.noDevice.message('Abdul'), "Add Abdul's phone first");
      expect(RouteTest.notConfigured.message('Abdul'), "Pushover isn't set up on the Pi");
      expect(RouteTest.pushoverFailed.message('Abdul'), "Couldn't reach Pushover — try again");
      expect(RouteTest.unsupported.message('Abdul'), 'Update the Pi to send routes');
      for (final r in RouteTest.values.where((r) => r != RouteTest.sent)) {
        expect(r.ok, isFalse);
      }
    });

    test('testRoute: anything else throws (and never unpairs)', () async {
      var revoked = false;
      final c = AgentClient(
        baseUrl: 'http://10.0.0.5:8080',
        deviceKey: 'qagt_k',
        client: MockClient((_) async => _json({'error': 'driver not found', 'code': 'driver_not_found'}, 404)),
        onDeviceRevoked: () => revoked = true,
      );
      await expectLater(c.testRoute('d-x'), throwsA(isA<AgentException>()));
      final c2 = AgentClient(
        baseUrl: 'http://10.0.0.5:8080',
        deviceKey: 'qagt_k',
        client: MockClient((_) async => _json({'error': 'device required', 'code': 'device_required'}, 401)),
        onDeviceRevoked: () => revoked = true,
      );
      await expectLater(c2.testRoute('d-x'), throwsA(isA<AgentException>()));
      expect(revoked, isFalse);
    });
  });

  group('driver dialog', () {
    testWidgets('a bad device name shows inline and is not sent; 26 chars too; empty is fine', (tester) async {
      final pi = _Pi((req) => req.method == 'GET' ? _json(const []) : _json({'id': 'd-new', 'name': 'Bo'}));
      await _pump(tester, pi, const [_ana]);

      await tester.tap(find.text('ADD DRIVER'));
      await _settle(tester);
      expect(_device, findsOneWidget);
      expect(find.text('Phone (Pushover device)'), findsOneWidget);
      expect(_sendTest, findsNothing, reason: 'a new driver has nothing saved to test');
      await tester.enterText(find.byKey(const ValueKey('driver-name')), 'Bo');
      await tester.enterText(_device, 'bo phone');
      await _settle(tester);
      expect(find.text('Letters, numbers, - and _ only (no spaces)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('driver-save')));
      await _settle(tester);
      expect(pi.paths, isNot(contains('POST /api/drivers')));
      expect(_device, findsOneWidget, reason: 'the dialog stays open');

      await tester.enterText(_device, 'b' * 26);
      await _settle(tester);
      expect(find.text('25 characters at most'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('driver-save')));
      await _settle(tester);
      expect(pi.paths, isNot(contains('POST /api/drivers')));

      await tester.enterText(_device, 'b' * 25);
      await _settle(tester);
      expect(find.text('25 characters at most'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('driver-save')));
      await _settle(tester);
      expect(pi.bodyOf('POST /api/drivers'), {'name': 'Bo', 'pushover_device': 'b' * 25});
      await tester.pump(const Duration(seconds: 4)); // the "Bo added" pill sits over ADD DRIVER

      await tester.tap(find.text('ADD DRIVER'));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('driver-name')), 'Cy');
      await tester.tap(find.byKey(const ValueKey('driver-save')));
      await _settle(tester);
      expect(pi.bodyOf('POST /api/drivers'), {'name': 'Cy'}, reason: 'no phone is fine');
      await _done(tester);
    });

    testWidgets('edit: only a changed phone is sent, "" clears it', (tester) async {
      final pi = _Pi((req) => req.method == 'GET' ? _json([_abdul.toJson()]) : _json(const {}));
      await _pump(tester, pi, const [_abdul]);

      await tester.tap(find.byTooltip('Edit name / Driver #'));
      await _settle(tester);
      expect(find.widgetWithText(TextField, 'abdul'), findsOneWidget);
      await tester.enterText(_device, 'abdul2');
      await tester.tap(find.byKey(const ValueKey('driver-save')));
      await _settle(tester);
      expect(pi.bodyOf('PATCH /api/drivers/d-abdul'), {'pushover_device': 'abdul2'});

      await tester.tap(find.byTooltip('Edit name / Driver #'));
      await _settle(tester);
      await tester.enterText(_device, '');
      await tester.tap(find.byKey(const ValueKey('driver-save')));
      await _settle(tester);
      expect(pi.bodyOf('PATCH /api/drivers/d-abdul'), {'pushover_device': ''});
      await _done(tester);
    });

    testWidgets('SEND TEST: off without a saved phone or while it is edited; the answer in the island', (tester) async {
      var answer = _json({'ok': true});
      final pi = _Pi((req) => req.method == 'GET' ? _json([_ana.toJson(), _abdul.toJson()]) : answer);
      await _pump(tester, pi, const [_ana, _abdul]);

      // Ana has no phone saved.
      await tester.tap(find.byTooltip('Edit name / Driver #').first);
      await _settle(tester);
      expect(_sendTest, findsOneWidget);
      expect(_testEnabled(tester), isFalse);
      await tester.enterText(_device, 'ana');
      await _settle(tester);
      expect(_testEnabled(tester), isFalse, reason: 'typed, not saved');
      await tester.tap(find.text('CANCEL'));
      await _settle(tester);

      // Abdul has.
      await tester.tap(find.byTooltip('Edit name / Driver #').last);
      await _settle(tester);
      expect(_testEnabled(tester), isTrue);
      await tester.enterText(_device, 'abdul2');
      await _settle(tester);
      expect(_testEnabled(tester), isFalse, reason: 'the field no longer holds the saved phone');
      await tester.enterText(_device, 'abdul');
      await _settle(tester);
      expect(_testEnabled(tester), isTrue);

      await tester.tap(_sendTest);
      await _settle(tester);
      expect(pi.paths, contains('POST /api/drivers/d-abdul/route/test'));
      expect(find.text('Test route sent to Abdul'), findsOneWidget);

      answer = _json({'error': 'device name is invalid', 'code': 'device_not_found'}, 502);
      await tester.tap(_sendTest);
      await _settle(tester);
      expect(find.text("Abdul's phone isn't set up in Pushover (check the device name)"), findsOneWidget);

      answer = http.Response('404 page not found', 404);
      await tester.tap(_sendTest);
      await _settle(tester);
      expect(find.text('Update the Pi to send routes'), findsOneWidget);
      await _done(tester);
    });
  });

  group('SSE driver.route', () {
    test('parse; only a failure has a pill', () {
      final ok = DriverRouteSent.fromJson({'driver_id': 'd-abdul', 'driver_name': 'Abdul', 'ok': true, 'stops': 3})!;
      expect(ok.ok, isTrue);
      expect(ok.stops, 3);
      expect(ok.toToast(), isNull);
      final failed = DriverRouteSent.fromJson({
        'driver_id': 'd-abdul',
        'driver_name': 'Abdul',
        'ok': false,
        'code': 'device_not_found',
        'stops': 3,
      })!;
      expect(failed.code, 'device_not_found');
      expect(failed.toToast()!.text, "Couldn't send Abdul's route");
      expect(failed.toToast()!.severity, Severity.serious);
      expect(DriverRouteSent.fromJson({'ok': false})!.toToast()!.text, "Couldn't send the driver's route");
      expect(DriverRouteSent.fromJson('nope'), isNull);
    });

    testWidgets('ok:false → a red pill "Couldn\'t send Abdul\'s route"; ok:true → nothing', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: [floorProvider.overrideWith(() => _FakeFloor(_floorState(const [])))]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: const IslandHost(child: IntegrationIslandFeed(child: Scaffold())),
          ),
        ),
      );
      await tester.pump();
      final f = c.read(floorProvider.notifier);
      final before = c.read(floorProvider).toasts;

      f.handleEvent(_route({'driver_id': 'd-abdul', 'driver_name': 'Abdul', 'ok': true, 'stops': 3}));
      await tester.pump();
      expect(c.read(floorProvider).toasts, before);
      expect(find.byType(Icon), findsNothing, reason: 'no pill');

      f.handleEvent(
        _route({'driver_id': 'd-abdul', 'driver_name': 'Abdul', 'ok': false, 'code': 'device_not_found', 'stops': 3}),
      );
      await tester.pump();
      expect(c.read(floorProvider).toasts, before + 1);
      expect(find.text("Couldn't send Abdul's route"), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget, reason: 'an error pill');
      // Not part of the pure reducer: a refresh's replay can't show it twice.
      expect(applySseEvent(c.read(floorProvider), _route({'ok': false})).state.toasts, before + 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
