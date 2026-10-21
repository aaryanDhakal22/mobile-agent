import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/storage.dart';
import 'package:mobile_agent/features/diagnose/guides.dart';
import 'package:mobile_agent/features/diagnose/report.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fake Pi + main: records every request; answers per path.
class Net {
  final calls = <String>[];
  final directKeys = <String>[];
  int piReport = 202;
  int mint = 200;
  int mintCount = 0;
  List<int> direct = [202];
  bool piDown = false;
  bool mainDown = false;

  http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  MockClient get pi => MockClient((req) async {
    if (piDown) throw const SocketExceptionLike();
    calls.add('pi ${req.url.path}');
    switch (req.url.path) {
      case '/api/diag/report':
        return piReport == 202
            ? _json(202, {'ok': true, 'stored': true})
            : _json(piReport, {'error': 'x', 'code': piReport == 429 ? 'rate_limited' : 'main_unreachable'});
      case '/api/device/report-token':
        mintCount++;
        return mint == 200
            ? _json(200, {'token': 'tok-$mintCount', 'main_url': 'http://main.test'})
            : _json(mint, {'error': 'x', 'code': 'main_unreachable'});
    }
    return _json(404, {'error': 'nope'});
  });

  MockClient get main => MockClient((req) async {
    if (mainDown) throw const SocketExceptionLike();
    calls.add('main ${req.url.path}');
    directKeys.add(req.headers[kReportKeyHeader] ?? '');
    final status = direct.length > 1 ? direct.removeAt(0) : direct.first;
    return _json(status, {'id': 'x'});
  });
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

Future<(ReportSender, AppStorage, Net)> make({bool paired = true, String? token}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final storage = AppStorage(prefs);
  if (token != null) await storage.setReportToken(token, 'http://main.test');
  final net = Net();
  final pi = AgentClient(baseUrl: '192.168.1.219', deviceKey: 'qagt_x', client: net.pi);
  final sender = ReportSender(storage: storage, piClient: () => paired ? pi : null, httpClient: () => net.main);
  return (sender, storage, net);
}

DiagReport report() => composeReport(
  kind: 'guide',
  scenario: 'pi_unreachable',
  outcome: 'fixed',
  headline: 'Fixed: the Pi had no power',
  cause: 'pi_power',
  fixedBy: 'pi_power_fix',
  steps: [StepRecord('pi_power_fix', 'test_again', result: 'fixed', at: DateTime.utc(2026, 10, 20))],
  checks: const {
    'pi_port': {'status': 'ok', 'plain': 'The Pi is listening', 'details': ''},
  },
  ctx: const ReportContext(tabletName: 'Counter', deviceId: 'd1', log: ['a', 'b']),
);

void main() {
  test('report v1 shape', () {
    final r = report().json;
    expect(r['v'], 1);
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch('${r['id']}'),
      isTrue,
    );
    expect(DateTime.tryParse('${r['created_at']}'), isNotNull);
    for (final k in [
      'kind',
      'scenario',
      'outcome',
      'headline',
      'cause',
      'fixed_by',
      'note',
      'steps',
      'checks',
      'tablet',
      'pi',
      'log',
    ]) {
      expect(r.containsKey(k), isTrue, reason: k);
    }
    expect((r['steps'] as List).first, containsPair('answer', 'test_again'));
    expect(r['tablet'], containsPair('app_version', kAppVersionFallback));
    expect(r['log'], ['a', 'b']);
    // Survives a JSON round trip (what the outbox stores).
    expect(jsonDecode(jsonEncode(r)), isA<Map>());
  });

  test('headline ≤120 and note ≤500 are enforced', () {
    final r = composeReport(
      kind: 'manual',
      outcome: 'info',
      headline: 'x' * 300,
      note: 'y' * 900,
      ctx: const ReportContext(),
    );
    expect(('${r.json['headline']}').length, 120);
    expect(('${r.json['note']}').length, 500);
  });

  test('via the Pi when it answers', () async {
    final (sender, storage, net) = await make();
    expect(await sender.send(report()), ReportOutcome.sent);
    expect(net.calls, ['pi /api/diag/report']);
    expect(sender.readOutbox(), isEmpty);
  });

