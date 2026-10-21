import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/friendly_error.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/receipt_models.dart';
import 'package:mobile_agent/features/settings/receipt_settings_card.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _defaultsJson = <String, Object?>{
  'kitchen_item_size': 'large',
  'kitchen_number_size': 'xlarge',
  'footer_text': null,
  'footer_size': 'xlarge',
  'copies': 1,
  'show_store_address': true,
  'show_phone': true,
  'extra_paper': true,
};

/// Plays the agent's receipt routes; records every request.
class FakeReceiptAgent {
  final requests = <http.Request>[];
  Map<String, Object?> prefs = Map.of(_defaultsJson);
  bool oldPi = false;
  List<Map<String, Object?>> sampleResults = const [];

  http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

  Future<http.Response> handle(http.Request req) async {
    requests.add(req);
    final path = req.url.path;
    if (oldPi && (path == '/api/settings/receipt' || path == '/api/printers/sample')) {
      return req.method == 'GET' ? _json({'error': 'not found'}, 404) : http.Response('Method Not Allowed', 405);
    }
    switch ((req.method, path)) {
      case ('GET', '/api/settings/receipt'):
        return _json({'prefs': prefs, 'defaults': _defaultsJson, 'footer_effective': _effective()});
      case ('PUT', '/api/settings/receipt'):
        prefs = (jsonDecode(req.body) as Map).cast<String, Object?>();
        return _json({'prefs': prefs, 'footer_effective': _effective()});
      case ('GET', '/api/diag'):
        return _json({
          'printers': [
            {'id': 'p1', 'name': 'Kitchen', 'up': true},
            {'id': 'p2', 'name': 'Online', 'up': true, 'is_receipt': true},
          ],
        });
      case ('POST', '/api/printers/sample'):
        final id = jsonDecode(req.body)['printer_id'] ?? 'p2';
        return _json({
          'results': sampleResults.isNotEmpty
              ? sampleResults
              : [
                  {'id': id, 'name': id == 'p1' ? 'Kitchen' : 'Online', 'ok': true},
                ],
        });
    }
    return _json({'error': 'nope'}, 500);
  }

  String _effective() => (prefs['footer_text'] as String?) ?? 'ONLINE ORDER';

