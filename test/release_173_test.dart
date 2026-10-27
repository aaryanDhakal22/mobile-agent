// Quibase 1.7.3 (with agent 2.2.3): PRINT REPORT on every driver row (one
// driver's report for the open batch so far), clock-out printing the report
// (`report_print` on the clock-out answer), and the driver report's POS
// cross-check fields.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/drivers/drivers_pane.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';

import 'delivery_fixtures.dart';

/// A Pi answering [handler]; records each request as "METHOD path".
(AgentClient, List<String>, List<bool>) _pi(http.Response Function(http.Request req) handler) {
  final calls = <String>[];
  final revoked = <bool>[];
  final client = AgentClient(
    baseUrl: 'http://10.0.0.5:8080',
    deviceKey: 'qagt_k',
    client: MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      return handler(req);
    }),
    onDeviceRevoked: () => revoked.add(true),
  );
  return (client, calls, revoked);
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

const _juma = {
  'id': 'd-juma',
  'name': 'Juma',
  'position': 1,
  'status': 'available',
  'clocked_in_at': '2026-10-26T16:00:00Z',
  'deliveries': 3,
};

const _roster = [
  _juma,
  {'id': 'd-lee', 'name': 'Lee', 'position': 2, 'status': 'off', 'deliveries': 0},
  {'id': 'd-sam', 'name': 'Sam', 'position': 3, 'status': 'out', 'clocked_in_at': '2026-10-26T16:05:00Z', 'deliveries': 1},
];

Map<String, Object?> _report({bool withPos = true}) => {
  'batch_id': 7,
  'driver_id': 'd-juma',
  'driver_name': 'Juma',
  'deliveries': 2,
  'cash_cents': 4200,
  'tip_cents': 800,
  'tip_after_tax_cents': 752,
  'owed_cents': 3448,
  'lines': [
    {
      'order_id': 'o1',
      'kitchen_number': 1104,
      'customer': 'Erik D.',
      'address': '12 Avenue A',
      'tip_cents': 500,
      'cash': true,
      'cash_cents': 2500,
      'total_cents': 2500,
      if (withPos) ...{
        'ext_ref': 'st-88',
        'display_number': 88,
        'source': 'online',
        'match': 'both',
        'out_at': '2026-10-26T17:00:00Z',
        'delivered_at': '2026-10-26T17:20:00Z',
      },
    },
    if (withPos)
      {
        'order_id': '',
        'display_number': 91,
        'customer': 'Walk-in',
        'tip_cents': 300,
        'cash': true,
        'cash_cents': 1700,
        'total_cents': 1700,
        'source': 'pos',
        'match': 'pos_only',
        'note': 'POS only',
      },
  ],
  if (withPos) ...{
    'driver_pos_number': ' 12 ',
    'pos': {'checked': false, 'as_of': '2026-10-26T17:30:00Z', 'note': 'hub offline'},
    'notes': ['Quibase had Ali on #1107', ''],
  },
};

/// The real floor controller (its clock-out / print calls hit the mock Pi)
/// over a fixed roster.
class _Floor extends FloorController {
  @override
  FloorState build() => deliveryFloor().copyWith(drivers: [for (final d in _roster) Driver.fromJson(d)]);

  @override
  Future<void> refresh() async {}
}

