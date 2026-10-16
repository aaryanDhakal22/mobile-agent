import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/printer_models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/alert/new_order_alert.dart';
import 'package:mobile_agent/features/drivers/dispatch_flash.dart';
import 'package:mobile_agent/features/drivers/driver_fab.dart';
import 'package:mobile_agent/features/home/home_screen.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
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
}