  List<http.Request> calls(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

void main() {
  group('ReceiptPrefs', () {
    test('round-trips the full object, null footer included', () {
      final p = ReceiptPrefs.fromJson(Map.of(_defaultsJson));
      expect(p, ReceiptPrefs.standard);
      expect(p.footerText, isNull);
      final json = p.toJson();
      expect(json, _defaultsJson);
      expect(json.containsKey('footer_text'), isTrue, reason: 'null is sent, not left out');
      expect(jsonDecode(jsonEncode(json)), _defaultsJson);
    });

    test('custom values survive a round-trip, including an empty footer', () {
      const p = ReceiptPrefs(
        kitchenItemSize: ReceiptSize.xlarge,
        kitchenNumberSize: NumberSize.huge,
        footerText: '',
        footerSize: ReceiptSize.normal,
        copies: 2,
        showStoreAddress: false,
        showPhone: false,
        extraPaper: false,
      );
      final back = ReceiptPrefs.fromJson((jsonDecode(jsonEncode(p.toJson())) as Map).cast<String, dynamic>());
      expect(back, p);
      expect(back.footerText, '');
      expect(back.hashCode, p.hashCode);
    });

    test('missing or unknown fields fall back to the defaults', () {
      final p = ReceiptPrefs.fromJson({'kitchen_item_size': 'gigantic', 'copies': 7, 'show_phone': false});
      expect(p.kitchenItemSize, ReceiptSize.large);
      expect(p.copies, 1);
      expect(p.showPhone, isFalse);
      expect(p.footerText, isNull);
    });

    test('copyWith sets the footer to null, or keeps it when left out', () {
      const p = ReceiptPrefs(footerText: 'THANK YOU');
      expect(p.copyWith(copies: 2).footerText, 'THANK YOU');
      expect(p.copyWith(footerText: null).footerText, isNull);
      expect(p.copyWith(footerText: null), isNot(p));
      expect(p.copyWith(footerText: 'THANK YOU'), p);
    });

    test('settings read prefs, defaults and the effective footer', () {
      final s = ReceiptSettings.fromJson({
        'prefs': {..._defaultsJson, 'copies': 2},
        'defaults': _defaultsJson,
        'footer_effective': 'ONLINE ORDER',
      });
      expect(s.prefs.copies, 2);
      expect(s.defaults, ReceiptPrefs.standard);
      expect(s.footerEffective, 'ONLINE ORDER');
    });
  });

  group('AgentClient receipt routes', () {
    AgentClient client(Future<http.Response> Function(http.Request) h) =>
        AgentClient(baseUrl: '192.168.1.219', deviceKey: 'k', client: MockClient(h));

    test('an older Pi (404 / 405) reads as "needs an update"', () async {
      final fake = FakeReceiptAgent()..oldPi = true;
      final c = client(fake.handle);
      for (final call in <Future<Object?> Function()>[
        c.getReceiptPrefs,
        () => c.putReceiptPrefs(ReceiptPrefs.standard),
        () => c.printSample(printerId: 'p1'),
      ]) {
        await expectLater(call(), throwsA(isA<AgentException>().having((e) => e.code, 'code', kReceiptUnsupported)));
      }
      expect(
        FriendlyError.from(const AgentException('not found', statusCode: 404, code: kReceiptUnsupported)).title,
        'This Pi needs an update for receipt settings',
      );
    });

    test('a sample on an unknown printer stays not_configured', () async {
      final c = client(
        (_) async => http.Response(jsonEncode({'error': 'unknown printer', 'code': 'not_configured'}), 404),
      );
      await expectLater(
        c.printSample(printerId: 'zz'),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', 'not_configured')),
      );
    });

    test('a sample with no printer sends an empty body', () async {
      final fake = FakeReceiptAgent();
      final r = await client(fake.handle).printSample();
      expect(jsonDecode(fake.requests.single.body), <String, Object?>{});
      expect(r.single.ok, isTrue);
    });
  });

  group('Receipts card', () {
    Future<FakeReceiptAgent> pumpCard(WidgetTester tester, {FakeReceiptAgent? agent}) async {
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = agent ?? FakeReceiptAgent();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          agentClientProvider.overrideWith(
            (ref) => AgentClient(baseUrl: '192.168.1.219', deviceKey: 'qagt_test', client: MockClient(fake.handle)),
          ),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]),
            home: const Scaffold(body: SingleChildScrollView(child: ReceiptSettingsCard())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return fake;
    }

    FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.ancestor(of: find.text('SAVE'), matching: find.byWidgetPredicate((w) => w is FilledButton)),
    );

    Set<T> selected<T>(WidgetTester tester, int index) =>
        tester.widgetList<SegmentedButton<T>>(find.byType(SegmentedButton<T>)).elementAt(index).selected;

    testWidgets('shows the saved settings, the store footer, SAVE off', (tester) async {
      await pumpCard(tester);
      expect(find.text('RECEIPTS'), findsOneWidget);
      expect(find.text('Kitchen tickets'), findsOneWidget);
      expect(find.text('Customer receipt'), findsOneWidget);
      expect(selected<ReceiptSize>(tester, 0), {ReceiptSize.large}, reason: 'item text size');
      expect(selected<NumberSize>(tester, 0), {NumberSize.xlarge});
      expect(selected<ReceiptSize>(tester, 1), {ReceiptSize.xlarge}, reason: 'footer size');
      expect(selected<int>(tester, 0), {1});
      expect(find.text('Prints: ONLINE ORDER'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(saveButton(tester).onPressed, isNull, reason: 'nothing changed yet');
      expect(find.text('Online (receipt)'), findsOneWidget, reason: 'the picker starts on the receipt printer');
      expect(find.text('This Pi needs an update for receipt settings'), findsNothing);
      // Every control has its (i).
      expect(find.byTooltip('What is this?'), findsNWidgets(11));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a change turns SAVE on and the PUT sends the whole object', (tester) async {
      final fake = await pumpCard(tester);
      await tester.tap(find.text('Extra large').first);
      await tester.pump();
      expect(saveButton(tester).onPressed, isNotNull);
      expect(find.text('You have changes that are not saved yet.'), findsOneWidget);

      await tester.tap(find.text('Show customer phone'));
      await tester.tap(find.text('2 copies'));
      await tester.tap(find.text('Use the store default'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'THANK YOU');
      await tester.pump();

      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();
      final put = fake.calls('PUT', '/api/settings/receipt').single;
      expect(jsonDecode(put.body), {
        ..._defaultsJson,
        'kitchen_item_size': 'xlarge',
        'show_phone': false,
        'copies': 2,
        'footer_text': 'THANK YOU',
      });
      expect(find.text('Receipt settings saved'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull, reason: 'saved = nothing pending');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an empty footer is sent as "", the store default as null', (tester) async {
      final fake = await pumpCard(tester);
      await tester.tap(find.text('Use the store default'));
      await tester.pump();
      expect(find.text('Leave it empty for no footer'), findsOneWidget);
      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();
      expect(jsonDecode(fake.calls('PUT', '/api/settings/receipt').last.body)['footer_text'], '');

      await tester.tap(find.text('Use the store default'));
      await tester.pump();
      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();
      final body = jsonDecode(fake.calls('PUT', '/api/settings/receipt').last.body) as Map;
      expect(body.containsKey('footer_text'), isTrue);
      expect(body['footer_text'], isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('PRINT SAMPLE prints on the chosen printer', (tester) async {
      final fake = await pumpCard(tester);
      await tester.tap(find.text('PRINT SAMPLE'));
      await tester.pumpAndSettle();
      expect(jsonDecode(fake.calls('POST', '/api/printers/sample').single.body), {'printer_id': 'p2'});
      expect(find.text('Sample printed on Online'), findsOneWidget);
      expect(fake.calls('PUT', '/api/settings/receipt'), isEmpty, reason: 'nothing to save first');

      await tester.tap(find.text('Online (receipt)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kitchen').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('PRINT SAMPLE'));
      await tester.pumpAndSettle();
      expect(jsonDecode(fake.calls('POST', '/api/printers/sample').last.body), {'printer_id': 'p1'});
      expect(find.text('Sample printed on Kitchen'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unsaved changes are saved before the sample prints', (tester) async {
      final fake = await pumpCard(tester);
      await tester.tap(find.text('2 copies'));
      await tester.pump();
      await tester.tap(find.text('PRINT SAMPLE'));
      await tester.pumpAndSettle();
      final order = fake.requests.map((r) => '${r.method} ${r.url.path}').toList();
      expect(order.indexOf('PUT /api/settings/receipt'), lessThan(order.indexOf('POST /api/printers/sample')));
      expect(fake.prefs['copies'], 2);
      expect(saveButton(tester).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a printer that did not print is named, in plain words', (tester) async {
      final fake = FakeReceiptAgent()
        ..sampleResults = [
          {'id': 'p2', 'name': 'Online', 'ok': false, 'error_code': 'unreachable', 'error': 'dial tcp: i/o timeout'},
        ];
      await pumpCard(tester, agent: fake);
      await tester.tap(find.text('PRINT SAMPLE'));
      await tester.pumpAndSettle();
      expect(find.text('Not printed on Online'), findsOneWidget);
      expect(find.textContaining('Check the printer is on'), findsOneWidget);
      expect(find.textContaining('i/o timeout'), findsNothing, reason: 'raw text stays behind DETAILS');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('RESET TO DEFAULTS fills the defaults and saves', (tester) async {
      final fake = FakeReceiptAgent()..prefs = {..._defaultsJson, 'copies': 2, 'footer_text': 'HI'};
      await pumpCard(tester, agent: fake);
      expect(selected<int>(tester, 0), {2});
      await tester.tap(find.text('RESET TO DEFAULTS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RESET'));
      await tester.pumpAndSettle();
      expect(jsonDecode(fake.calls('PUT', '/api/settings/receipt').single.body), _defaultsJson);
      expect(selected<int>(tester, 0), {1});
      expect(find.text('Prints: ONLINE ORDER'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an older Pi gets the update message instead of the controls', (tester) async {
      await pumpCard(tester, agent: FakeReceiptAgent()..oldPi = true);
      expect(find.text('This Pi needs an update for receipt settings'), findsOneWidget);
      expect(find.text('SAVE'), findsNothing);
      expect(find.text('PRINT SAMPLE'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a bad footer: the Pi\'s reason is shown', (tester) async {
      await pumpCard(tester, agent: _RejectingAgent());
      await tester.tap(find.text('2 copies'));
      await tester.pump();
      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();
      expect(find.text('Not saved'), findsOneWidget);
      expect(find.textContaining('footer is too long'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Answers every PUT with a 400 `bad_request`.
class _RejectingAgent extends FakeReceiptAgent {
  @override
  Future<http.Response> handle(http.Request req) async {
    if (req.method == 'PUT') {
      requests.add(req);
      return http.Response(jsonEncode({'error': 'footer is too long', 'code': 'bad_request'}), 400);
    }
    return super.handle(req);
  }
}
