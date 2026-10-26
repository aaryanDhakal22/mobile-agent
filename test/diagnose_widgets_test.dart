import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/device_platform.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/friendly_error.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/core/storage.dart';
import 'package:mobile_agent/features/diagnose/checks.dart';
import 'package:mobile_agent/features/diagnose/diagnose_entry.dart';
import 'package:mobile_agent/features/diagnose/full_check_screen.dart';
import 'package:mobile_agent/features/diagnose/guide_session.dart';
import 'package:mobile_agent/features/diagnose/guides.dart';
import 'package:mobile_agent/features/diagnose/texts.dart';
import 'package:mobile_agent/features/home/home_screen.dart';
import 'package:mobile_agent/features/home/warning_bars.dart';
import 'package:mobile_agent/features/illustrations/illustration.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag_fakes.dart';

class FakeFloor extends FloorController {
  @override
  FloorState build() => const FloorState(connection: SseStatus.connected);

  @override
  Future<void> refresh() async {}
}

/// Records reports instead of sending them.
class RecordingSender extends ReportSender {
  final sent = <DiagReport>[];
  RecordingSender(AppStorage storage) : super(storage: storage, piClient: () => null);

  @override
  Future<ReportOutcome> send(DiagReport r) async {
    sent.add(r);
    return ReportOutcome.sent;
  }

  @override
  Future<int> flushOutbox() async => 0;

  @override
  Future<void> ensureToken() async {}
}

ThemeData theme(Brightness b) => ThemeData(
  brightness: b,
  useMaterial3: true,
  extensions: [b == Brightness.dark ? QuiccPalette.dark : QuiccPalette.light],
);

late RecordingSender sender;

Future<ProviderContainer> container({FakeProbes? probes, bool paired = true}) async {
  SharedPreferences.setMockInitialValues({
    if (paired) 'agent_address': kSaved,
    if (paired) 'device_key': 'qagt_test',
    'device_name': 'Counter',
  });
  final prefs = await SharedPreferences.getInstance();
  sender = RecordingSender(AppStorage(prefs));
  return ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      diagProbesProvider.overrideWithValue(probes ?? FakeProbes()),
      floorProvider.overrideWith(FakeFloor.new),
      reportSenderProvider.overrideWithValue(sender),
    ],
  );
}

Future<ProviderContainer> pump(WidgetTester tester, Widget home, {FakeProbes? probes, bool paired = true}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = await container(probes: probes, paired: paired);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: theme(Brightness.dark), home: home),
    ),
  );
  await settle(tester);
  return c;
}

