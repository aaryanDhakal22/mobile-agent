import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/discovery.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/features/setup/setup_controller.dart';
import 'package:mobile_agent/features/setup/setup_flow.dart';
import 'package:mobile_agent/features/setup/setup_wizard.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

ThemeData _theme() => ThemeData(brightness: Brightness.dark, useMaterial3: true, extensions: const [QuiccPalette.dark]);

class _FixedSetup extends SetupController {
  final SetupProgress initial;
  _FixedSetup(this.initial);
  @override
  SetupProgress? build() => initial;
}

class _FakeDiscovery extends PiDiscovery {
  final List<DiscoveredPi> pis;
  _FakeDiscovery(this.pis);
  @override
  Stream<List<DiscoveredPi>> discover({String? savedAddress, bool sweep = true}) => Stream.value(pis);
}

final _t0 = DateTime.utc(2026, 10, 20, 12);

Future<ProviderContainer> _pump(WidgetTester tester, SetupProgress p, {List<Override> more = const []}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      setupProvider.overrideWith(() => _FixedSetup(p)),
      ...more,
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: _theme(), home: const SetupWizard()),
    ),
  );
  await tester.pump();
  await tester.pump();
  return c;
}

void main() {
  group('SetupFlow', () {
    test('steps advance in order and stop at done', () {
      var p = SetupProgress.start(now: _t0);
      final seen = <SetupStep>[p.step];
      while (p.step != SetupStep.done) {
        p = SetupFlow.next(p);
        seen.add(p.step);
      }
      expect(seen, SetupStep.values);
      expect(SetupFlow.next(p).step, SetupStep.done);
      expect(p.active, isTrue, reason: 'the last screen still shows until START TAKING ORDERS');
      expect(p.copyWith(finished: true).active, isFalse);
    });

    test('back never crosses sign-in once paired', () {
      final checks = SetupProgress.start(step: SetupStep.tabletChecks, now: _t0);
      expect(SetupFlow.canGoBack(checks), isFalse);
      expect(SetupFlow.back(checks).step, SetupStep.tabletChecks);
      expect(SetupFlow.back(checks.copyWith(step: SetupStep.testRing)).step, SetupStep.piReady);
      expect(SetupFlow.back(checks.copyWith(step: SetupStep.signIn)).step, SetupStep.findPi);
      expect(SetupFlow.canGoBack(checks.copyWith(step: SetupStep.welcome)), isFalse);
    });

    test('json round-trip keeps everything but never a password', () {
      final p = SetupProgress.start(now: _t0).copyWith(
        step: SetupStep.testPrint,
        piAddress: 'http://10.0.0.5:8080',
        piStore: "Lombardi's",
        piIsNew: true,
        link: const LinkSummary(store: "Lombardi's", orders: 3, waiting: 1, drivers: 6, kitchenNext: 1142),
        ringOk: true,
        printOk: {'p1': true, 'p2': false},
        checksOk: false,
      );
      final j = p.toJson();
      expect(j.toString().contains('password'), isFalse);
      final back = SetupProgress.fromJson(Map<String, dynamic>.from(j))!;
      expect(back.step, SetupStep.testPrint);
      expect(back.link!.kitchenNext, 1142);
      expect(back.printOk, {'p1': true, 'p2': false});
      expect(back.ringOk, isTrue);
      expect(back.checksOk, isFalse);
    });

    test('resume rules', () {
      // Fresh install → welcome; upgrade from 1.2.0 (paired, nothing stored) → set up.
      expect(SetupFlow.resume(null, paired: false, now: _t0)!.step, SetupStep.welcome);
      expect(SetupFlow.resume(null, paired: true, now: _t0), isNull);
      // Closed at the password form → back to Find the Pi, address kept.
      final atLogin = SetupProgress.start(step: SetupStep.signIn, address: 'http://10.0.0.5:8080', now: _t0);
      final r = SetupFlow.resume(atLogin, paired: false, now: _t0)!;
      expect(r.step, SetupStep.findPi);
      expect(r.piAddress, 'http://10.0.0.5:8080');
      // Past sign-in but the pairing is gone → Find the Pi.
      expect(
        SetupFlow.resume(atLogin.copyWith(step: SetupStep.testRing), paired: false, now: _t0)!.step,
        SetupStep.findPi,
      );
      // Still paired → same step.
      expect(
        SetupFlow.resume(atLogin.copyWith(step: SetupStep.drivers), paired: true, now: _t0)!.step,
        SetupStep.drivers,
      );
    });

    test('paired jumps to the checks with the restore summary', () {
      final p = SetupFlow.paired(
        SetupProgress.start(step: SetupStep.signIn, now: _t0),
        link: const LinkSummary(store: "Lombardi's", orders: 2),
      );
      expect(p.step, SetupStep.tabletChecks);
      expect(p.piStore, "Lombardi's");
      expect(p.link!.orders, 2);
    });
  });

  testWidgets('a new Pi asks for the manager login; a code is still possible', (tester) async {
    await _pump(
      tester,
      SetupProgress.start(step: SetupStep.signIn, address: 'http://10.0.0.5:8080', now: _t0).copyWith(piIsNew: true),
    );
    expect(find.text('This Pi is new'), findsOneWidget);
    expect(find.byKey(const ValueKey('link-user')), findsOneWidget);
    expect(find.text('SET UP PI'), findsOneWidget);
    expect(find.byKey(const ValueKey('pair-code')), findsNothing);

    await tester.tap(find.text('I have a pairing code instead'));
    await tester.pump();
    expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
    expect(find.text('JOIN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a set-up Pi asks for a code only', (tester) async {
    await _pump(
      tester,
      SetupProgress.start(
        step: SetupStep.signIn,
        address: 'http://10.0.0.5:8080',
        now: _t0,
      ).copyWith(piStore: "Lombardi's"),
    );
    expect(find.text("Join Lombardi's"), findsOneWidget);
    expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
    expect(find.text('I have a pairing code instead'), findsNothing);
  });

  testWidgets('find the Pi lists discovered Pis and picking one goes to sign in', (tester) async {
    final c = await _pump(
      tester,
      SetupProgress.start(step: SetupStep.findPi, now: _t0),
      more: [
        piDiscoveryProvider.overrideWithValue(
          _FakeDiscovery(const [
            DiscoveredPi(address: 'http://10.0.0.5:8080', linked: false, linkAvailable: true),
            DiscoveredPi(address: 'http://10.0.0.6:8080', storeName: "Lombardi's", linked: true, linkAvailable: true),
          ]),
        ),
        agentProbeProvider.overrideWithValue(
          (addr) async => addr.endsWith('.5:8080')
              ? const AgentProbe(state: 'unconfigured', linkAvailable: true)
              : const AgentProbe(state: 'locked', linkAvailable: true, storeName: "Lombardi's"),
        ),
      ],
    );
    await tester.pump();
    expect(find.text('New Pi — not set up yet'), findsOneWidget);
    expect(find.text("Lombardi's"), findsOneWidget);

    await tester.tap(find.text('New Pi — not set up yet'));
    await tester.pump();
    await tester.pump();
    final p = c.read(setupProvider)!;
    expect(p.step, SetupStep.signIn);
    expect(p.piIsNew, isTrue);
    expect(p.piAddress, 'http://10.0.0.5:8080');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every post-pairing step renders', (tester) async {
    for (final step in [
      SetupStep.welcome,
      SetupStep.tabletChecks,
      SetupStep.testRing,
      SetupStep.testPrint,
      SetupStep.times,
      SetupStep.chime,
      SetupStep.done,
    ]) {
      await _pump(tester, SetupProgress.start(step: step, now: _t0));
      expect(tester.takeException(), isNull, reason: step.name);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    }
    unawaited(Future<void>.value());
  });
}
