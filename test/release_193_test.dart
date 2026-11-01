// 1.9.3: developer mode → Logs → Settings changes — the Pi's settings history
// (agent 2.3.11, GET /api/settings/changes): when, which tablet or the Pi web
// page, and each key from → to. An older Pi says it needs the update.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/delivery_models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/dev/settings_history.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _paired = {'agent_address': 'http://10.0.0.5:8080', 'device_key': 'qagt_k', 'device_name': 'Counter'};

const _history = {
  'keep_days': 90,
  'changes': [
    {
      'id': 3,
      'at': '2026-10-29T21:00:35Z',
      'section': 'tickets',
      'by': {'kind': 'tablet', 'name': 'Counter', 'device_id': 'dev-1'},
      'changes': [
        {'key': 'online_cash_delivery', 'from': true, 'to': false},
      ],
    },
    {
      'id': 2,
      'at': '2026-10-29T20:31:44Z',
      'section': 'times',
      'by': {'kind': 'web', 'name': 'Pi web page'},
      'changes': [
        {'key': 'default_pickup_minutes', 'from': 15, 'to': 20},
      ],
    },
  ],
};

AgentClient _client(List<http.Request> seen, http.Response Function() answer) => AgentClient(
  baseUrl: 'http://10.0.0.5:8080',
  deviceKey: 'qagt_k',
  client: MockClient((req) async {
    seen.add(req);
    return answer();
  }),
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Future<void> _pump(WidgetTester tester, AgentClient client) async {
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
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]),
        home: const Scaffold(body: SingleChildScrollView(child: SettingsHistoryCard())),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  test('SettingsChange parses who, section and each key', () {
    final c = SettingsChange.fromJson((_history['changes']! as List).first as Map<String, dynamic>);
    expect(c.id, 3);
    expect(c.section, 'tickets');
    expect(c.byTablet, isTrue);
    expect(c.byName, 'Counter');
    expect(c.at, DateTime.utc(2026, 10, 29, 21, 0, 35));
    expect(c.changes.single.key, 'online_cash_delivery');
    expect(c.changes.single.from, true);
    expect(c.changes.single.to, false);
  });

  test('labels: Settings switch names, plain words otherwise, ON/OFF values', () {
    expect(settingKeyLabel('tickets', 'online_card'), 'Online card (paid)');
    expect(settingKeyLabel('features', 'pos_pull'), 'POS orders pull-in');
    expect(settingKeyLabel('times', 'default_pickup_minutes'), 'Default pickup minutes');
    expect(settingKeyLabel('callout', 'voice_lines.kokoro:af_heart'), 'Voice lines › kokoro:af_heart');
    expect(settingsSectionLabel('driver-reset'), 'Driver clock-out');
    expect(settingValue(true), 'ON');
    expect(settingValue(false), 'OFF');
    expect(settingValue(null), '—');
    expect(settingValue(20), '20');
    expect(settingValue(''), '""');
    expect(settingValue('09:30'), '09:30');
    expect(settingValue(const ['a']), '["a"]');
  });

  testWidgets('the card lists the Pi\'s history, newest first, with who did it', (tester) async {
    final seen = <http.Request>[];
    await _pump(tester, _client(seen, () => _json(_history)));
    expect(seen.single.url.path, '/api/settings/changes');
    expect(seen.single.headers['X-Agent-Device-Key'], 'qagt_k');

    expect(find.text('SETTINGS CHANGES'), findsOneWidget);
    expect(find.byType(SettingsChangeTile), findsNWidgets(2));
    expect(find.text('Counter'), findsOneWidget);
    expect(find.text('Pi web page'), findsOneWidget);
    expect(find.text('· Kitchen tickets'), findsOneWidget);
    expect(find.text('· Default times'), findsOneWidget);
    expect(find.textContaining('Online cash delivery', findRichText: true), findsOneWidget);
    expect(find.textContaining('ON  →  OFF', findRichText: true), findsOneWidget);
    expect(find.textContaining('15  →  20', findRichText: true), findsOneWidget);
    final first = tester.getTopLeft(find.text('Counter'));
    final second = tester.getTopLeft(find.text('Pi web page'));
    expect(first.dy, lessThan(second.dy), reason: 'newest first');

    // Refresh asks again.
    await tester.tap(find.byKey(const ValueKey('settings-history-refresh')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(seen, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nothing changed yet', (tester) async {
    await _pump(tester, _client([], () => _json({'changes': <Object>[], 'keep_days': 90})));
    expect(find.text('No settings changed in the last 90 days.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an older Pi (404) says it needs the update and stops asking', (tester) async {
    final seen = <http.Request>[];
    await _pump(tester, _client(seen, () => http.Response('404 page not found', 404)));
    expect(find.textContaining('needs the 2.3.11 update'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    expect(seen, hasLength(1), reason: 'no polling an old Pi');
    await tester.pumpWidget(const SizedBox());
  });
}
