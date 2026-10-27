// Driver reports, follow-ups (with the Pi's 2.3 agent): clock-out answers at
// once (`report_printing`) and the report's outcome arrives as SSE
// `driver.report_printed` → an app-wide toast; the Receipts card's driver
// report text size and line spacing; `owed_rounded_cents` on a driver report.
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
import 'package:mobile_agent/core/receipt_models.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/batch/batch_pane.dart';
import 'package:mobile_agent/features/common/island.dart';
import 'package:mobile_agent/features/integration/integration_alerts.dart';
import 'package:mobile_agent/features/settings/receipt_settings_card.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';

import 'delivery_fixtures.dart';
import 'receipt_settings_test.dart' show FakeReceiptAgent;

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// The real floor controller (its SSE handling) over the delivery fixture,
/// with no network.
class _Floor extends FloorController {
  @override
  FloorState build() => deliveryFloor();

  @override
  Future<void> refresh() async {}
}

SseEvent _printed(Map<String, Object?> data) => SseEvent('driver.report_printed', jsonEncode(data));

Map<String, Object?> _report({int owed = 3448, int? rounded, List<Map<String, Object?>> lines = const []}) => {
  'batch_id': 7,
  'driver_id': 'd-juma',
  'driver_name': 'Juma',
  'deliveries': 2,
  'cash_cents': 4200,
  'tip_cents': 800,
  'tip_after_tax_cents': 752,
  'owed_cents': owed,
  'owed_rounded_cents': ?rounded,
  'lines': lines,
};

/// A card order (online, kitchen #), a cash POS check with a remark, and a
/// line from an older Pi (no street / slip fields) — listed card first, so
/// the preview must put the cash ones on top.
const _lines = <Map<String, Object?>>[
  {
    'order_id': 'o1',
    'kitchen_number': 1104,
    'customer': 'Erik D.',
    'address': '531 Stevenson Ln, Apt 2, Towson MD',
    'street': '531 Stevenson Ln',
    'source': 'online',
    'cash': false,
    'tip_cents': 300,
    'total_cents': 2500,
    'order_tip_cents': 500,
    'slip_total_cents': 3000,
  },
  {
    'order_id': '',
    'display_number': 88,
    'customer': 'Walk-in Wanda',
    'street': '12 York Rd',
    'source': 'pos',
    'cash': true,
    'cash_cents': 1700,
    'tip_cents': 200,
    'total_cents': 1700,
    'order_tip_cents': 200,
    'slip_total_cents': 1700,
    'match': 'pos_only',
    'note': 'POS only',
  },
  {
    'order_id': 'o3',
    'kitchen_number': 1107,
    'customer': 'Old Pi Olga',
    'address': '9 Bosley Ave',
    'cash': true,
    'cash_cents': 1250,
    'tip_cents': 150,
    'total_cents': 1250,
  },
];

