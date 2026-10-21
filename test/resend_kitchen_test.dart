// 1.3.5: Reprint = the customer receipt only; Resend = every kitchen ticket
// again (POST /api/orders/{id}/kitchen), always behind a confirm. An older Pi
// without the route says it needs an update instead of failing oddly.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/friendly_error.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/kitchen/kitchen_pane.dart';
import 'package:mobile_agent/features/kitchen/resend_kitchen.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _paired = {'agent_address': 'http://10.0.0.5:8080', 'device_key': 'qagt_k', 'device_name': 'Counter'};
const _id = 'k-1';

ThemeData _theme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

Map<String, dynamic> _acceptedJson() {
  final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  (m['order'] as Map)['id'] = _id;
  (m['status'] as Map)
    ..['state'] = 'accepted'
    ..['kitchen_number'] = 1104
    ..['accepted_at'] = DateTime.now().toUtc().subtract(const Duration(minutes: 3)).toIso8601String();
  return m;
}

StoredOrder _accepted() => StoredOrder.fromJson(_acceptedJson());

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// A FloorController that never touches the network on its own.
class _FakeFloor extends FloorController {
  final FloorState initial;
  _FakeFloor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}
}

/// A fake agent: [handler] answers by request; every request is kept.
class _Agent {
  final List<http.Request> requests = [];
  final http.Response Function(http.Request req) handler;
  _Agent(this.handler);

  AgentClient client() => AgentClient(
    baseUrl: 'http://10.0.0.5:8080',
    deviceKey: 'qagt_k',
    client: MockClient((req) async {
      requests.add(req);
      return handler(req);
    }),
  );

  List<String> get paths => [for (final r in requests) '${r.method} ${r.url.path}'];
}

Future<void> _pump(WidgetTester tester, _Agent agent, Widget body) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(_paired);
  final prefs = await SharedPreferences.getInstance();
  final floor = const FloorState(connection: SseStatus.connected).withSnapshot(
    floor: Floor.fromJson(jsonDecode(floorJson) as Map<String, dynamic>),
    current: [_accepted()],
    arrived: const [],
    drivers: const [],
    at: DateTime.now(),
  );
  final c = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      agentClientProvider.overrideWithValue(agent.client()),
      floorProvider.overrideWith(() => _FakeFloor(floor)),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: _theme(), home: body),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _card() => Scaffold(
  body: Center(
    child: SizedBox(width: kTicketWidth, child: KitchenCard(order: _accepted())),
  ),
);

/// Unmounts (stops the ticket's ticker) and lets the snackbar timers finish.
Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 10));
}

const _kitchenPath = 'POST /api/orders/$_id/kitchen';
const _reprintPath = 'POST /api/orders/$_id/reprint';

http.Response _okResend(http.Request req) => req.url.path.endsWith('/kitchen')
    ? _json({
        'order': _acceptedJson(),
        'printed': ['Pizza', 'Wings'],
        'failed': <String>[],
        'rerouted': <String>[],
      })
    : _json(_acceptedJson());

