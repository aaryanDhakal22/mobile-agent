import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/friendly_error.dart';
import 'package:mobile_agent/core/local_log.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/printer_models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/alert/new_order_alert.dart';
import 'package:mobile_agent/features/common/widgets.dart';
import 'package:mobile_agent/features/drivers/dispatch_flash.dart';
import 'package:mobile_agent/features/drivers/driver_fab.dart';
import 'package:mobile_agent/features/home/home_screen.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:mobile_agent/features/settings/settings_screen.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

StoredOrder _parse(String raw) => StoredOrder.fromJson(jsonDecode(raw) as Map<String, dynamic>);

/// A FloorController that never touches the network: tests push state in.
class FakeFloor extends FloorController {
  final FloorState initial;
  FakeFloor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}

  void push(FloorState s) => state = s;
}

FloorState _floorWith({bool withArrived = true}) {
  final accepted = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  (accepted['order'] as Map)['id'] = 'k-1';
  (accepted['status'] as Map)
    ..['state'] = 'accepted'
    ..['kitchen_number'] = 1100
    ..['accepted_at'] = DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String()
    ..['estimated_ready_at'] = DateTime.now().toUtc().add(const Duration(minutes: 15)).toIso8601String();
  final ready = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
  (ready['order'] as Map)['id'] = 'r-1';
  (ready['status'] as Map)
    ..['state'] = 'ready'
    ..remove('driver_id')
    ..remove('out_at');
  return const FloorState(connection: SseStatus.connected).withSnapshot(
    floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
    current: [_parse(onDeliveryJson), StoredOrder.fromJson(accepted), StoredOrder.fromJson(ready), _parse(legacyJson)],
    arrived: withArrived ? [_parse(arrivedPickupJson)] : const [],
    drivers: (jsonDecode(driversJson) as List).cast<Map<String, dynamic>>().map(Driver.fromJson).toList(),
    at: DateTime.now(),
  );
}

ThemeData _theme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

Future<ProviderContainer> _container(FloorState s, {List<Shift> shifts = const []}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      floorProvider.overrideWith(() => FakeFloor(s)),
      printerStatusProvider.overrideWith(
        (ref) => Stream.value(const [
          PrinterStatus(name: 'Kitchen', ip: '192.168.1.100', up: true),
          PrinterStatus(name: 'Receipt', ip: '192.168.1.101', lastError: 'dial tcp: i/o timeout'),
        ]),
      ),
      batchesProvider.overrideWith((ref) async => const [Batch(id: 7), Batch(id: 6, orderCount: 30)]),
      driverShiftsProvider.overrideWith((ref) async => shifts),
    ],
  );
}

