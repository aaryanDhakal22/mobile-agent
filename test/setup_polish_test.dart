// Fixes from the 2026-10-21 staging install rehearsal (Quibase 1.3.2).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/discovery.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/format.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/setup/setup_widgets.dart';
import 'package:mobile_agent/features/setup/steps/drivers_step.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

ThemeData _theme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

/// Clocking in moves the driver to the back of the queue, like the agent.
class _QueueFloor extends FloorController {
  final FloorState initial;
  _QueueFloor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}

  @override
  Future<Driver> clockIn(String id) async {
    final d = state.drivers.firstWhere((x) => x.id == id);
    final on = Driver(id: d.id, name: d.name, status: DriverStatus.available);
    state = state.copyWith(drivers: [...state.drivers.where((x) => x.id != id), on]);
    return on;
  }
}

void main() {
  group('item size', () {
    test('"Serving" is the vendor placeholder for a single-size item', () {
      expect(const LineItem(name: 'Turkey Club', size: 'Serving').displaySize, '');
      expect(const LineItem(name: 'Turkey Club', size: ' serving ').displaySize, '');
      expect(const LineItem(name: 'Wings', size: 'Serving (2 Piece)').displaySize, '2 Piece');
      expect(const LineItem(name: 'Pizza', size: '14 Large').displaySize, '14 Large');
      expect(const LineItem(name: 'Pizza').displaySize, '');
    });

    test('itemTitle leaves the placeholder out', () {
      expect(itemTitle(const LineItem(name: 'Turkey Club Sandwich', size: 'Serving')), 'Turkey Club Sandwich');
      expect(itemTitle(const LineItem(name: 'Wings', size: 'Serving (6 Piece)', quantity: 2)), '2× 6 Piece Wings');
      expect(itemTitle(const LineItem(name: 'Cheese Pizza', size: '12 Medium')), '12 Medium Cheese Pizza');
    });
  });

  group('find the Pi lists each Pi once', () {
    const byIp = DiscoveredPi(address: 'http://192.168.1.219:8080', host: 'quiccpos-pi');
    const byName = DiscoveredPi(
      address: 'http://quiccpos-pi:8080',
      host: 'quiccpos-pi',
      via: 'hostname',
      resolvedIps: ['192.168.1.219'],
    );

    test('the hostname entry is dropped when its IP was found too', () {
      expect(dedupePis([byName, byIp]), [byIp]);
      expect(dedupePis([byIp, byName]), [byIp]);
    });

    test('the hostname entry stays when it is the only way the Pi was found', () {
      expect(dedupePis([byName]), [byName]);
    });

    test('another Pi with the same hostname is not merged', () {
      const other = DiscoveredPi(address: 'http://192.168.1.50:8080', host: 'quiccpos-pi');
      expect(dedupePis([other, byName]), [other, byName]);
    });
  });

  testWidgets('with the keyboard up a step drops its subtitle', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: const Scaffold(
          body: StepLayout(title: 'This Pi is new', subtitle: 'Sign in with the store manager login.', body: SizedBox()),
        ),
      ),
    );
    expect(find.text('Sign in with the store manager login.'), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pumpAndSettle();
    expect(find.text('Sign in with the store manager login.'), findsNothing);
    expect(find.text('This Pi is new'), findsOneWidget);
  });

  testWidgets('clocking a driver in does not move the rows under the finger', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const off = DriverStatus.off;
    final c = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        floorProvider.overrideWith(
          () => _QueueFloor(
            const FloorState(
              drivers: [
                Driver(id: 'a', name: 'Abdul', status: off),
                Driver(id: 'c', name: 'Carlos', status: off),
                Driver(id: 'd', name: 'Deep', status: off),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: _theme(), home: const Scaffold(body: DriversPanel())),
      ),
    );

    List<String> shown() {
      final names = ['Abdul', 'Carlos', 'Deep'];
      names.sort((x, y) => tester.getTopLeft(find.text(x)).dy.compareTo(tester.getTopLeft(find.text(y)).dy));
      return names;
    }

    expect(shown(), ['Abdul', 'Carlos', 'Deep']);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(c.read(floorProvider).drivers.map((d) => d.name), ['Carlos', 'Deep', 'Abdul'], reason: 'the queue moved');
    expect(shown(), ['Abdul', 'Carlos', 'Deep'], reason: 'the list did not');
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(c.read(floorProvider).drivers.firstWhere((d) => d.id == 'c').status, DriverStatus.available);
    expect(shown(), ['Abdul', 'Carlos', 'Deep']);
  });
}