void main() {
  group('kitchen ticket', () {
    testWidgets('Reprint (receipt) and Resend sit next to READY with 44 px targets', (tester) async {
      final agent = _Agent(_okResend);
      await _pump(tester, agent, _card());
      expect(tester.takeException(), isNull);
      final reprint = find.byTooltip(kReprintReceiptLabel);
      final resend = find.byTooltip(kResendKitchenLabel);
      expect(reprint, findsOneWidget);
      expect(resend, findsOneWidget);
      expect(find.bySemanticsLabel(kResendKitchenLabel), findsOneWidget);
      expect(find.bySemanticsLabel(kReprintReceiptLabel), findsOneWidget);
      for (final b in [reprint, resend]) {
        final s = tester.getSize(find.descendant(of: b, matching: find.byType(OutlinedButton)));
        expect(s.width, greaterThanOrEqualTo(44));
        expect(s.height, greaterThanOrEqualTo(44));
      }
      expect(find.text('READY'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('Reprint still calls the reprint route (receipt), no confirm', (tester) async {
      final agent = _Agent(_okResend);
      await _pump(tester, agent, _card());
      await tester.tap(find.byTooltip(kReprintReceiptLabel));
      await _settle(tester);
      expect(find.text('Send to the kitchen again?'), findsNothing);
      expect(agent.paths, [_reprintPath]);
      expect(find.text('Receipt reprinted — 1104'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('Resend asks first and only calls the API after SEND', (tester) async {
      final agent = _Agent(_okResend);
      await _pump(tester, agent, _card());
      await tester.tap(find.byTooltip(kResendKitchenLabel));
      await _settle(tester);
      expect(find.text('Send to the kitchen again?'), findsOneWidget);
      expect(find.text('Every kitchen printer for #1104 prints its ticket again.'), findsOneWidget);
      expect(agent.requests, isEmpty, reason: 'nothing is sent before SEND');

      await tester.tap(find.text('SEND'));
      await _settle(tester);
      expect(agent.paths, [_kitchenPath]);
      expect(find.text('Sent to the kitchen — Pizza, Wings'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('CANCEL does nothing', (tester) async {
      final agent = _Agent(_okResend);
      await _pump(tester, agent, _card());
      await tester.tap(find.byTooltip(kResendKitchenLabel));
      await _settle(tester);
      await tester.tap(find.text('CANCEL'));
      await _settle(tester);
      expect(find.text('Send to the kitchen again?'), findsNothing);
      expect(agent.requests, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      await _done(tester);
    });

    testWidgets('409 not_accepted shows the plain message', (tester) async {
      final agent = _Agent((_) => _json({'error': 'order not accepted', 'code': 'not_accepted'}, 409));
      await _pump(tester, agent, _card());
      await tester.tap(find.byTooltip(kResendKitchenLabel));
      await _settle(tester);
      await tester.tap(find.text('SEND'));
      await _settle(tester);
      expect(agent.paths, [_kitchenPath]);
      expect(find.text("This order hasn't been accepted yet."), findsOneWidget);
      await _done(tester);
    });

    testWidgets('an older Pi (405) says it needs an update — no crash', (tester) async {
      final agent = _Agent((_) => http.Response('Method Not Allowed\n', 405));
      await _pump(tester, agent, _card());
      await tester.tap(find.byTooltip(kResendKitchenLabel));
      await _settle(tester);
      await tester.tap(find.text('SEND'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('This Pi needs an update to resend to the kitchen'), findsOneWidget);
      // The button is usable again.
      final btn = tester.widget<OutlinedButton>(
        find.descendant(of: find.byTooltip(kResendKitchenLabel), matching: find.byType(OutlinedButton)),
      );
      expect(btn.onPressed, isNotNull);
      await _done(tester);
    });
  });

  group('order details', () {
    testWidgets('accepted order: REPRINT RECEIPT and RESEND TO KITCHEN side by side; resend confirms', (
      tester,
    ) async {
      final agent = _Agent(_okResend);
      final so = _accepted();
      await _pump(tester, agent, OrderDetailScreen(orderId: so.id, initial: so));
      expect(tester.takeException(), isNull);
      final reprint = find.text('REPRINT RECEIPT');
      final resend = find.text('RESEND TO KITCHEN');
      expect(reprint, findsOneWidget);
      expect(resend, findsOneWidget);
      expect(tester.getCenter(reprint).dy, closeTo(tester.getCenter(resend).dy, 1), reason: 'same row');

      await tester.tap(resend);
      await _settle(tester);
      expect(find.text('Send to the kitchen again?'), findsOneWidget);
      expect(agent.requests, isEmpty);
      await tester.tap(find.text('SEND'));
      await _settle(tester);
      expect(agent.paths, [_kitchenPath]);
      expect(find.text('Sent to the kitchen — Pizza, Wings'), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));
      await tester.tap(reprint);
      await _settle(tester);
      expect(agent.paths.last, _reprintPath);
      expect(find.text('Receipt reprinted'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('no Resend without a kitchen number (cancelled before accept)', (tester) async {
      final agent = _Agent(_okResend);
      final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
      (m['status'] as Map)['state'] = 'cancelled';
      final so = StoredOrder.fromJson(m);
      await _pump(tester, agent, OrderDetailScreen(orderId: so.id, initial: so));
      expect(find.text('REPRINT RECEIPT'), findsOneWidget);
      expect(find.text('RESEND TO KITCHEN'), findsNothing);
      await _done(tester);
    });

    testWidgets('fits a 960 px tablet without overflow', (tester) async {
      final agent = _Agent(_okResend);
      final so = _accepted();
      await _pump(tester, agent, OrderDetailScreen(orderId: so.id, initial: so));
      tester.view.physicalSize = const Size(960, 600);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await _done(tester);
    });
  });

  group('AgentClient.resendKitchen', () {
    test('200 → printed / failed station names', () async {
      final agent = _Agent(
        (_) => _json({
          'order': _acceptedJson(),
          'printed': ['Pizza'],
          'failed': ['Wings'],
          'rerouted': <String>[],
        }),
      );
      final r = await agent.client().resendKitchen(_id);
      expect(r.printed, ['Pizza']);
      expect(r.failed, ['Wings']);
      expect(r.order?.status.kitchenNumber, 1104);
      expect(resendKitchenMessage(r), 'Sent to the kitchen — Pizza. Not printed: Wings');
      expect(agent.paths, [_kitchenPath]);
    });

    Future<AgentException> failure(http.Response resp) async {
      try {
        await _Agent((_) => resp).client().resendKitchen(_id);
      } on AgentException catch (e) {
        return e;
      }
      throw StateError('expected an AgentException');
    }

    test('missing route (405, plain-text 404) → kitchen_unsupported', () async {
      for (final r in [http.Response('Method Not Allowed', 405), http.Response('404 page not found\n', 404)]) {
        final e = await failure(r);
        expect(e.code, kKitchenUnsupported);
        expect(FriendlyError.from(e).title, 'This Pi needs an update to resend to the kitchen');
      }
    });

    test('a JSON 404 is an unknown order, not an old Pi', () async {
      final e = await failure(_json({'error': 'order not found'}, 404));
      expect(e.code, 'not_found');
    });

    test('friendly messages for the new codes', () async {
      Future<String> title(int status, String code) async =>
          FriendlyError.from(await failure(_json({'error': 'x', 'code': code}, status))).title;
      expect(await title(409, 'not_accepted'), "This order hasn't been accepted yet.");
      expect(await title(409, 'nothing_for_kitchen'), 'Nothing on this order goes to a kitchen printer.');
      expect(await title(502, 'print_failed'), "Printer problem — the kitchen tickets didn't print.");
    });
  });
}