/// Lets the fake probes + controller work finish (no pumpAndSettle: the
/// drawings blink forever).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('guide screen', () {
    testWidgets('advances on TEST AGAIN and reports the fix', (tester) async {
      final probes = FakeProbes()..diagAnswer = diagOf(mainState: 'connecting', reachable: false);
      await pump(tester, const GuideScreen(start: GuideId.noOrders), probes: probes);
      expect(find.text(StepText.piCable.title), findsOneWidget);
      expect(find.text('${GuideText.stepOf} 1'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The cable was it: the Pi reconnects.
      probes.diagAnswer = diagOf();
      await tester.tap(find.text(GuideText.testAgain));
      await settle(tester);
      expect(find.text(GuideText.worked), findsOneWidget);
      expect(find.textContaining(ConclusionText.fixedPrefix), findsOneWidget);
      expect(find.text(ReportText.sent), findsOneWidget);
      expect(sender.sent, hasLength(1));
      final r = sender.sent.single.json;
      expect(r['kind'], 'guide');
      expect(r['scenario'], 'no_orders');
      expect(r['outcome'], 'fixed');
      expect(r['fixed_by'], 'pi_cable');
      expect((r['steps'] as List).single, containsPair('id', 'pi_cable'));
      expect((r['checks'] as Map).keys, contains('pi_to_main'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a settling action keeps re-checking, then moves on when its time is up', (tester) async {
      final probes = FakeProbes()..diagAnswer = diagOf(mainState: 'connecting', reachable: false);
      final c = await pump(tester, const GuideScreen(start: GuideId.noOrders), probes: probes);
      await tester.tap(find.text(GuideText.testAgain));
      await settle(tester);
      expect(find.textContaining('Checking again'), findsOneWidget);
      // pi_cable re-checks for 60 s; the next rung is the Pi restart.
      c.read(guideControllerProvider.notifier).now = () => DateTime.now().add(const Duration(minutes: 2));
      await tester.pump(const Duration(seconds: 10));
      await settle(tester);
      expect(find.text(StepText.piPowerCycle.title), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('YES / NO, then EXIT reports "abandoned"', (tester) async {
      final probes = FakeProbes()
        ..sessionAnswer = null
        ..diagAnswer = null
        ..internetOk = false
        ..portState = PortState.unreachable;
      await pump(tester, const GuideScreen(start: GuideId.piUnreachable), probes: probes);
      expect(find.text(StepText.piPowerLight.title), findsOneWidget);
      await tester.tap(find.text(GuideText.yes));
      await settle(tester);
      expect(find.text(StepText.piCable.title), findsOneWidget);

      // BACK undoes the answer.
      await tester.tap(find.text(GuideText.back));
      await settle(tester);
      expect(find.text(StepText.piPowerLight.title), findsOneWidget);
      await tester.tap(find.text(GuideText.no));
      await settle(tester);
      expect(find.text(StepText.piPowerFix.title), findsOneWidget);

      await tester.tap(find.text(GuideText.exit));
      await settle(tester);
      await tester.tap(find.text(GuideText.exit).last);
      await settle(tester);
      expect(sender.sent.single.json['outcome'], 'abandoned');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the session survives a restart', (tester) async {
      final probes = FakeProbes()
        ..sessionAnswer = null
        ..diagAnswer = null
        ..internetOk = false
        ..portState = PortState.unreachable;
      final c = await pump(tester, const GuideScreen(start: GuideId.piUnreachable), probes: probes);
      await tester.tap(find.text(GuideText.yes));
      await settle(tester);
      final saved = resumableGuideSession(c.read(storageProvider));
      expect(saved?.history.single.id, 'pi_power_light');
      expect(saved?.stepId, 'pi_cable');
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('resumed mid-swap after the setup wizard linked the new card → needs_part', () async {
    SharedPreferences.setMockInitialValues({
      'agent_address': kSaved,
      'device_key': 'qagt_new',
      'device_id': 'dev-new',
      AppStorage.kGuideSession: jsonEncode(
        GuideSession(
          id: 'g1',
          guide: GuideId.piUnreachable,
          startedAt: DateTime.now(),
          history: [
            rec('sd_swap', 'next'),
            rec('swap_unplug', 'next'),
            rec('swap_card', 'next'),
            rec('swap_plug', 'next'),
          ],
          stepId: 'swap_wait_new',
          waitStartedAt: DateTime.now(),
          params: const {'device_at_start': 'dev-old'},
        ).toJson(),
      ),
    });
    final prefs = await SharedPreferences.getInstance();
    final rs = RecordingSender(AppStorage(prefs));
    final c = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        diagProbesProvider.overrideWithValue(FakeProbes()),
        floorProvider.overrideWith(FakeFloor.new),
        reportSenderProvider.overrideWithValue(rs),
      ],
    );
    addTearDown(c.dispose);
    final g = c.read(guideControllerProvider.notifier);
    await g.resume();
    expect(c.read(guideControllerProvider).session?.stepId, 'swap_ready');
    await g.poll();
    final s = c.read(guideControllerProvider).session!;
    expect(s.conclusion?.outcome, Outcome.needsPart);
    expect(s.history.map((r) => r.id), isNot(contains('swap_back')));
    expect(rs.sent.single.json['fixed_by'], 'sd_swap');
  });

  testWidgets('Help: four guides and send diagnostics; the full check has FIX IT', (tester) async {
    final probes = FakeProbes()..diagAnswer = diagOf(printers: [kitchen, down(receipt)]);
    await pump(tester, const Scaffold(body: HelpPane()), probes: probes);
    for (final name in [
      GuideText.piUnreachableName,
      GuideText.printerName,
      GuideText.noOrdersName,
      GuideText.piSwapName,
    ]) {
      expect(find.text(name), findsOneWidget);
    }
    // The checks and tests moved to developer mode → Tests (1.6.0).
    expect(find.text(GuideText.fullCheck), findsNothing);
    expect(find.text(GuideText.pairAnother), findsNothing);
    expect(find.text(GuideText.sendDiag), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pump(tester, const FullCheckScreen(), probes: probes);
    expect(find.byType(FullCheckScreen), findsOneWidget);
    expect(find.text(CheckText.printersDown(['Online'])), findsOneWidget);
    expect(find.widgetWithText(FilledButton, GuideText.fixIt), findsWidgets);
    expect(find.text(CheckText.apiOk), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Home has a Help tab (store mode)', (tester) async {
    await pump(tester, const HomeScreen(), paired: false);
    await tester.tap(find.byKey(const ValueKey('q-button')));
    await settle(tester);
    await settle(tester);
    await settle(tester);
    await tester.tap(find.text('Help').last);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(HelpPane), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('About & diagnostics: rows, COPY, SEND', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final c = await pump(tester, const Scaffold(body: SingleChildScrollView(child: AboutDiagnosticsCard())));
    c.read(piDiagProvider.notifier).set(diagOf());
    await settle(tester);
    expect(find.text(AboutText.title), findsOneWidget);
    expect(find.text(kSaved), findsOneWidget);
    expect(find.text('2.0.1'), findsOneWidget);
    expect(find.text(AboutText.healthGood), findsOneWidget);

    await tester.tap(find.text(ReportText.copy));
    await settle(tester);
    expect(copied, contains('Pi address: $kSaved'));
    expect(copied, contains('Printer Kitchen'));

    await tester.tap(find.text(ReportText.sendToOwner));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Printer beeps');
    await tester.tap(find.text(ReportText.send));
    await settle(tester);
    expect(sender.sent.single.json['kind'], 'manual');
    expect(sender.sent.single.json['note'], 'Printer beeps');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
  });

  for (final b in Brightness.values) {
    testWidgets('every drawing paints in ${b.name} mode, with every highlight', (tester) async {
      tester.view.physicalSize = const Size(2000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(b),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Wrap(
                children: [
                  for (final art in Illustration.values)
                    for (final part in IllustrationPart.values)
                      IllustrationView(art, highlight: part, blink: part.index.isEven, width: 120),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.takeException(), isNull);
      expect(find.byType(IllustrationView), findsNWidgets(Illustration.values.length * IllustrationPart.values.length));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('warning bars: printer down, quiet orders (snooze), alarm quiet, tablet checks', (tester) async {
    final c = await pump(tester, const Scaffold(body: Column(children: [WarningBars(), Spacer()])));
    final now = DateTime.now();
    c
        .read(piDiagProvider.notifier)
        .set(
          diagOf(
            printers: [kitchen, downAt(receipt, now.subtract(const Duration(minutes: 5)))],
            lastArrivedAt: now.subtract(const Duration(hours: 3)),
          ),
        );
    c.read(deviceChecksProvider.notifier).set(const DeviceChecks(alarmVolume: 3, alarmMax: 10, notifications: false));
    await settle(tester);
    expect(find.text(WarningText.printerDown('Online')), findsOneWidget);
    expect(find.textContaining('No online orders for 3 h'), findsOneWidget);
    expect(find.text(WarningText.alarmQuiet(30)), findsOneWidget);
    expect(find.text(WarningText.checksNeedAttention), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(WarningText.snooze));
    await settle(tester);
    expect(find.textContaining('No online orders'), findsNothing);

    // A printer that only just went down doesn't warn yet.
    c.read(piDiagProvider.notifier).set(diagOf(printers: [kitchen, downAt(receipt, now)]));
    c.read(deviceChecksProvider.notifier).set(const DeviceChecks(alarmVolume: 8, alarmMax: 10));
    await settle(tester);
    expect(find.text(WarningText.printerDown('Online')), findsNothing);
    expect(find.text(WarningText.alarmQuiet(80)), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('printer FIX IT opens the printer guide on that printer', (tester) async {
    final probes = FakeProbes()..diagAnswer = diagOf(printers: [kitchen, down(receipt)]);
    final c = await pump(
      tester,
      const Scaffold(body: Column(children: [WarningBars(), Spacer()])),
      probes: probes,
    );
    c
        .read(piDiagProvider.notifier)
        .set(
          diagOf(
            printers: [kitchen, downAt(receipt, DateTime.now().subtract(const Duration(minutes: 2)))],
            lastArrivedAt: DateTime.now(),
          ),
        );
    await settle(tester);
    await tester.tap(find.text(GuideText.fixIt));
    await settle(tester);
    expect(find.byType(GuideScreen), findsOneWidget);
    expect(find.textContaining("Is the Online printer's power light on?"), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
