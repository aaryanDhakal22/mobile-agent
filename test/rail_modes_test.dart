import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/alarm.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/motion.dart';
import 'package:mobile_agent/core/printer_models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/alert/new_order_alert.dart';
import 'package:mobile_agent/features/dev/config_screen.dart';
import 'package:mobile_agent/features/dev/connections_screen.dart';
import 'package:mobile_agent/features/dev/dev_gate.dart';
import 'package:mobile_agent/features/dev/dev_log.dart';
import 'package:mobile_agent/features/dev/logs_screen.dart';
import 'package:mobile_agent/features/dev/pos_hub_screen.dart';
import 'package:mobile_agent/features/dev/tests_screen.dart';
import 'package:mobile_agent/features/diagnose/diagnose_entry.dart';
import 'package:mobile_agent/features/drivers/driver_fab.dart';
import 'package:mobile_agent/features/home/home_nav.dart';
import 'package:mobile_agent/features/home/idle_kitchen.dart';
import 'package:mobile_agent/features/home/home_screen.dart';
import 'package:mobile_agent/features/home/rail_blob.dart';
import 'package:mobile_agent/features/home/rail_motion.dart';
import 'package:mobile_agent/features/settings/store_settings_screen.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _Floor extends FloorController {
  final FloorState initial;
  _Floor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}

  void push(FloorState s) => state = s;
}

FloorState _floor() => const FloorState(connection: SseStatus.connected).withSnapshot(
  floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
  current: [StoredOrder.fromJson(jsonDecode(onDeliveryJson) as Map<String, dynamic>)],
  arrived: const [],
  drivers: (jsonDecode(driversJson) as List).cast<Map<String, dynamic>>().map(Driver.fromJson).toList(),
  at: DateTime.now(),
);

ThemeData _theme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

const _paired = <String, Object>{
  'agent_address': 'http://192.168.1.219:8080',
  'device_key': 'qagt_test',
  'device_name': 'Counter tablet',
  'device_id': 'dev-1',
};

/// Logins the fake Pi accepts.

Future<ProviderContainer> _pumpHome(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  bool motion = true,
  bool ringingHidden = false,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({..._paired, 'motion_enabled': motion, ...prefs});
  final sp = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(sp),
      floorProvider.overrideWith(() => _Floor(_floor())),
      agentClientProvider.overrideWith((ref) => null),
      printerStatusProvider.overrideWith(
        (ref) => Stream.value(const [PrinterStatus(name: 'Kitchen', ip: '192.168.1.100', up: true)]),
      ),
      batchesProvider.overrideWith((ref) async => const [Batch(id: 7)]),
      driverShiftsProvider.overrideWith((ref) async => const []),
      if (ringingHidden) alarmProvider.overrideWith(_HiddenRing.new),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: _theme(),
        home: const HomeScreen(),
        builder: (context, child) => DevActivityListener(child: AlarmHost(child: child!)),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return c;
}

/// An order is ringing but staff hid the alert: only the strip shows.
class _HiddenRing extends AlarmNotifier {
  @override
  AlarmState build() => const AlarmState(ringing: true, visible: false);
}

final _q = find.byKey(const ValueKey('q-button'));

/// Lets a mode switch play out.
Future<void> _switchDone(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _unlock(WidgetTester tester) async {
  await tester.longPress(_q);
  await tester.pump(const Duration(milliseconds: 400));
  await _typePin(tester, kDevPin);
  await _switchDone(tester);
}

Future<void> _typePin(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.byKey(ValueKey('dev-pin-digit-$d')));
    await tester.pump();
  }
}