  test('Pi answers 502 → straight to main with the stored token', () async {
    final (sender, storage, net) = await make(token: 'tok-saved');
    net.piReport = 502;
    expect(await sender.send(report()), ReportOutcome.sent);
    expect(net.calls, ['pi /api/diag/report', 'main /store/v1/tablet/diag-reports']);
    expect(net.directKeys, ['tok-saved']);
  });

  test('Pi 502 and no token yet → minted via the Pi, stored, then direct', () async {
    final (sender, storage, net) = await make();
    net.piReport = 502;
    expect(await sender.send(report()), ReportOutcome.sent);
    expect(net.calls, ['pi /api/diag/report', 'pi /api/device/report-token', 'main /store/v1/tablet/diag-reports']);
    expect(storage.reportToken?.token, 'tok-1');
  });

  test('Pi down and main down → saved in the outbox', () async {
    final (sender, storage, net) = await make(token: 'tok-saved');
    net.piDown = true;
    net.mainDown = true;
    expect(await sender.send(report()), ReportOutcome.saved);
    expect(sender.readOutbox(), hasLength(1));
  });

  test('Pi down, main answers → direct with the saved token', () async {
    final (sender, storage, net) = await make(token: 'tok-saved');
    net.piDown = true;
    expect(await sender.send(report()), ReportOutcome.sent);
    expect(net.calls, ['main /store/v1/tablet/diag-reports']);
  });

  test('429 from the Pi → outbox, main is not hammered', () async {
    final (sender, storage, net) = await make(token: 'tok-saved');
    net.piReport = 429;
    expect(await sender.send(report()), ReportOutcome.saved);
    expect(net.calls, ['pi /api/diag/report']);
  });

  test('401 direct → re-mint once via the Pi → sent', () async {
    final (sender, storage, net) = await make(token: 'tok-old');
    net.piReport = 502;
    net.direct = [401, 202];
    expect(await sender.send(report()), ReportOutcome.sent);
    expect(net.mintCount, 1);
    expect(net.directKeys, ['tok-old', 'tok-1']);
    expect(storage.reportToken?.token, 'tok-1');
  });

  test('401 twice → only one re-mint, then the outbox', () async {
    final (sender, storage, net) = await make(token: 'tok-old');
    net.piReport = 502;
    net.direct = [401];
    expect(await sender.send(report()), ReportOutcome.saved);
    expect(net.mintCount, 1);
    expect(net.directKeys, hasLength(2));
  });

  test('401 with the Pi down → token dropped, saved for later', () async {
    final (sender, storage, net) = await make(token: 'tok-old');
    net.piDown = true;
    net.direct = [401];
    expect(await sender.send(report()), ReportOutcome.saved);
    expect(storage.reportToken, isNull);
  });

  test('outbox flush delivers in order and empties it; keeps at most 20', () async {
    final (sender, storage, net) = await make(token: 'tok-saved');
    net.piDown = true;
    net.mainDown = true;
    for (var i = 0; i < 22; i++) {
      await sender.send(report());
    }
    final queued = sender.readOutbox();
    expect(queued, hasLength(kOutboxMax));
    net.piDown = false;
    expect(await sender.flushOutbox(), kOutboxMax);
    expect(sender.readOutbox(), isEmpty);
    expect(net.calls.where((c) => c == 'pi /api/diag/report'), hasLength(kOutboxMax));
  });

  test('flush stops at the first failure and keeps the rest', () async {
    final (sender, storage, net) = await make();
    net.piDown = true;
    await sender.send(report());
    await sender.send(report());
    expect(await sender.flushOutbox(), 0);
    expect(sender.readOutbox(), hasLength(2));
  });

  test('ensureToken mints once while the Pi answers', () async {
    final (sender, storage, net) = await make();
    await sender.ensureToken();
    await sender.ensureToken();
    expect(net.mintCount, 1);
    expect(storage.reportToken?.mainUrl, 'http://main.test');
  });
}
