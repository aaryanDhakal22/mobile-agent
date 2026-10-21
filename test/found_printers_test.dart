// 1.3.4: printers the Pi found on its network, offered with ADD in the setup
// wizard (Pi ready + Test the printers). Hidden on an older Pi.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/friendly_error.dart';
import 'package:mobile_agent/core/printer_models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/setup/found_printers.dart';
import 'package:mobile_agent/features/setup/setup_widgets.dart';
import 'package:mobile_agent/features/setup/steps/pi_ready_step.dart';
import 'package:mobile_agent/features/setup/steps/test_print_step.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _paired = {'agent_address': 'http://10.0.0.5:8080', 'device_key': 'qagt_k', 'device_name': 'Counter'};

ThemeData _theme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

const _foundBody = {
  'scanned_at': '2026-10-21T18:00:00Z',
  'scanning': false,
  'printers': [
    {'ip': '192.168.1.100', 'mac': '00:11:62:00:00:01', 'known': true, 'printer_name': 'Kitchen'},
    {'ip': '192.168.1.47', 'mac': '00:11:62:aa:bb:cc', 'known': false, 'printer_name': ''},
  ],
};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// A fake agent: [handler] answers by "METHOD /path"; every request is kept.
class _Agent {
  final List<http.Request> requests = [];
  final http.Response? Function(http.Request req) handler;
  _Agent(this.handler);

  AgentClient client() => AgentClient(
    baseUrl: 'http://10.0.0.5:8080',
    deviceKey: 'qagt_k',
    client: MockClient((req) async {
      requests.add(req);
      return handler(req) ?? http.Response('404 page not found', 404);
    }),
  );

  List<http.Request> to(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

Future<void> _pump(WidgetTester tester, AgentClient client, Widget body) async {
  SharedPreferences.setMockInitialValues(_paired);
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs), agentClientProvider.overrideWithValue(client)],
  );
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
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Finder get _dialogAdd => find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton));
Finder get _rowAdd => find.descendant(of: find.byType(CheckRow), matching: find.text('ADD'));

/// Through a dialog's open / close animation (no pumpAndSettle: spinners
/// never settle).
Future<void> _anim(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Unmounts and lets any pending timers run out.
Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
}