/// The Drivers pane at the tablet's size (1280×800 minus the rail).
Future<ProviderContainer> _pumpPane(WidgetTester tester, AgentClient client) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = await deliveryContainer(
    FakeDeliveryFloor(deliveryFloor()),
    extra: [floorProvider.overrideWith(_Floor.new), agentClientProvider.overrideWithValue(client)],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(
          body: Row(
            children: [
              SizedBox(width: 105),
              Expanded(child: DriversPane()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 500));
}

Color? _snackColor(WidgetTester tester) => tester.widget<SnackBar>(find.byType(SnackBar)).backgroundColor;

void main() {
  group('api: one driver\'s report', () {
    test('200: driver, printer, reroute and the report', () async {
      final (c, calls, _) = _pi(
        (_) => _json({
          'driver_id': 'd-juma',
          'driver_name': 'Juma',
          'printed_on': 'Front',
          'rerouted_from': 'Kitchen',
          'report': _report(),
        }),
      );
      final r = await c.printDriverReport('d-juma');
      expect(calls, ['POST /api/drivers/d-juma/report/print']);
      expect(r.driverId, 'd-juma');
      expect(r.driverName, 'Juma');
      expect(r.printedOn, 'Front');
      expect(r.reroutedFrom, 'Kitchen');
      expect(r.report!.owedCents, 3448);
      expect(r.report!.lines, hasLength(2));

      final (c2, _, _) = _pi((_) => _json({'driver_id': 'd-juma', 'driver_name': 'Juma', 'printed_on': 'Front'}));
      final plain = await c2.printDriverReport('d-juma');
      expect(plain.reroutedFrom, isNull, reason: 'omitted unless it failed over');
      expect(plain.report, isNull);
    });

    test('502 nothing_printed / 503 printing_unavailable / 404 driver_not_found keep their codes', () async {
      for (final (status, code) in [(502, 'nothing_printed'), (503, 'printing_unavailable'), (404, 'driver_not_found')]) {
        final (c, _, revoked) = _pi((_) => _json({'error': 'x', 'code': code, 'driver_name': 'Juma'}, status));
        await expectLater(
          c.printDriverReport('d-juma'),
          throwsA(isA<AgentException>().having((e) => e.code, 'code', code).having((e) => e.statusCode, 'status', status)),
        );
        expect(revoked, isEmpty);
      }
    });

    test('an older Pi (no route): plain 404, not_found 404 or 405 → needs an update; never unpairs', () async {
      for (final resp in [
        () => http.Response('404 page not found\n', 404),
        () => _json({'error': 'not found', 'code': 'not_found'}, 404),
        () => _json({'error': 'not found'}, 404),
        () => http.Response('Method Not Allowed', 405),
      ]) {
        final (c, _, revoked) = _pi((_) => resp());
        await expectLater(
          c.printDriverReport('d-juma'),
          throwsA(isA<AgentException>().having((e) => e.code, 'code', kDriverReportUnsupported)),
        );
        expect(revoked, isEmpty);
      }
      // Even a device_required 401 from it doesn't unpair the tablet.
      final (c, _, revoked) = _pi((_) => _json({'error': 'device', 'code': 'device_required'}, 401));
      await expectLater(c.printDriverReport('d-juma'), throwsA(isA<AgentException>()));
      expect(revoked, isEmpty);
    });
  });

  group('api: clock-out', () {
    test('without report_print (older Pi): the driver, nothing else', () async {
      final (c, calls, _) = _pi((_) => _json({..._juma, 'status': 'off'}));
      final r = await c.clockOut('d-juma');
      expect(calls, ['POST /api/drivers/d-juma/clock-out']);
      expect(r.driver.id, 'd-juma');
      expect(r.driver.isOff, isTrue);
      expect(r.reportPrint, isNull);
    });

    test('with report_print: printed (and rerouted) or not', () async {
      final (c, _, _) = _pi(
        (_) => _json({
          ..._juma,
          'status': 'off',
          'report_print': {'printed': true, 'driver_name': 'Juma', 'printed_on': 'Front', 'rerouted_from': 'Kitchen'},
        }),
      );
      final r = await c.clockOut('d-juma');
      expect(r.driver.name, 'Juma');
      expect(r.driver.isOff, isTrue);
      expect(r.reportPrint!.printed, isTrue);
      expect(r.reportPrint!.printedOn, 'Front');
      expect(r.reportPrint!.reroutedFrom, 'Kitchen');

      final (c2, _, _) = _pi(
        (_) => _json({
          ..._juma,
          'status': 'off',
          'report_print': {'printed': false, 'driver_name': 'Juma', 'error': 'printer offline', 'code': 'nothing_printed'},
        }),
      );
      final r2 = await c2.clockOut('d-juma');
      expect(r2.reportPrint!.printed, isFalse);
      expect(r2.reportPrint!.error, 'printer offline');
      expect(r2.reportPrint!.code, 'nothing_printed');
      expect(r2.reportPrint!.reroutedFrom, isNull);
    });

    test('a 409 still throws as before', () async {
      final (c, _, _) = _pi((_) => _json({'error': 'no', 'code': 'driver_not_available'}, 409));
      await expectLater(
        c.clockOut('d-sam'),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', 'driver_not_available')),
      );
    });
  });

  group('driver report: POS cross-check fields', () {
    test('parse when present', () {
      final r = DriverReport.fromJson(_report());
      expect(r.driverPosNumber, '12');
      expect(r.pos!.checked, isFalse);
      expect(r.pos!.asOf, DateTime.utc(2026, 10, 26, 17, 30));
      expect(r.pos!.note, 'hub offline');
      expect(r.notes, ['Quibase had Ali on #1107']);
      final a = r.lines[0];
      expect(a.extRef, 'st-88');
      expect(a.displayNumber, 88);
      expect(a.source, 'online');
      expect(a.match, DriverReportMatch.both);
      expect(a.outAt, DateTime.utc(2026, 10, 26, 17));
      expect(a.deliveredAt, DateTime.utc(2026, 10, 26, 17, 20));
      final b = r.lines[1];
      expect(b.match, DriverReportMatch.posOnly);
      expect(b.note, 'POS only');
      expect(b.kitchenNumber, isNull);
      expect(DriverReportMatch.parse('quibase_only'), DriverReportMatch.quibaseOnly);
    });

    test('an older Pi: defaults', () {
      final r = DriverReport.fromJson(_report(withPos: false));
      expect(r.driverPosNumber, isNull);
      expect(r.pos, isNull);
      expect(r.notes, isEmpty);
      final l = r.lines.single;
      expect(l.extRef, '');
      expect(l.displayNumber, isNull);
      expect(l.source, '');
      expect(l.match, DriverReportMatch.both);
      expect(l.note, '');
      expect(l.outAt, isNull);
      expect(l.deliveredAt, isNull);
      expect(l.kitchenNumber, 1104);
    });
  });

  group('messages', () {
    test('printed, rerouted, clock-out', () {
      expect(driverReportPrintedMessage('Juma'), "Printed Juma's report");
      expect(
        driverReportPrintedMessage('Juma', printedOn: 'Front', reroutedFrom: 'Kitchen'),
        "Printed Juma's report on Front (Kitchen was down)",
      );
      expect(clockedOutMessage('Juma', null), ('Juma clocked out', false));
      expect(
        clockedOutMessage('Juma', const ReportPrintOutcome(printed: true, driverName: 'Juma')),
        ("Juma clocked out · Printed Juma's report", false),
      );
      expect(
        clockedOutMessage('Juma', const ReportPrintOutcome(printed: false, error: 'printer offline')),
        ("Juma clocked out — report didn't print: printer offline", true),
      );
      expect(
        clockedOutMessage('Juma', const ReportPrintOutcome(printed: false)),
        ("Juma clocked out — report didn't print", true),
      );
    });
  });

  group('Drivers pane', () {
    testWidgets('PRINT REPORT on every driver row, whatever the status; tap prints that driver\'s', (tester) async {
      final (client, calls, _) = _pi((req) {
        if (req.url.path.endsWith('/report/print')) {
          return _json({'driver_id': 'd-juma', 'driver_name': 'Juma', 'printed_on': 'Front', 'report': _report()});
        }
        return _json(_roster);
      });
      await _pumpPane(tester, client);
      expect(find.text('PRINT REPORT'), findsNWidgets(3));
      for (final id in ['d-juma', 'd-lee', 'd-sam']) {
        expect(find.byKey(ValueKey('print-report-$id')), findsOneWidget);
      }

      await tester.tap(find.byKey(const ValueKey('print-report-d-juma')));
      await _settle(tester);
      expect(calls, contains('POST /api/drivers/d-juma/report/print'));
      expect(find.text("Printed Juma's report"), findsOneWidget);
      expect(_snackColor(tester), isNot(QuiccColors.statusVoided));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('rerouted: says where it printed', (tester) async {
      final (client, _, _) = _pi(
        (_) => _json({'driver_id': 'd-juma', 'driver_name': 'Juma', 'printed_on': 'Front', 'rerouted_from': 'Kitchen'}),
      );
      await _pumpPane(tester, client);
      await tester.tap(find.byKey(const ValueKey('print-report-d-juma')));
      await _settle(tester);
      expect(find.text("Printed Juma's report on Front (Kitchen was down)"), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('502 / 503 / an older Pi: plain error toasts; the tablet stays paired', (tester) async {
      for (final (resp, text) in [
        (
          () => _json({'error': 'printer offline', 'code': 'nothing_printed', 'driver_name': 'Juma'}, 502),
          "Juma's report didn't print — check the receipt printer.",
        ),
        (
          () => _json({'error': 'no printers', 'code': 'printing_unavailable'}, 503),
          'No printers are set up on the Pi — nothing to print on.',
        ),
        (() => http.Response('404 page not found\n', 404), "This Pi needs an update to print one driver's report."),
      ]) {
        final (client, _, revoked) = _pi((_) => resp());
        await _pumpPane(tester, client);
        await tester.tap(find.byKey(const ValueKey('print-report-d-juma')));
        await _settle(tester);
        expect(find.text(text), findsOneWidget);
        expect(_snackColor(tester), QuiccColors.statusVoided);
        expect(revoked, isEmpty);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('clock-out that printed the report says so', (tester) async {
      final (client, calls, _) = _pi((req) {
        if (req.url.path.endsWith('/clock-out')) {
          return _json({
            ..._juma,
            'status': 'off',
            'report_print': {'printed': true, 'driver_name': 'Juma', 'printed_on': 'Front'},
          });
        }
        return _json(_roster);
      });
      await _pumpPane(tester, client);
      await tester.tap(find.text('CLOCK OUT').first);
      await _settle(tester);
      expect(calls, contains('POST /api/drivers/d-juma/clock-out'));
      expect(find.text("Juma clocked out · Printed Juma's report"), findsOneWidget);
      expect(_snackColor(tester), isNot(QuiccColors.statusVoided));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("clock-out whose report didn't print: an error toast with why", (tester) async {
      final (client, _, _) = _pi((req) {
        if (req.url.path.endsWith('/clock-out')) {
          return _json({
            ..._juma,
            'status': 'off',
            'report_print': {
              'printed': false,
              'driver_name': 'Juma',
              'error': 'printer offline',
              'code': 'nothing_printed',
            },
          });
        }
        return _json(_roster);
      });
      await _pumpPane(tester, client);
      await tester.tap(find.text('CLOCK OUT').first);
      await _settle(tester);
      expect(find.text("Juma clocked out — report didn't print: printer offline"), findsOneWidget);
      expect(_snackColor(tester), QuiccColors.statusVoided);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('clock-out on an older Pi: as before', (tester) async {
      final (client, _, _) = _pi(
        (req) => req.url.path.endsWith('/clock-out') ? _json({..._juma, 'status': 'off'}) : _json(_roster),
      );
      await _pumpPane(tester, client);
      await tester.tap(find.text('CLOCK OUT').first);
      await _settle(tester);
      expect(find.text('Juma clocked out'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