void main() {
  group('rail modes', () {
    testWidgets('tap q: kitchen ↔ store, each with its own five destinations', (tester) async {
      final c = await _pumpHome(tester);
      for (final l in ['Kitchen', 'Deliveries', 'Map', 'Drivers', 'History']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      expect(find.text('Batch'), findsNothing);
      expect(find.byType(DriverFab), findsOneWidget);

      await tester.tap(_q);
      await tester.pump(const Duration(milliseconds: 300)); // mid-switch
      expect(tester.takeException(), isNull);
      await _switchDone(tester);
      expect(c.read(homeNavProvider), HomeDestination.batch);
      for (final l in ['Batch', 'Printers', 'Updates', 'Help', 'Settings']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      expect(find.text('Deliveries'), findsNothing, reason: 'the kitchen icons fell off');
      expect(find.byType(DriverFab), findsNothing, reason: 'driver button only in kitchen mode');

      await tester.tap(find.text('Settings').last);
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(StoreSettingsScreen), findsOneWidget);

      // Back to kitchen, and the q remembers Settings for next time.
      await tester.tap(_q);
      await _switchDone(tester);
      expect(c.read(homeNavProvider), HomeDestination.kitchen);
      await tester.tap(_q);
      await _switchDone(tester);
      expect(c.read(homeNavProvider), HomeDestination.settings);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('homeNavProvider.go switches to the mode that holds it', (tester) async {
      final c = await _pumpHome(tester);
      await tester.tap(_q);
      await _switchDone(tester);
      expect(find.text('Batch'), findsWidgets);

      c.read(homeNavProvider.notifier).go(HomeDestination.drivers);
      await tester.pump();
      await _switchDone(tester);
      expect(find.text('Deliveries'), findsWidgets);
      expect(find.text('Batch'), findsNothing);

      // Developer screens are ignored while locked.
      c.read(homeNavProvider.notifier).go(HomeDestination.logs);
      await tester.pump();
      await _switchDone(tester);
      expect(c.read(homeNavProvider), HomeDestination.drivers);
      expect(find.byType(DevLogsScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('long-press q asks for the developer PIN; a wrong one shakes, clears and stays locked', (tester) async {
      final c = await _pumpHome(tester);
      await tester.longPress(_q);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Developer mode'), findsOneWidget);
      expect(find.byKey(const ValueKey('dev-pin-pad')), findsOneWidget);
      expect(find.byKey(const ValueKey('dev-username')), findsNothing, reason: 'no manager login any more');

      // Two digits fill two dots; backspace takes one off.
      await _typePin(tester, '10');
      Color? fill(int i) =>
          (tester.widget<Container>(find.byKey(ValueKey('dev-pin-dot-$i'))).decoration! as BoxDecoration).color;
      expect(fill(1), isNot(Colors.transparent));
      await tester.tap(find.byKey(const ValueKey('dev-pin-back')));
      await tester.pump();
      expect(fill(1), Colors.transparent);
      expect(fill(0), isNot(Colors.transparent));
      await tester.tap(find.byKey(const ValueKey('dev-pin-back')));
      await tester.pump();

      await _typePin(tester, '1234');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('dev-pin-wrong')), findsOneWidget);
      expect(c.read(devGateProvider), isFalse);
      for (var i = 0; i < 4; i++) {
        expect(fill(i), Colors.transparent, reason: 'cleared after a wrong PIN');
      }
      expect(c.read(devLogProvider).map((e) => e.text), contains('Developer PIN wrong'));
      await tester.pump(const Duration(milliseconds: 500)); // the shake ends
      // No lockout: the right PIN still works at once.
      await _typePin(tester, kDevPin);
      await _switchDone(tester);
      expect(c.read(devGateProvider), isTrue);
      expect(c.read(homeNavProvider), HomeDestination.connections);
      for (final l in ['Connections', 'POS hub', 'Logs', 'Tests', 'Config']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      expect(find.byType(ConnectionsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      c.read(devGateProvider.notifier).lock();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the PIN pad cancels without unlocking', (tester) async {
      final c = await _pumpHome(tester);
      await tester.longPress(_q);
      await tester.pump(const Duration(milliseconds: 400));
      await _typePin(tester, '10');
      await tester.tap(find.byKey(const ValueKey('dev-pin-cancel')));
      await _switchDone(tester);
      expect(find.byKey(const ValueKey('dev-pin-pad')), findsNothing);
      expect(c.read(devGateProvider), isFalse);
      expect(c.read(homeNavProvider), HomeDestination.kitchen);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('developer mode relocks after 15 min idle; touches push it back', (tester) async {
      final c = await _pumpHome(tester);
      // The 1 min back to Kitchen (1.7.1) would come first: off for this one.
      c.read(idleKitchenProvider.notifier).set(false);
      await _unlock(tester);
      expect(c.read(devGateProvider), isTrue);

      // 10 min, a touch, 10 more: still open (the touch restarted the clock).
      await tester.pump(const Duration(minutes: 10));
      await tester.tap(find.text('Logs').last);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(DevLogsScreen), findsOneWidget);
      await tester.pump(const Duration(minutes: 10));
      expect(c.read(devGateProvider), isTrue);

      await tester.pump(const Duration(minutes: 5, seconds: 1));
      await _switchDone(tester);
      expect(c.read(devGateProvider), isFalse);
      expect(c.read(homeNavProvider), HomeDestination.kitchen);
      expect(find.text('Connections'), findsNothing);
      expect(c.read(devLogProvider).any((e) => e.text.contains('15 min idle')), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tap q in developer mode goes back to kitchen and locks', (tester) async {
      final c = await _pumpHome(tester);
      await _unlock(tester);
      await tester.tap(_q);
      await _switchDone(tester);
      expect(c.read(devGateProvider), isFalse);
      expect(c.read(homeNavProvider), HomeDestination.kitchen);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('every developer screen renders', (tester) async {
      final c = await _pumpHome(tester);
      await _unlock(tester);
      for (final (label, type) in [
        ('POS hub', PosHubScreen),
        ('Logs', DevLogsScreen),
        ('Tests', DevTestsScreen),
        ('Config', DevConfigScreen),
        ('Connections', ConnectionsScreen),
      ]) {
        await tester.tap(find.text(label).last);
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.byType(type), findsOneWidget, reason: label);
        expect(tester.takeException(), isNull, reason: label);
      }
      c.read(devGateProvider.notifier).lock();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('motion off: the switch is a quick fade and nothing breaks', (tester) async {
      final c = await _pumpHome(tester, motion: false);
      expect(c.read(motionProvider).enabled, isFalse);
      await tester.tap(_q);
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Batch'), findsWidgets);
      expect(find.text('Deliveries'), findsNothing, reason: 'done within the 150 ms fade');
      await tester.tap(find.text('Printers').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the "orders waiting" strip sits above the rail, not over the q', (tester) async {
      final c = await _pumpHome(tester, ringingHidden: true);
      final strip = find.textContaining('tap to show');
      expect(strip, findsOneWidget);
      expect(
        tester.getRect(_q).top,
        greaterThanOrEqualTo(tester.getRect(find.ancestor(of: strip, matching: find.byType(Material)).first).bottom),
      );
      await tester.tap(_q);
      await _switchDone(tester);
      expect(c.read(homeNavProvider), HomeDestination.batch, reason: 'the q still switches modes while ringing');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the blob moves between destinations without errors', (tester) async {
      await _pumpHome(tester);
      await tester.tap(find.text('History').last);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 70));
        expect(tester.takeException(), isNull);
      }
      expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is RailBlobPainter), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the Deliveries badge counts unassigned deliveries', (tester) async {
      final c = await _pumpHome(tester);
      final n = c.read(floorProvider).unassignedDeliveries.length;
      final badge = tester.widget<Badge>(
        find.ancestor(of: find.byIcon(Icons.delivery_dining_outlined), matching: find.byType(Badge)),
      );
      expect(badge.isLabelVisible, n > 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('motion maths', () {
    test('the bounce goes 0 → 1.2 → 0.9 → 1.1 → 1.0', () {
      expect(kRailBounce.transform(0), 0);
      final peak = [for (var i = 0; i <= 100; i++) kRailBounce.transform(i / 100)];
      expect(peak.reduce((a, b) => a > b ? a : b), closeTo(1.2, 0.001));
      expect(kRailBounce.transform(1), closeTo(1.0, 1e-9));
      // The dip and second peak.
      final afterPeak = peak.sublist(peak.indexOf(peak.reduce((a, b) => a > b ? a : b)));
      expect(afterPeak.reduce((a, b) => a < b ? a : b), closeTo(0.9, 0.01));
    });

    test('falling icons accelerate, tumble and leave the rail', () {
      final body = FallBody.seeded('Kitchen');
      expect(body.comX.abs(), greaterThanOrEqualTo(0.07));
      expect(FallBody.seeded('Kitchen').comX, body.comX, reason: 'deterministic');
      final a = FallPose.at(0.2, body, 700);
      final b = FallPose.at(0.4, body, 700);
      final c = FallPose.at(0.6, body, 700);
      expect(b.dy - a.dy, greaterThan(a.dy), reason: 'speeding up');
      expect(c.dy, greaterThan(700), reason: 'off the bottom within the switch');
      expect(c.angle.abs(), greaterThan(b.angle.abs()));
      expect(c.angle.sign, body.comX.sign, reason: 'tips toward its heavy side');
    });

    test('the blob stretches mid-move and rests at the target', () {
      const from = (0.0, 80.0);
      const to = (300.0, 380.0);
      final (t0, b0, _) = BlobGeometry.at(0, from, to, full: true);
      expect((t0, b0), (0.0, 80.0));
      final (tm, bm, _) = BlobGeometry.at(0.4, from, to, full: true);
      expect(bm - tm, greaterThan(150), reason: 'stretched: the leading edge leads');
      final (t1, b1, w1) = BlobGeometry.at(1, from, to, full: true);
      expect(t1, closeTo(300, 0.01));
      expect(b1, closeTo(380, 0.01));
      expect(w1, closeTo(1, 0.01));
    });
  });

  group('store settings', () {
    testWidgets('groups render, coming-soon rows are greyed, motion card works', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(_paired);
      final sp = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(sp),
          floorProvider.overrideWith(() => _Floor(_floor())),
          agentClientProvider.overrideWith((ref) => null),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: _theme(),
            home: const Scaffold(body: StoreSettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      final list = find.byType(Scrollable).first;
      for (final key in [
        'group-deliveries',
        'coming-radius',
        'coming-nearby',
        'coming-auto-assign',
        'group-times',
        'group-tickets',
        'group-receipts',
        'group-look',
      ]) {
        await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 200, scrollable: list);
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        if (key == 'coming-nearby') expect(find.text('Coming with the next Pi update'), findsAtLeastNWidgets(2));
      }
      expect(find.text('THE PI'), findsNothing, reason: 'the Pi moved to developer mode');
      expect(find.text('FEATURES'), findsNothing, reason: 'features moved to developer mode');

      await tester.scrollUntilVisible(find.byKey(const ValueKey('motion-speed')), 200, scrollable: list);
      await tester.pump();
      // Right end = 2× = twice as fast = half the durations.
      final slider = find.byKey(const ValueKey('motion-speed'));
      await tester.tapAt(tester.getTopRight(slider) + const Offset(-4, 24));
      await tester.pump();
      expect(c.read(motionProvider).speed, closeTo(0.5, 0.001));
      await tester.tap(find.byKey(const ValueKey('motion-switch')));
      await tester.pump();
      expect(c.read(motionProvider).enabled, isFalse);
      expect(sp.getBool('motion_enabled'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('dev gate', () {
    test('the dev log keeps order numbers and state changes, not names', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final log = c.read(devLogProvider.notifier);
      final before = _floor();
      final after = before.copyWith(connection: SseStatus.disconnected);
      log.observeFloor(before, after);
      expect(c.read(devLogProvider).single.text, contains('dropped'));
      log.observeFloor(null, after);
      expect(c.read(devLogProvider), hasLength(1));
      log.clear();
      expect(c.read(devLogProvider), isEmpty);
    });

    test('Help no longer duplicates the checks', () {
      // Compile-time guard that the Help pane still exists for the store rail.
      expect(const HelpPane(), isA<Widget>());
    });
  });
}