void main() {
  for (final size in const [Size(1280, 800), Size(960, 600)]) {
    testWidgets('every nav pane renders without layout errors at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await _container(_floorWith());
      addTearDown(c.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: _theme(), home: const HomeScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: 'Kitchen (initial)');
      expect(find.text('Erik Davis'), findsWidgets, reason: 'Kitchen is the start screen');
      expect(find.text('Arrived'), findsNothing, reason: 'no Arrived tab — new orders ring full-screen');
      expect(find.byType(DriverFab), findsOneWidget);

      for (final label in ['Deliveries', 'Drivers', 'History', 'Batch', 'Printers', 'Settings', 'Kitchen']) {
        await tester.tap(find.text(label).last);
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull, reason: '$label at $size');
      }

      await tester.tap(find.text('Settings').last);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(DriverFab), findsNothing, reason: 'no driver button on Settings');

      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('order detail renders a delivery order with timeline', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await _container(_floorWith());
    addTearDown(c.dispose);
    final so = _parse(onDeliveryJson);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: _theme(),
          home: OrderDetailScreen(orderId: so.id, initial: so),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('1104'), findsWidgets);
    expect(find.text('931 Taylor Avenue, Apt 4'), findsOneWidget);
    expect(find.text('Delivered'), findsNothing);
    expect(find.text('Maria Lopez'), findsOneWidget);
    expect(find.text('REPRINT'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in const [Size(1280, 800), Size(960, 600)]) {
    testWidgets('full-screen alert shows the oldest arrived order with prep picks at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await _container(_floorWith());
      addTearDown(c.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: _theme(),
            home: const Scaffold(body: NewOrderAlert()),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('NEW ORDER'), findsOneWidget);
      expect(find.text('Erik Davis'), findsOneWidget);
      expect(find.text('ACCEPT · 20 MIN'), findsOneWidget);
      for (final m in [10, 15, 20, 30, 45, 60]) {
        expect(find.text('$m'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('alarm provider follows the floor: rings until no order is arrived', () async {
    final c = await _container(_floorWith());
    addTearDown(c.dispose);
    expect(c.read(alarmProvider).ringing, isTrue);
    expect(c.read(alarmProvider).visible, isTrue);

    // Hiding keeps it ringing.
    c.read(alarmProvider.notifier).hide();
    expect(c.read(alarmProvider).ringing, isTrue);
    expect(c.read(alarmProvider).visible, isFalse);

    // An escalation frame brings it back, louder.
    final fake = c.read(floorProvider.notifier) as FakeFloor;
    final s = c.read(floorProvider);
    fake.push(s.copyWith(escalations: s.escalations + 1));
    expect(c.read(alarmProvider).visible, isTrue);
    expect(c.read(alarmProvider).loud, isTrue);

    // Accepting the last arrived order silences it.
    fake.push(_floorWith(withArrived: false));
    expect(c.read(alarmProvider).ringing, isFalse);
  });

  Future<ProviderContainer> pumpHome(WidgetTester tester, FloorState s, {List<Shift> shifts = const []}) async {
    tester.view.physicalSize = const Size(960, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await _container(s, shifts: shifts);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: _theme(), home: const HomeScreen()),
      ),
    );
    await tester.pump();
    return c;
  }

  testWidgets('Drivers tab: status, clock in / out, daily reset time, shifts', (tester) async {
    final shifts = (jsonDecode(shiftsJson) as List).cast<Map<String, dynamic>>().map(Shift.fromJson).toList();
    await pumpHome(tester, _floorWith(withArrived: false), shifts: shifts);
    await tester.tap(find.text('Drivers').last);
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.text('Everyone is clocked out daily at 10:00 AM (set in the agent web UI).'), findsOneWidget);
    expect(find.text('Ana · NEXT'), findsOneWidget);
    expect(find.text('CLOCK IN'), findsOneWidget, reason: 'only Lee is off');
    expect(find.text('CLOCK OUT'), findsNWidgets(3));
    expect(find.text('OFF'), findsOneWidget);
    expect(find.text('OUT'), findsOneWidget);
    expect(find.text('AVAILABLE'), findsNWidgets(2));
    expect(find.textContaining('Clocked out ·'), findsOneWidget);
    expect(find.textContaining('In since '), findsNWidgets(3));

    // Sam is out on a run: removing is refused up front, no confirm dialog.
    await tester.tap(find.byTooltip('Remove').at(2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining("Can't remove a driver who is out on a run"), findsOneWidget);
    expect(find.text('REMOVE'), findsNothing);

    await tester.tap(find.text('SHIFTS'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('Shifts — last 7 days'), findsOneWidget);
    expect(find.text('ON SHIFT'), findsOneWidget);
    expect(find.text('AUTO OUT'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Deliveries: the driver picker offers only clocked-in, available drivers', (tester) async {
    await pumpHome(tester, _floorWith(withArrived: false));
    await tester.tap(find.text('Deliveries').last);
    await tester.pump(const Duration(milliseconds: 600));
    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).toList();
    expect(chips, hasLength(2));
    expect(find.widgetWithText(ChoiceChip, 'Ana · NEXT'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Joe'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Lee'), findsNothing, reason: 'clocked out');
    expect(find.widgetWithText(ChoiceChip, 'Sam'), findsNothing, reason: 'out on a run');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Deliveries: nobody clocked in → points to the Drivers tab', (tester) async {
    final s = _floorWith(withArrived: false);
    final allOff = s.drivers.map((d) => Driver(id: d.id, name: d.name, status: DriverStatus.off)).toList();
    await pumpHome(tester, s.copyWith(drivers: allOff));
    await tester.tap(find.text('Deliveries').last);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('No driver clocked in — clock one in on the Drivers tab.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('driver name flash', () {
    DriverDispatch samRun() {
      final sam = (jsonDecode(driversJson) as List).cast<Map<String, dynamic>>().map(Driver.fromJson).toList()[2];
      return DriverDispatch(driver: sam, orders: [_parse(onDeliveryJson)]);
    }

    Future<(ProviderContainer, FakeFloor)> pumpHost(WidgetTester tester, FloorState s) async {
      tester.view.physicalSize = const Size(960, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await _container(s);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: _theme(),
            builder: (context, child) => AlarmHost(child: child!),
            home: const Scaffold(body: Center(child: Text('floor underneath'))),
          ),
        ),
      );
      await tester.pump();
      return (c, c.read(floorProvider.notifier) as FakeFloor);
    }

    testWidgets('shows the name + kitchen numbers over every route and auto-dismisses', (tester) async {
      final (c, fake) = await pumpHost(tester, _floorWith(withArrived: false));
      expect(find.text('OUT NOW'), findsNothing);

      fake.push(c.read(floorProvider).withDispatch(samRun()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('OUT NOW'), findsOneWidget);
      expect(find.text('Sam'), findsOneWidget);
      expect(find.text('1104'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The same dispatch again (SSE echo) doesn't restart anything; after
      // the hold it fades away.
      fake.push(c.read(floorProvider).withDispatch(samRun()));
      await tester.pump(kDispatchFlashHold);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('OUT NOW'), findsNothing);
      expect(find.text('floor underneath'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a tap dismisses it', (tester) async {
      final (c, fake) = await pumpHost(tester, _floorWith(withArrived: false));
      fake.push(c.read(floorProvider).withDispatch(samRun()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Sam'), findsOneWidget);
      await tester.tap(find.text('Sam'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('OUT NOW'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the new-order alert sits above the flash', (tester) async {
      // The ringing alarm drives audioplayers; answer its platform calls.
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final ch in const [
        'xyz.luan/audioplayers',
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers/events/quicc-new-order',
        'xyz.luan/audioplayers.global/events',
      ]) {
        messenger.setMockMethodCallHandler(MethodChannel(ch), (call) async => null);
        addTearDown(() => messenger.setMockMethodCallHandler(MethodChannel(ch), null));
      }
      final (c, fake) = await pumpHost(tester, _floorWith());
      expect(c.read(alarmProvider).visible, isTrue);
      fake.push(c.read(floorProvider).withDispatch(samRun()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('NEW ORDER'), findsOneWidget);
      expect(find.text('OUT NOW'), findsOneWidget, reason: 'flash is up, underneath');

      final stack = tester.widget<Stack>(
        find.descendant(of: find.byType(AlarmHost), matching: find.byType(Stack)).first,
      );
      final order = stack.children.map((w) => (w as Positioned).child.runtimeType).toList();
      expect(order.indexOf(DispatchFlash), lessThan(order.indexOf(NewOrderAlert)));

      // A tap lands on the alert, not the flash.
      await tester.tapAt(const Offset(480, 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('OUT NOW'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Settings', () {
    const paired = <String, Object>{
      'agent_address': 'http://192.168.1.219:8080',
      'device_key': 'qagt_test',
      'device_name': 'Counter tablet',
      'device_id': 'dev-1',
    };

    /// Settings on its own, paired, with the agent answered by [handler].
    Future<ProviderContainer> pumpSettings(
      WidgetTester tester, {
      Future<http.Response> Function(http.Request req)? handler,
      Future<AgentProbe> Function(String address)? probe,
    }) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(paired);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          floorProvider.overrideWith(() => FakeFloor(_floorWith(withArrived: false))),
          agentClientProvider.overrideWith(
            (ref) => AgentClient(
              baseUrl: '192.168.1.219',
              deviceKey: 'qagt_test',
              client: MockClient(handler ?? (_) async => http.Response('{"error":"nope"}', 500)),
            ),
          ),
          if (probe != null) piProbeProvider.overrideWithValue(probe),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: _theme(),
            home: const Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      return c;
    }

    testWidgets('renders every card', (tester) async {
      await pumpSettings(tester);
      expect(tester.takeException(), isNull);
      for (final t in ['THE PI', 'THIS TABLET', 'ORDER CHIME', 'CHECKS & TESTS', 'LIGHT OR DARK']) {
        await tester.scrollUntilVisible(find.text(t), 200, scrollable: find.byType(Scrollable).first);
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('Counter tablet'), findsOneWidget);
      expect(find.text('PREVIEW'), findsOneWidget);
      for (final b in ['RENAME', 'PAIR ANOTHER TABLET', 'UNPAIR', 'TABLET CHECKS', 'TEST RING', 'TEST PRINT']) {
        expect(find.text(b), findsOneWidget, reason: b);
      }
      expect(find.text('System'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('rename: asks the Pi, then remembers the new name', (tester) async {
      http.Request? sent;
      final c = await pumpSettings(
        tester,
        handler: (req) async {
          sent = req;
          return http.Response(jsonEncode({'name': 'Front counter'}), 200);
        },
      );
      await tester.tap(find.text('RENAME'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Front counter');
      await tester.tap(find.widgetWithText(FilledButton, 'RENAME'));
      await tester.pumpAndSettle();

      expect(sent?.method, 'PATCH');
      expect(sent?.url.path, '/api/device/self');
      expect(jsonDecode(sent!.body), {'name': 'Front counter'});
      expect(c.read(pairingProvider)?.deviceName, 'Front counter');
      expect(c.read(pairingProvider)?.deviceKey, 'qagt_test', reason: 'still paired');
      expect(c.read(sharedPrefsProvider).getString('device_name'), 'Front counter');
      expect(find.text('Front counter'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('rename on an old Pi says so in plain words', (tester) async {
      await pumpSettings(tester, handler: (_) async => http.Response('404 page not found', 404));
      await tester.tap(find.text('RENAME'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Front counter');
      await tester.tap(find.widgetWithText(FilledButton, 'RENAME'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Not renamed'), findsOneWidget);
      expect(find.textContaining('The Pi needs an update for this'), findsOneWidget);
      expect(find.text('DETAILS'), findsOneWidget);
      expect(find.textContaining('404 page not found'), findsNothing, reason: 'raw text stays behind DETAILS');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the address is checked as you type', (tester) async {
      final asked = <String>[];
      await pumpSettings(
        tester,
        probe: (a) async {
          asked.add(a);
          if (a.endsWith('.50')) throw const AgentException("Can't reach the Pi");
          return const AgentProbe(state: 'ready', linkAvailable: false, storeName: "Lombardi's");
        },
      );
      final field = find.byType(TextField).first;
      await tester.enterText(field, '192.168.1.5');
      await tester.enterText(field, '192.168.1.50');
      await tester.pump();
      expect(find.text('Looking for the Pi…'), findsOneWidget);
      await tester.pump(kAddressCheckDelay);
      await tester.pump();
      expect(asked, ['192.168.1.50'], reason: 'debounced: only the last text is checked');
      expect(find.textContaining('Nothing there ✗'), findsOneWidget);

      await tester.enterText(field, '192.168.1.219');
      await tester.pump(kAddressCheckDelay);
      await tester.pump();
      expect(find.text("Found the Pi ✓ — Lombardi's"), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pair another tablet shows the code big with the steps', (tester) async {
      await pumpSettings(
        tester,
        handler: (req) async => http.Response(
          jsonEncode({
            'code': '482913',
            'expires_at': DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
          }),
          200,
        ),
      );
      await tester.tap(find.text('PAIR ANOTHER TABLET'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('482913'), findsOneWidget);
      expect(find.textContaining('Expires in 4:'), findsOneWidget);
      expect(find.textContaining('I have a code'), findsOneWidget);
      await tester.tap(find.text('DONE'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an (i) opens its explanation', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.byTooltip('What is this?').first);
      await tester.pumpAndSettle();
      expect(find.text("The Pi's address"), findsOneWidget);
      await tester.tap(find.text('GOT IT'));
      await tester.pumpAndSettle();
      expect(find.text("The Pi's address"), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the theme picker saves the choice', (tester) async {
      final c = await pumpSettings(tester);
      expect(c.read(themeModeProvider), ThemeMode.dark, reason: 'dark by default');
      await tester.scrollUntilVisible(find.text('Light'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Light'));
      await tester.pump();
      expect(c.read(themeModeProvider), ThemeMode.light);
      expect(c.read(sharedPrefsProvider).getString('theme_mode'), 'light');
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('the theme is remembered across restarts', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer boot() {
      final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      return c;
    }

    final first = boot();
    expect(first.read(themeModeProvider), ThemeMode.dark);
    first.read(themeModeProvider.notifier).set(ThemeMode.system);
    expect(boot().read(themeModeProvider), ThemeMode.system);

    // The nav-rail logo's `.notifier.state =` saves too.
    final second = boot();
    second.read(themeModeProvider.notifier).state = ThemeMode.light;
    expect(boot().read(themeModeProvider), ThemeMode.light);
    second.read(themeModeProvider.notifier).toggle();
    expect(boot().read(themeModeProvider), ThemeMode.dark);
  });

  group('friendly errors', () {
    Future<ProviderContainer> pumpBody(WidgetTester tester, Widget body) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: _theme(),
            home: Scaffold(body: body),
          ),
        ),
      );
      await tester.pump();
      return c;
    }

    const refused = AgentException("Can't reach the Pi", cause: SocketException('Connection refused (errno 111)'));

    testWidgets('an inline error shows the title + what to do, details behind a link, and logs them', (tester) async {
      final c = await pumpBody(tester, InlineError.from(refused, lead: 'Reports not loaded', area: 'batch'));
      expect(find.text('Reports not loaded'), findsOneWidget);
      expect(find.textContaining("Can't reach the Pi. Check the tablet is on the store Wi-Fi"), findsOneWidget);
      expect(find.textContaining('errno 111'), findsNothing);
      expect(find.text('FIX IT'), findsOneWidget, reason: 'it names the Pi-unreachable guide');

      await tester.tap(find.text('Details'));
      await tester.pump();
      expect(find.textContaining('errno 111'), findsOneWidget);
      expect(c.read(localLogProvider).lines.single, contains('W batch:'));
      expect(c.read(localLogProvider).lines.single, contains('errno 111'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('FIX IT goes through openGuideHook', (tester) async {
      final opened = <GuideId>[];
      final before = openGuideHook;
      openGuideHook = (_, g) => opened.add(g);
      addTearDown(() => openGuideHook = before);

      await pumpBody(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => toastError(
              context,
              const AgentException('nothing printed', statusCode: 502, code: 'nothing_printed'),
              lead: 'Not reprinted',
            ),
            child: const Text('go'),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Not reprinted'), findsOneWidget);
      expect(find.textContaining('Nothing printed. Check the printers'), findsOneWidget);
      await tester.tap(find.text('FIX IT'));
      expect(opened, [GuideId.printer]);

      await tester.tap(find.text('DETAILS'));
      await tester.pumpAndSettle();
      expect(find.textContaining('nothing_printed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