void main() {
  group('client', () {
    test('found printers parse; unknown lists only the new ones', () {
      final f = FoundPrinters.fromJson(Map<String, dynamic>.from(_foundBody));
      expect(f.scannedAt, DateTime.utc(2026, 10, 21, 18));
      expect(f.printers, hasLength(2));
      expect(f.printers.first.printerName, 'Kitchen');
      expect(f.unknown.map((p) => p.ip), ['192.168.1.47']);
    });

    test('refresh asks the Pi to scan again', () async {
      final agent = _Agent((req) => _json(_foundBody));
      await agent.client().foundPrinters();
      await agent.client().foundPrinters(refresh: true);
      expect(agent.requests.first.url.queryParameters, isEmpty);
      expect(agent.requests.last.url.queryParameters, {'refresh': '1'});
      expect(agent.requests.last.headers[kDeviceKeyHeader], 'qagt_k');
    });

    test('add posts name, ip and mac', () async {
      final agent = _Agent((req) => _json({'id': 'p9', 'name': 'Pizza', 'ip': '192.168.1.47'}, 201));
      final added = await agent.client().addPrinter(' Pizza ', '192.168.1.47', '00:11:62:aa:bb:cc');
      expect(added.id, 'p9');
      final sent = agent.to('POST', '/api/printers/add').single;
      expect(jsonDecode(sent.body), {'name': 'Pizza', 'ip': '192.168.1.47', 'mac': '00:11:62:aa:bb:cc'});
    });

    for (final (status, code, title) in [
      (409, kPrinterNameTaken, 'There is already a printer with that name'),
      (503, kMainOffline, "The Pi can't reach Quicc right now"),
    ]) {
      test('add $status → $code with a plain message (even without a code in the body)', () async {
        final agent = _Agent((req) => _json({'error': 'nope'}, status));
        try {
          await agent.client().addPrinter('Pizza', '192.168.1.47', '');
          fail('should throw');
        } on AgentException catch (e) {
          expect(e.code, code);
          expect(FriendlyError.from(e).title, title);
        }
      });
    }
  });

  group('found on the network', () {
    testWidgets('lists the unknown printers only', (tester) async {
      final agent = _Agent((req) => req.url.path == '/api/printers/found' ? _json(_foundBody) : null);
      await _pump(tester, agent.client(), const FoundPrintersSection(noPrintersYet: true));
      expect(find.text('Found on the network'), findsOneWidget);
      expect(find.text('Printer at 192.168.1.47'), findsOneWidget);
      expect(find.text('00:11:62:aa:bb:cc'), findsOneWidget);
      expect(find.text('Printer at 192.168.1.100'), findsNothing);
      expect(find.text('The first printer you add prints the customer receipts.'), findsOneWidget);
      expect(find.text('ADD'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('SCAN AGAIN scans with refresh=1', (tester) async {
      final agent = _Agent((req) => req.url.path == '/api/printers/found' ? _json(_foundBody) : null);
      await _pump(tester, agent.client(), const FoundPrintersSection());
      expect(find.text('The first printer you add prints the customer receipts.'), findsNothing);
      await tester.tap(find.text('SCAN AGAIN'));
      await _settle(tester);
      expect(agent.to('GET', '/api/printers/found').last.url.queryParameters, {'refresh': '1'});
      await _done(tester);
    });

    for (final status in [404, 405]) {
      testWidgets('an older Pi ($status) hides the section', (tester) async {
        final agent = _Agent((req) => http.Response('nope', status));
        await _pump(tester, agent.client(), const FoundPrintersSection(noPrintersYet: true));
        expect(find.text('Found on the network'), findsNothing);
        expect(find.text('SCAN AGAIN'), findsNothing);
        await _done(tester);
      });
    }

    testWidgets('name taken: the name dialog comes back with a message', (tester) async {
      final agent = _Agent(
        (req) => switch (req.url.path) {
          '/api/printers/found' => _json(_foundBody),
          '/api/printers/add' => _json({'error': 'a printer with that name exists', 'code': 'name_taken'}, 409),
          _ => null,
        },
      );
      final added = <String>[];
      await _pump(tester, agent.client(), FoundPrintersSection(onAdded: added.add));
      await tester.tap(_rowAdd);
      await _anim(tester);
      await tester.tap(find.text('Pizza'));
      await tester.pump();
      await tester.tap(_dialogAdd);
      await _anim(tester);
      expect(find.text('Name this printer'), findsOneWidget);
      expect(find.textContaining('There is already a printer called "Pizza"'), findsOneWidget);
      expect(added, isEmpty);
      await tester.tap(find.text('CANCEL'));
      await _anim(tester);
      expect(find.text('Printer at 192.168.1.47'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('the name is required', (tester) async {
      final agent = _Agent((req) => req.url.path == '/api/printers/found' ? _json(_foundBody) : null);
      await _pump(tester, agent.client(), const FoundPrintersSection());
      await tester.tap(_rowAdd);
      await _anim(tester);
      final add = tester.widget<FilledButton>(_dialogAdd);
      expect(add.onPressed, isNull);
      await tester.enterText(find.byType(TextField), '  ');
      await tester.pump();
      expect(tester.widget<FilledButton>(_dialogAdd).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'Grill');
      await tester.pump();
      expect(tester.widget<FilledButton>(_dialogAdd).onPressed, isNotNull);
      await tester.tap(find.text('CANCEL'));
      await _anim(tester);
      expect(agent.to('POST', '/api/printers/add'), isEmpty);
      await _done(tester);
    });
  });

  group('in the wizard', () {
    testWidgets('Test the printers: add from the empty state, then the Pi has it', (tester) async {
      var added = false;
      final agent = _Agent(
        (req) => switch (req.url.path) {
          '/api/printers/test' => _json({'results': <Object>[]}),
          '/api/printers/found' => _json(_foundBody),
          '/api/printers/add' => (() {
            added = true;
            return _json({'id': 'p9', 'name': 'Pizza', 'ip': '192.168.1.47'}, 201);
          })(),
          '/api/diag' => _json({
            'main': {'state': 'connected'},
            'printers': [
              if (added) {'id': 'p9', 'name': 'Pizza', 'ip': '192.168.1.47', 'up': true, 'is_receipt': true},
            ],
          }),
          _ => null,
        },
      );
      await _pump(tester, agent.client(), const TestPrintPanel());
      expect(find.text('Found on the network'), findsNothing); // only once the test shows no printers
      await tester.tap(find.text('PRINT TEST SLIPS'));
      await _settle(tester);
      expect(find.text('Found on the network'), findsOneWidget);
      expect(find.text('The first printer you add prints the customer receipts.'), findsOneWidget);

      await tester.tap(_rowAdd);
      await _anim(tester);
      await tester.tap(find.text('Pizza'));
      await tester.pump();
      await tester.tap(_dialogAdd);
      await _anim(tester);

      final sent = agent.to('POST', '/api/printers/add').single;
      expect(jsonDecode(sent.body), {'name': 'Pizza', 'ip': '192.168.1.47', 'mac': '00:11:62:aa:bb:cc'});
      expect(find.text('Added Pizza. The Pi gets it in a few seconds.'), findsOneWidget);
      expect(find.text('Printer at 192.168.1.47'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(agent.to('GET', '/api/diag'), isNotEmpty);
      expect(find.text('Pizza is set up. Tap PRINT AGAIN to test it.'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('Pi ready: adding a printer reads the Pi again', (tester) async {
      var added = false;
      final agent = _Agent(
        (req) => switch (req.url.path) {
          '/api/printers/found' => _json(_foundBody),
          '/api/printers/add' => (() {
            added = true;
            return _json({'id': 'p9', 'name': 'Pizza', 'ip': '192.168.1.47'}, 201);
          })(),
          '/api/diag' => _json({
            'main': {'state': 'connected', 'reachable': true},
            'printers': [
              if (added) {'id': 'p9', 'name': 'Pizza', 'ip': '192.168.1.47', 'up': true, 'is_receipt': true},
            ],
          }),
          _ => null,
        },
      );
      await _pump(tester, agent.client(), const PiReadyPanel());
      expect(find.text('Printer at 192.168.1.47'), findsOneWidget);
      expect(find.text('The first printer you add prints the customer receipts.'), findsOneWidget);

      await tester.tap(_rowAdd);
      await _anim(tester);
      await tester.tap(find.text('Pizza'));
      await tester.pump();
      await tester.tap(_dialogAdd);
      await tester.pump();
      await _settle(tester);
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.text('Pizza (receipts)'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('Pi ready on an older Pi: no found section', (tester) async {
      final agent = _Agent(
        (req) => req.url.path == '/api/diag'
            ? _json({
                'main': {'state': 'connected', 'reachable': true},
                'printers': <Object>[],
              })
            : null,
      );
      await _pump(tester, agent.client(), const PiReadyPanel());
      expect(find.text('Printers'), findsOneWidget);
      expect(find.text('Found on the network'), findsNothing);
      await _done(tester);
    });
  });
}
