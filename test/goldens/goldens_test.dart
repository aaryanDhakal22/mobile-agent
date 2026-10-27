// Golden screenshots of the key 1.6.0 screens, dark + light, at the
// counter tablet's 1280×800. Real fonts (the bundled Barlow family,
// Material icons from the Flutter SDK) and a pinned clock, so the images only
// change when the UI does. After a deliberate UI change:
//
//   flutter test --update-goldens test/goldens
//
// and look at the new PNGs in test/goldens/png/ before committing them.
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/alert/new_order_alert.dart';
import 'package:mobile_agent/features/dev/dev_gate.dart';
import 'package:mobile_agent/features/home/home_nav.dart';
import 'package:mobile_agent/features/home/home_screen.dart';
import 'package:mobile_agent/features/update/update_prompt.dart';
import 'package:mobile_agent/features/update/updater.dart';
import 'package:mobile_agent/theme/quicc_theme.dart';

import '../delivery_fixtures.dart';
import '../fixtures.dart';

/// The pinned "now": a little after the fixtures' orders were placed.
final _now = DateTime.utc(2026, 5, 12, 17, 50);

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  const w = ['Regular', 'Medium', 'SemiBold', 'Bold'];
  for (final f in ['Barlow', 'BarlowCondensed', 'BarlowSemiCondensed']) {
    await _loadFont(f, [for (final x in w) 'assets/fonts/$f-$x.ttf']);
  }
  final root = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final mf = '$root/bin/cache/artifacts/material_fonts';
  await _loadFont('MaterialIcons', ['$mf/MaterialIcons-Regular.otf']);
  await _loadFont('Roboto', ['$mf/Roboto-Regular.ttf', '$mf/Roboto-Medium.ttf', '$mf/Roboto-Bold.ttf']);
}

/// A pickup the kitchen is cooking: kitchen #[k], accepted [ago] min ago,
/// ready in [readyIn] min.
StoredOrder _cooking(String id, int k, String name, {int ago = 8, int readyIn = 12, bool paidAtStore = false}) {
  final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  if (paidAtStore) (m['status'] as Map)['paid'] = true; // customer waiting: red lava bar
  final now = clock.now().toUtc();
  (m['order'] as Map)
    ..['id'] = id
    ..['placed_at'] = now.subtract(Duration(minutes: ago + 1)).toIso8601String();
  ((m['order'] as Map)['customer'] as Map)['display_name'] = name;
  (m['status'] as Map)
    ..['state'] = 'accepted'
    ..['kitchen_number'] = k
    ..['arrival_date'] = now.subtract(Duration(minutes: ago)).toIso8601String()
    ..['accepted_at'] = now.subtract(Duration(minutes: ago)).toIso8601String()
    ..['estimated_ready_at'] = now.add(Duration(minutes: readyIn)).toIso8601String();
  return StoredOrder.fromJson(m);
}

StoredOrder _arrivedPickup(String id) {
  final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  (m['order'] as Map)['id'] = id;
  (m['status'] as Map)
    ..['state'] = 'arrived'
    ..['arrival_date'] = clock.now().toUtc().subtract(const Duration(seconds: 30)).toIso8601String();
  return StoredOrder.fromJson(m);
}

StoredOrder _arrivedDelivery(String id) {
  final m = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
  final now = clock.now().toUtc();
  (m['order'] as Map)
    ..['id'] = id
    ..['placed_at'] = now.subtract(const Duration(minutes: 1)).toIso8601String()
    ..remove('kitchen_order_number');
  m['status'] = {'state': 'arrived', 'arrival_date': now.subtract(const Duration(seconds: 40)).toIso8601String()};
  m['geo'] = locatedGeo();
  return StoredOrder.fromJson(m);
}

StoredOrder _located(StoredOrder o) {
  final m = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
  m['geo'] = locatedGeo();
  return StoredOrder.fromJson(m);
}

