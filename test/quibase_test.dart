import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/alert_player.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/drivers/driver_fab.dart';
import 'package:mobile_agent/features/kitchen/kitchen_pane.dart';
import 'package:mobile_agent/features/update/update_gate.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

StoredOrder accepted(String id, int kitchen, {int? etaMin}) => StoredOrder.fromJson({
  'order': {'id': id, 'source_event_id': id, 'customer': {'display_name': 'C $id'}, 'fulfillment': {'type': 'pickup'}},
  'status': {
    'state': 'accepted',
    'batch_id': 7,
    'kitchen_number': kitchen,
    'estimated_ready_at': ?(etaMin == null ? null : DateTime.utc(2026, 10, 16, 12, etaMin).toIso8601String()),
  },
});

/// Records the floor calls the driver button makes.
class RecordingFloor extends FloorController {
  final FloorState initial;
  final calls = <String>[];
  RecordingFloor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> driverReturned(String driverId) async {
    calls.add('returned:$driverId');
    ref.read(lastReturnProvider.notifier).state = LastReturn(driverId, DateTime.now());
  }

  @override
  Future<Driver> undoReturn(String driverId) async {
    calls.add('undo:$driverId');
    ref.read(lastReturnProvider.notifier).state = null;
    return state.drivers.firstWhere((d) => d.id == driverId);
  }
}

void main() {
  group('lateColor', () {
    test('green until green-till, amber halfway, red at twice', () {
      expect(lateColor(const Duration(minutes: 5), 20), QuiccColors.statusPaid);
      expect(lateColor(const Duration(minutes: 20), 20), QuiccColors.statusPaid);
      expect(lateColor(const Duration(minutes: 30), 20), QuiccColors.statusFiring);
      expect(lateColor(const Duration(minutes: 40), 20), QuiccColors.statusVoided);
      expect(lateColor(const Duration(minutes: 90), 20), QuiccColors.statusVoided);
      final mid = lateColor(const Duration(minutes: 25), 20);
      expect(mid, isNot(QuiccColors.statusPaid));
      expect(mid, isNot(QuiccColors.statusFiring));
    });
    test('a zero setting falls back to the default', () {
      expect(lateColor(const Duration(minutes: 19), 0), QuiccColors.statusPaid);
    });
  });

  test('dealIntoColumns keeps the most urgent across the top row', () {
    expect(dealIntoColumns([1, 2, 3, 4, 5], 3), [
      [1, 4],
      [2, 5],
      [3],
    ]);
    expect(dealIntoColumns([1, 2], 0), [
      [1, 2],
    ]);
  });

  test('kitchenByUrgency: earliest ready time first, no estimate last', () {
    final s = const FloorState().withSnapshot(
      floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
      current: [accepted('a', 1100, etaMin: 30), accepted('b', 1101, etaMin: 10), accepted('c', 1102), accepted('d', 1103, etaMin: 10)],
      arrived: const [],
      drivers: const [],
      at: DateTime.now(),
    );
    expect(s.kitchenByUrgency.map((o) => o.id), ['b', 'd', 'a', 'c']);
    expect(s.kitchen.map((o) => o.id), ['a', 'b', 'c', 'd'], reason: 'kitchen-number order is unchanged');
  });

  test('floor settings parse with defaults', () {
    final f = Floor.fromJson({'batch': {'id': 1}, 'green_till_minutes': 25, 'tip_tax_percent': 6.5});
    expect(f.greenTillMinutes, 25);
    expect(f.tipTaxPercent, 6.5);
    expect(Floor.fromJson({'batch': {'id': 1}}).greenTillMinutes, kDefaultGreenTillMinutes);
  });

  test('needsUpdate only for a newer release', () {
    const rel = AppRelease(versionCode: 20);
    expect(needsUpdate(10, rel), isTrue);
    expect(needsUpdate(20, rel), isFalse);
    expect(needsUpdate(null, rel), isFalse, reason: 'no platform channel (tests/desktop)');
    expect(needsUpdate(10, null), isFalse);
  });

  test('the new sounds are offered', () {
    expect(AlertSound.values.map((s) => s.label), containsAll(['Default', 'Forbidden', 'Meow', 'Polka']));
    expect(AlertSound.byName('polka'), AlertSound.polka);
  });

  testWidgets('driver button: pills for drivers out, tap = returned, hold = undo', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final initial = const FloorState(connection: SseStatus.connected).withSnapshot(
      floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
      current: const [],
      arrived: const [],
      drivers: (jsonDecode(driversJson) as List).cast<Map<String, dynamic>>().map(Driver.fromJson).toList(),
      at: DateTime.now(),
    );
    late RecordingFloor floor;
    final c = ProviderContainer(overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      floorProvider.overrideWith(() => floor = RecordingFloor(initial)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, extensions: const [QuiccPalette.dark]),
        home: const Scaffold(body: Stack(children: [Positioned.fill(child: DriverFab())])),
      ),
    ));
    expect(find.text('1 out'), findsOneWidget, reason: 'badge: one driver out (Sam)');
    expect(find.text('Sam'), findsNothing);
    final card = find.byKey(const ValueKey('next-card'));
    final round = find.byKey(const ValueKey('fab-round'));

    await tester.tap(find.byIcon(Icons.local_shipping_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Sam'), findsOneWidget, reason: 'pill for the driver who is out');
    expect(find.text('Joe'), findsNothing, reason: 'available drivers are not pills');
    expect(card, findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('next-driver'))).textSpan!.toPlainText(),
      startsWith('Ana'),
      reason: 'the head of the queue is NEXT',
    );

    await tester.tap(find.text('Sam'));
    await tester.pumpAndSettle();
    expect(floor.calls, ['returned:d-sam']);
    expect(card, findsNothing, reason: 'collapsed after a return');

    // Hold the round button 2 s → undo.
    await tester.tap(find.byIcon(Icons.local_shipping_outlined));
    await tester.pumpAndSettle();
    final g = await tester.startGesture(tester.getCenter(round));
    await tester.pump(kUndoHold + const Duration(milliseconds: 100));
    await g.up();
    await tester.pumpAndSettle();
    expect(floor.calls, ['returned:d-sam', 'undo:d-sam']);
    expect(card, findsOneWidget, reason: 'the release-tap of an undo does not collapse');

    // Tap outside collapses.
    await tester.tapAt(const Offset(100, 100));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
  });
}