void main() {
  group('clock-out answers at once', () {
    test('report_printing is read; absent (an older Pi) = false', () {
      final on = ClockOutResult.fromJson({'id': 'd-juma', 'name': 'Juma', 'status': 'off', 'report_printing': true});
      expect(on.reportPrinting, isTrue);
      expect(on.driver.isOff, isTrue);
      final off = ClockOutResult.fromJson({'id': 'd-juma', 'name': 'Juma', 'status': 'off'});
      expect(off.reportPrinting, isFalse);
    });

    test('uses the normal timeout, not the print timeout', () async {
      final c = AgentClient(
        baseUrl: 'http://10.0.0.5:8080',
        deviceKey: 'qagt_k',
        timeout: const Duration(milliseconds: 50),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return _json({'id': 'd-juma', 'name': 'Juma', 'status': 'off'});
        }),
      );
      await expectLater(c.clockOut('d-juma'), throwsA(anything));
    });
  });

  group('SSE driver.report_printed', () {
    test('parse: printed, rerouted, failed', () {
      final p = DriverReportPrinted.fromJson({
        'driver_id': 'd-juma',
        'driver_name': 'Juma',
        'trigger': 'clock_out',
        'printed': true,
        'printed_on': 'Front',
        'rerouted_from': 'Kitchen',
      })!;
      expect(p.printed, isTrue);
      expect(p.trigger, 'clock_out');
      expect(p.toToast().text, "Printed Juma's report on Front (Kitchen was down)");
      expect(p.toToast().severity, Severity.info);

      final plain = DriverReportPrinted.fromJson({'driver_name': 'Juma', 'printed': true, 'printed_on': 'Front'})!;
      expect(plain.reroutedFrom, isNull);
      expect(plain.toToast().text, "Printed Juma's report");

      final failed = DriverReportPrinted.fromJson({
        'driver_name': 'Juma',
        'printed': false,
        'error': 'printer offline',
        'code': 'nothing_printed',
      })!;
      expect(failed.code, 'nothing_printed');
      expect(failed.toToast().text, "Juma's report didn't print — check the receipt printer (printer offline)");
      expect(failed.toToast().severity, Severity.serious);
      expect(
        DriverReportPrinted.fromJson({
          'driver_name': 'Juma',
          'printed': false,
          'code': 'report_failed',
        })!.toToast().text,
        "Juma's report didn't print — check the receipt printer",
      );
      expect(DriverReportPrinted.fromJson('nope'), isNull);
    });

    test('the floor controller raises one toast per event', () async {
      final c = ProviderContainer(overrides: [floorProvider.overrideWith(_Floor.new)]);
      addTearDown(c.dispose);
      final f = c.read(floorProvider.notifier);
      final before = c.read(floorProvider).toasts;
      f.handleEvent(_printed({'driver_name': 'Juma', 'printed': true, 'trigger': 'clock_out'}));
      expect(c.read(floorProvider).toasts, before + 1);
      expect(c.read(floorProvider).toast!.text, "Printed Juma's report");
      // Not part of the pure reducer: a refresh's replay can't show it twice.
      expect(applySseEvent(c.read(floorProvider), _printed({'printed': true})).state.toasts, before + 1);
    });

    testWidgets('printed → "Printed Juma\'s report"; failed → a red toast', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: [floorProvider.overrideWith(_Floor.new)]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: const IslandHost(child: IntegrationIslandFeed(child: Scaffold())),
          ),
        ),
      );
      await tester.pump();
      final f = c.read(floorProvider.notifier);

      f.handleEvent(_printed({'driver_id': 'd-juma', 'driver_name': 'Juma', 'trigger': 'clock_out', 'printed': true}));
      await tester.pump();
      expect(find.text("Printed Juma's report"), findsOneWidget);

      f.handleEvent(
        _printed({
          'driver_id': 'd-juma',
          'driver_name': 'Juma',
          'trigger': 'clock_out',
          'printed': false,
          'error': 'printer offline',
          'code': 'nothing_printed',
        }),
      );
      await tester.pump();
      const failed = "Juma's report didn't print — check the receipt printer (printer offline)";
      expect(find.text(failed), findsOneWidget);
      final pill = tester.widget<IslandPill>(find.ancestor(of: find.text(failed), matching: find.byType(IslandPill)));
      expect(pill.kind, IslandKind.error);
      expect(pill.colorIn(tester.element(find.text(failed))), QuiccColors.statusVoided);

      await tester.pump(kIntegrationToastFor + const Duration(seconds: 1));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200)); // it shrinks away
      }
      expect(find.text("Printed Juma's report"), findsNothing, reason: 'fades by itself');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('ReceiptPrefs: driver report size + spacing', () {
    test('a Pi without the keys → the defaults; the PUT body still carries them', () {
      final p = ReceiptPrefs.fromJson({'kitchen_item_size': 'large', 'copies': 1});
      expect(p.driverReportSize, DriverReportSize.normal);
      expect(p.spacing, LineSpacing.none);
      final json = p.toJson();
      expect(json['driver_report_size'], 'normal');
      expect(json['spacing'], {'item_mod': 0, 'mod_mod': 0, 'item_item': 0});
    });

    test('round-trip; unknown / out-of-range values fall back', () {
      const p = ReceiptPrefs(
        driverReportSize: DriverReportSize.large,
        spacing: LineSpacing(itemMod: 8, modMod: 4, itemItem: 48),
      );
      final back = ReceiptPrefs.fromJson((jsonDecode(jsonEncode(p.toJson())) as Map).cast<String, dynamic>());
      expect(back, p);
      expect(back.hashCode, p.hashCode);
      expect(back.spacing.itemItem, 48);

      final odd = ReceiptPrefs.fromJson({
        'driver_report_size': 'huge',
        'spacing': {'item_mod': 12, 'mod_mod': 99, 'item_item': -4},
      });
      expect(odd.driverReportSize, DriverReportSize.normal);
      expect(odd.spacing, const LineSpacing(itemMod: 12));
      expect(const LineSpacing().copyWith(modMod: 60).modMod, kSpacingMaxDots, reason: 'clamped');
    });

    test('the defaults come from the Pi when it sends them', () {
      final s = ReceiptSettings.fromJson({
        'prefs': {'copies': 2},
        'defaults': {
          'driver_report_size': 'small',
          'spacing': {'item_mod': 4, 'mod_mod': 0, 'item_item': 8},
        },
      });
      expect(s.defaults.driverReportSize, DriverReportSize.small);
      expect(s.prefs.driverReportSize, DriverReportSize.small, reason: 'missing in prefs → the defaults');
      expect(s.prefs.spacing, const LineSpacing(itemMod: 4, itemItem: 8));
    });
  });

  group('Receipts card: driver reports + line spacing', () {
    Future<FakeReceiptAgent> pumpCard(WidgetTester tester, {Size size = const Size(1280, 2400)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = FakeReceiptAgent();
      final c = await deliveryContainer(
        FakeDeliveryFloor(deliveryFloor()),
        extra: [
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
            theme: darkTheme(),
            home: const Scaffold(body: SingleChildScrollView(child: ReceiptSettingsCard())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return fake;
    }

    String value(WidgetTester tester, String id) =>
        tester.widget<Text>(find.byKey(ValueKey('spacing-$id-value'))).data!;

    testWidgets('shows the slider (Normal) and the three steppers at 0', (tester) async {
      await pumpCard(tester);
      expect(find.text('Driver reports'), findsOneWidget);
      final slider = tester.widget<Slider>(find.byKey(const ValueKey('receipt-driver-report-size')));
      expect(slider.value, DriverReportSize.normal.index.toDouble());
      expect(slider.divisions, 2);
      expect(find.text('Small'), findsOneWidget);
      expect(find.text('Line spacing'), findsOneWidget);
      for (final label in ['Item→mod', 'Mod→mod', 'Item→item']) {
        expect(find.text(label), findsOneWidget);
      }
      for (final id in ['item_mod', 'mod_mod', 'item_item']) {
        expect(value(tester, id), '0');
        expect(
          tester.widget<IconButton>(find.byKey(ValueKey('spacing-$id-minus'))).onPressed,
          isNull,
          reason: 'already 0',
        );
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('steppers and the slider change the draft; SAVE sends them', (tester) async {
      final fake = await pumpCard(tester);
      await tester.tap(find.byKey(const ValueKey('spacing-item_mod-plus')));
      await tester.tap(find.byKey(const ValueKey('spacing-item_mod-plus')));
      await tester.tap(find.byKey(const ValueKey('spacing-item_item-plus')));
      await tester.pump();
      expect(value(tester, 'item_mod'), '8');
      expect(value(tester, 'item_item'), '4');
      await tester.tap(find.byKey(const ValueKey('spacing-item_mod-minus')));
      await tester.pump();
      expect(value(tester, 'item_mod'), '4');
      expect(find.text('You have changes that are not saved yet.'), findsOneWidget);

      // The slider's right end = Large.
      final slider = find.byKey(const ValueKey('receipt-driver-report-size'));
      await tester.tapAt(tester.getTopRight(slider) + Offset(-4, tester.getSize(slider).height / 2));
      await tester.pump();
      expect(tester.widget<Slider>(slider).value, DriverReportSize.large.index.toDouble());

      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();
      final body = jsonDecode(fake.calls('PUT', '/api/settings/receipt').single.body) as Map;
      expect(body['driver_report_size'], 'large');
      expect(body['spacing'], {'item_mod': 4, 'mod_mod': 0, 'item_item': 4});
      expect(body['copies'], 1, reason: 'the full object, as before');
      expect(fake.prefs['spacing'], {'item_mod': 4, 'mod_mod': 0, 'item_item': 4});
      expect(find.text('Receipt settings saved'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('+ stops at 48', (tester) async {
      await pumpCard(tester);
      for (var i = 0; i < 14; i++) {
        await tester.tap(find.byKey(const ValueKey('spacing-mod_mod-plus')));
      }
      await tester.pump();
      expect(value(tester, 'mod_mod'), '48');
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('spacing-mod_mod-plus'))).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('fits a narrow pane (the settings column) without overflow', (tester) async {
      await pumpCard(tester, size: const Size(640, 2600));
      expect(tester.takeException(), isNull);
      expect(find.text('Item→item'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('driver report preview', () {
    test('owed_rounded_cents parsed; absent = owed_cents', () {
      expect(DriverReport.fromJson(_report(owed: 3448, rounded: 3400)).owedRoundedCents, 3400);
      expect(DriverReport.fromJson(_report(owed: 3448)).owedRoundedCents, 3448);
      expect(const DriverReport(batchId: 1, driverId: 'd', driverName: 'D', owedCents: 250).owedRoundedCents, 250);
    });

    test('line: street, slip tip / total, ticket number — with fallbacks for an older Pi', () {
      final r = DriverReport.fromJson(_report(lines: _lines));
      final [online, pos, old] = r.lines;
      expect(online.ticketNumber, 1104);
      expect(online.streetOrAddress, '531 Stevenson Ln');
      expect(online.slipTipCents, 500);
      expect(online.slipTotal, 3000);
      expect(pos.ticketNumber, 88, reason: 'a POS check: its check #');
      expect(old.street, '');
      expect(old.streetOrAddress, '9 Bosley Ave');
      expect(old.orderTipCents, isNull);
      expect(old.slipTipCents, 150);
      expect(old.slipTotal, 1250);
    });

    Future<void> pumpBatch(WidgetTester tester, Map<String, Object?> report) async {
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = AgentClient(
        baseUrl: 'http://10.0.0.5:8080',
        deviceKey: 'qagt_k',
        client: MockClient((req) async => req.url.path.endsWith('/driver-reports') ? _json([report]) : _json(const [])),
      );
      final c = await deliveryContainer(
        FakeDeliveryFloor(deliveryFloor()),
        extra: [
          agentClientProvider.overrideWithValue(client),
          batchesProvider.overrideWith((ref) async => const [Batch(id: 7)]),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: darkTheme(),
            home: const Scaffold(body: BatchPane()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('Batch tab: the rounded amount first, the exact one small beside it', (tester) async {
      await pumpBatch(tester, _report(owed: 3448, rounded: 3400));
      expect(find.text('OWED TO STORE'), findsOneWidget);
      expect(find.text(r'$34.00  ($34.48)', findRichText: true), findsOneWidget);
      expect(find.textContaining('Show deliveries'), findsNothing, reason: 'no lines');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('deliveries as the slip lists them: cash first, number + street, Tip / Total, no names', (
      tester,
    ) async {
      await pumpBatch(tester, _report(rounded: 3448, lines: _lines));
      expect(find.text(r'$34.48'), findsOneWidget, reason: 'rounded = exact: one figure');
      expect(find.text('1 with a remark'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('report-lines-d-juma')));
      await tester.pump();

      for (final name in ['Erik D.', 'Walk-in Wanda', 'Old Pi Olga']) {
        expect(find.textContaining(name), findsNothing, reason: 'no customer names');
      }
      for (final n in ['#1104', '#88', '#1107']) {
        expect(find.textContaining(n), findsNothing, reason: 'numbers without "#"');
      }
      expect(find.text('1104 531 Stevenson Ln'), findsOneWidget);
      expect(find.text('88 12 York Rd'), findsOneWidget);
      expect(find.text('1107 9 Bosley Ave'), findsOneWidget, reason: 'an older Pi: the address');
      expect(find.text('POS only'), findsOneWidget);
      expect(find.text(r'Tip: $5.00'), findsOneWidget);
      expect(find.text(r'Total: $30.00'), findsOneWidget);
      expect(find.text(r'Tip: $1.50'), findsOneWidget);
      expect(find.text(r'Total: $12.50'), findsOneWidget);

      // Tip at the far left, Total at the far right of the same row.
      final tip = tester.getRect(find.text(r'Tip: $5.00'));
      final total = tester.getRect(find.text(r'Total: $30.00'));
      expect(tip.center.dy, total.center.dy);
      final line = tester.getRect(find.text('1104 531 Stevenson Ln'));
      expect(tip.left, line.left);
      expect(total.right, line.right);
      expect(total.left, greaterThan(tip.right));

      // Cash (88, 1107) above card (1104).
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('88 12 York Rd'), lessThan(y('1104 531 Stevenson Ln')));
      expect(y('1107 9 Bosley Ave'), lessThan(y('1104 531 Stevenson Ln')));
      expect(y('CASH · 2'), lessThan(y('CARD · 1')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