/// A delivery the driver brought back (1.7.1): TRY AGAIN put it in "Came
/// back" [backMin] minutes ago.
StoredOrder _cameBack(String id, int k, String street, {int backMin = 6}) {
  final m = jsonDecode(onDeliveryJson) as Map<String, dynamic>;
  final now = clock.now().toUtc();
  (m['order'] as Map)
    ..['id'] = id
    ..['kitchen_order_number'] = k
    ..['placed_at'] = now.subtract(const Duration(minutes: 50)).toIso8601String();
  (((m['order'] as Map)['fulfillment'] as Map)['address'] as Map)['line1'] = street;
  m['status'] = {
    'state': 'ready',
    'kitchen_number': k,
    'batch_id': 7,
    'came_back': true,
    'not_delivered': {
      'action': 'retry',
      'at': now.subtract(Duration(minutes: backMin)).toIso8601String(),
      'driver_id': 'd-sam',
    },
  };
  m['geo'] = locatedGeo();
  return StoredOrder.fromJson(m);
}

/// A POS takeout cooking, #158, the cashier added Garlic Knots and voided a
/// Coke at the terminal (1.8.0): the blue CHANGED alert ([acked] = OK'd).
StoredOrder _changedPos({bool acked = false}) {
  final now = clock.now().toUtc();
  return StoredOrder.fromJson({
    'order': {
      'id': 'pos-158',
      'source': 'pos',
      'customer': {'display_name': 'Dana Ruiz'},
      'fulfillment': {'type': 'pickup'},
      'items': [
        {'id': 'l1', 'name': 'Cheese Steak', 'quantity': 1, 'pos_ref': '1', 'kitchen': true},
        {'id': 'l3', 'name': 'Garlic Knots', 'quantity': 1, 'pos_ref': '3', 'kitchen': true, 'added': true},
      ],
      'removed_items': [
        {'id': 'l2', 'name': 'Coke', 'quantity': 1, 'pos_ref': '2'},
      ],
      'placed_at': now.subtract(const Duration(minutes: 6)).toIso8601String(),
    },
    'status': {
      'state': 'accepted',
      'batch_id': 7,
      'ext_source': 'softtouch',
      'ext_ref': '1277158',
      'display_number': 158,
      'sent_at': now.subtract(const Duration(minutes: 6)).toIso8601String(),
      'accepted_at': now.subtract(const Duration(minutes: 6)).toIso8601String(),
      'estimated_ready_at': now.add(const Duration(minutes: 9)).toIso8601String(),
      'pos_change': {
        'id': 'c1',
        'at': now.subtract(const Duration(seconds: 20)).toIso8601String(),
        'kind': 'cooking',
        'added': [
          {'name': 'Garlic Knots', 'quantity': 1, 'kitchen': true},
        ],
        'removed': [
          {'name': 'Coke', 'quantity': 1},
        ],
        if (acked) 'acked_at': now.subtract(const Duration(seconds: 10)).toIso8601String(),
      },
    },
  });
}

/// The delivery floor plus a few pickups cooking, and [arrived] ringing.
/// Ana (NEXT) has #1103 in her box; d2 and d5 sit in Joe's, so one delivery
/// waits and NEXT can send her out.
FloorState _floor({List<StoredOrder> arrived = const [], bool quiet = false, bool cameBack = false, StoredOrder? extra}) {
  final base = deliveryFloor();
  if (quiet) {
    return base.withSnapshot(floor: base.floor!, current: const [], arrived: const [], drivers: base.drivers, at: clock.now());
  }
  final current = [
    for (final o in base.orders.values)
      if (o.id == 'd2' || o.id == 'd5')
        o.copyWith(status: o.status.withPool('d-joe'))
      else if (o.state == OrderState.onDelivery)
        _located(o) // Sam's run, so the Map shows a line
      else
        o,
    _cooking('p1', 1107, 'Maria Lopez', ago: 4, readyIn: 16),
    _cooking('p2', 1108, 'Tom Becker', ago: 14, readyIn: 3, paidAtStore: true),
    _cooking('p3', 1109, 'Priya Shah', ago: 27, readyIn: -6),
    if (cameBack) ...[_cameBack('cb1', 1100, '18 Linden Terrace', backMin: 9), _cameBack('cb2', 1104, '5 Elm Ct')],
    ?extra,
  ];
  return base.withSnapshot(floor: base.floor!, current: current, arrived: arrived, drivers: base.drivers, at: clock.now());
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required bool dark,
  List<StoredOrder> arrived = const [],
  bool ringing = false,
  bool quiet = false,
  bool cameBack = false,
  StoredOrder? extra,
  UpdateState? update,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakeDeliveryFloor(_floor(arrived: arrived, quiet: quiet, cameBack: cameBack, extra: extra));
  final c = await deliveryContainer(
    fake,
    prefs: const {
      'agent_address': 'http://192.168.1.219:8080',
      'device_key': 'qagt_test',
      'device_name': 'Counter tablet',
      'device_id': 'dev-1',
    },
    extra: [
      agentClientProvider.overrideWith((ref) => null),
      if (update != null) updaterProvider.overrideWith(() => _FixedUpdater(update)),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: dark ? QuiccTheme.dark() : QuiccTheme.light(),
        home: const HomeScreen(),
        builder: (context, child) => ringing
            ? AlarmHost(child: child!)
            : update != null
            ? UpdatePrompt(child: child!)
            : child!,
      ),
    ),
  );
  await _settle(tester);
  return c;
}

