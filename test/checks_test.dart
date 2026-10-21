import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/device_platform.dart';
import 'package:mobile_agent/core/diag_models.dart';
import 'package:mobile_agent/core/discovery.dart';
import 'package:mobile_agent/features/diagnose/checks.dart';
import 'package:mobile_agent/features/diagnose/texts.dart';

import 'diag_fakes.dart';

Future<CheckSnapshot> run(FakeProbes p, {String mainUrl = 'http://main.test', bool probePrinters = false}) =>
    runChecks(p, savedAddress: kSaved, mainUrl: mainUrl, probePrinters: probePrinters, now: () => kNow);

void main() {
  test('all healthy → every check ok, in board order', () async {
    final s = await run(FakeProbes());
    expect(s.results.keys.toList(), CheckId.values);
    for (final r in s.results.values) {
      expect(r.status, CheckStatus.ok, reason: '${r.id}: ${r.plain}');
    }
    expect(s.results[CheckId.printers]!.plain, CheckText.printersOk(2));
    expect(s.toReport()['pi_port'], containsPair('status', 'ok'));
  });

  test('refused port → plain sentence; Pi-dependent checks unknown when the Pi API fails', () async {
    final p = FakeProbes()
      ..portState = PortState.refused
      ..sessionAnswer = null
      ..diagAnswer = null;
    final s = await run(p);
    expect(s.results[CheckId.piPort]!.plain, CheckText.portRefused);
    expect(s.results[CheckId.piApi]!.status, CheckStatus.fail);
    for (final id in [CheckId.piToMain, CheckId.piHealth, CheckId.printers, CheckId.ordersFlow]) {
      expect(s.results[id]!.status, CheckStatus.unknown, reason: '$id');
    }
  });

  test('our Pi at a new address is found (our key works there)', () async {
    const moved = DiscoveredPi(address: 'http://192.168.1.50:8080', linked: true);
    const stranger = DiscoveredPi(address: 'http://192.168.1.60:8080', linked: true);
    final p = FakeProbes()
      ..sessionAnswer = null
      ..diagAnswer = null
      ..portState = PortState.unreachable
      ..found = [stranger, moved]
      ..keyWorks = {moved.address};
    final s = await run(p);
    expect(s.piElsewhere?.address, moved.address);
    expect(s.results[CheckId.piDiscovered]!.plain, CheckText.piMoved('192.168.1.50'));
  });

  test('a fresh card at the saved address counts as a new Pi', () async {
    final p = FakeProbes()..sessionAnswer = newSession;
    final s = await run(p);
    expect(s.piLinked, isFalse);
    expect(s.newPi, isNotNull);
    expect(s.results[CheckId.piApi]!.plain, CheckText.apiNew);
  });

  test('an old (2.0.0) Pi: /api/diag 404 → "needs an update", not a failure', () async {
    final p = FakeProbes()..diagError = const AgentException('not found', statusCode: 404);
    final s = await run(p);
    expect(s.diagUnsupported, isTrue);
    expect(s.results[CheckId.piHealth]!.status, CheckStatus.unknown);
    expect(s.results[CheckId.piHealth]!.plain, CheckText.piTooOld);
  });

  test('no health file (dev box) → health unknown, not OK', () async {
    final p = FakeProbes()..diagAnswer = diagOf(health: const PiHealth(fileStale: true));
    final s = await run(p);
    expect(s.results[CheckId.piHealth]!.status, CheckStatus.unknown);
  });

  test('SD errors / under-voltage fail the health check', () async {
    final sd = await run(FakeProbes()..diagAnswer = diagOf(health: const PiHealth(sdErrors: 3)));
    expect(sd.results[CheckId.piHealth]!.plain, CheckText.healthSd(false));
    final pw = await run(FakeProbes()..diagAnswer = diagOf(health: const PiHealth(underVoltageNow: true)));
    expect(pw.results[CheckId.piHealth]!.plain, CheckText.healthPower(false));
  });

  test('a dead Pi still shows the last known SD trouble', () {
    final s = snap(piDown: true, lastDiag: diagOf(health: const PiHealth(rootfsReadOnly: true)));
    expect(s.results[CheckId.piHealth]!.status, CheckStatus.fail);
    expect(s.results[CheckId.piHealth]!.plain, CheckText.healthSd(true));
    expect(s.sdSuspect, isTrue);
  });

  test('orders: quiet while open fails; no schedule (open_now null) is unknown; closed is ok', () async {
    final quiet = await run(FakeProbes()..diagAnswer = diagOf(lastArrivedAt: kNow.subtract(const Duration(hours: 3))));
    expect(quiet.results[CheckId.ordersFlow]!.status, CheckStatus.fail);
    final noSchedule = await run(FakeProbes()..diagAnswer = diagOf(openNow: null));
    expect(noSchedule.results[CheckId.ordersFlow]!.status, CheckStatus.unknown);
    final closed = await run(FakeProbes()..diagAnswer = diagOf(openNow: false));
    expect(closed.results[CheckId.ordersFlow]!.plain, CheckText.ordersClosed);
  });

  test('printers down are named; a probe (printer guide) overrides', () async {
    final p = FakeProbes()..diagAnswer = diagOf(printers: [kitchen, down(receipt)]);
    expect((await run(p)).results[CheckId.printers]!.plain, CheckText.printersDown(['Online']));
    p.printerResults = const [PrinterTestResult(id: 'p2', name: 'Online', ok: true)];
    expect((await run(p, probePrinters: true)).results[CheckId.printers]!.status, CheckStatus.ok);
  });

  test('tablet off Wi-Fi / no internet / main unknown', () async {
    final p = FakeProbes()
      ..deviceChecks = const DeviceChecks(wifi: false, ethernet: false)
      ..internetOk = false;
    final s = await run(p, mainUrl: '');
    expect(s.results[CheckId.tabletNetwork]!.plain, CheckText.tabletNetworkFail);
    expect(s.results[CheckId.tabletInternet]!.status, CheckStatus.fail);
    expect(s.results[CheckId.mainFromTablet]!.status, CheckStatus.unknown);
  });

  testWidgets('a hanging network can\'t hold the checks past ~8 s', (tester) async {
    final p = FakeProbes()..delay = const Duration(minutes: 5);
    CheckSnapshot? s;
    run(p).then((v) => s = v);
    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(seconds: 1));
    expect(s, isNotNull);
    expect(s!.session, isNull);
    // Drain the fake probes' long delays.
    await tester.pump(const Duration(minutes: 6));
  });
}