/// A fixed update state (no Pi, no timers).
class _FixedUpdater extends Updater {
  final UpdateState initial;
  _FixedUpdater(this.initial);

  @override
  UpdateState build() => initial;
}

/// Lets switches, the blob and dialogs come to rest (fixed frames — the AUTO
/// glow loops forever, so no pumpAndSettle).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _golden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('png/$name.png'));

void main() {
  setUpAll(_loadFonts);

  for (final dark in [true, false]) {
    final theme = dark ? 'dark' : 'light';

    void golden(String name, Future<void> Function(WidgetTester tester) body) {
      testWidgets('$name ($theme)', (tester) => withClock(Clock.fixed(_now), () => body(tester)));
    }

    golden('kitchen', (tester) async {
      await _pump(tester, dark: dark);
      await _golden(tester, 'kitchen_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('driver button NEXT card', (tester) async {
      await _pump(tester, dark: dark);
      await tester.tap(find.byIcon(Icons.local_shipping_outlined));
      await _settle(tester);
      await _golden(tester, 'driver_next_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('deliveries', (tester) async {
      final c = await _pump(tester, dark: dark);
      c.read(homeNavProvider.notifier).go(HomeDestination.deliveries);
      await _settle(tester);
      await _golden(tester, 'deliveries_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('deliveries with came back', (tester) async {
      final c = await _pump(tester, dark: dark, cameBack: true);
      c.read(homeNavProvider.notifier).go(HomeDestination.deliveries);
      await _settle(tester);
      await _golden(tester, 'deliveries_came_back_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('alert, pickup', (tester) async {
      await _pump(tester, dark: dark, arrived: [_arrivedPickup('a-p1')], ringing: true);
      await _golden(tester, 'alert_pickup_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('alert, delivery with map', (tester) async {
      await _pump(tester, dark: dark, arrived: [_arrivedDelivery('a-d1')], ringing: true);
      await _golden(tester, 'alert_delivery_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('CHANGED alert', (tester) async {
      await _pump(tester, dark: dark, extra: _changedPos(), ringing: true);
      await _golden(tester, 'change_alert_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('kitchen with a CHANGED ticket', (tester) async {
      await _pump(tester, dark: dark, extra: _changedPos(acked: true));
      await _golden(tester, 'kitchen_changed_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('map', (tester) async {
      final c = await _pump(tester, dark: dark);
      c.read(homeNavProvider.notifier).go(HomeDestination.map);
      await _settle(tester);
      await _golden(tester, 'map_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('update prompt', (tester) async {
      await _pump(
        tester,
        dark: dark,
        quiet: true,
        update: const UpdateState(
          target: AppRelease(versionCode: 20, versionName: '1.6.2'),
          phase: UpdatePhase.needsTap,
        ),
      );
      await _golden(tester, 'update_prompt_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('store mode settings', (tester) async {
      final c = await _pump(tester, dark: dark);
      c.read(homeNavProvider.notifier).go(HomeDestination.settings);
      await _settle(tester);
      await _golden(tester, 'store_settings_$theme');
      await tester.pumpWidget(const SizedBox());
    });

    golden('developer mode connections', (tester) async {
      final c = await _pump(tester, dark: dark);
      c.read(devGateProvider.notifier).unlock();
      c.read(homeNavProvider.notifier).go(HomeDestination.connections);
      await _settle(tester);
      await _golden(tester, 'dev_connections_$theme');
      c.read(devGateProvider.notifier).lock();
      await tester.pumpWidget(const SizedBox());
    });
  }
}
