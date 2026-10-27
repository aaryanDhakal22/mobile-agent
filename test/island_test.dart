// The notification island (1.9.0): every toast is a small pill top-right,
// not a full-width bar at the bottom over SEND OUT and the driver button.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/format.dart';
import 'package:mobile_agent/core/friendly_error.dart';
import 'package:mobile_agent/core/motion.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/common/island.dart';
import 'package:mobile_agent/features/common/widgets.dart';
import 'package:mobile_agent/features/integration/integration_alerts.dart';
import 'package:mobile_agent/theme/quicc_colors.dart';
import 'package:mobile_agent/theme/quicc_theme.dart';

import 'delivery_fixtures.dart';

const _screen = Size(1280, 800);

class _MotionOff extends MotionNotifier {
  @override
  MotionSettings build() => const MotionSettings(enabled: false);
}

class _MotionOn extends MotionNotifier {
  @override
  MotionSettings build() => const MotionSettings();
}

class _Floor extends FloorController {
  @override
  FloorState build() => deliveryFloor();

  @override
  Future<void> refresh() async {}
}

/// What the screen under the island counts: SEND OUT presses (where the old
/// snackbar sat, bottom centre) and taps that reach the background.
class _Taps {
  int sendOut = 0;
  final background = <Offset>[];
}

/// A tablet-sized app with the island over every route (as `app.dart`
/// mounts it), a SEND OUT bar at the bottom and a background that records
/// taps. [show] runs on the "go" button.
Future<(_Taps, BuildContext)> _pump(
  WidgetTester tester, {
  bool motion = true,
  List<Override> overrides = const [],
  bool feed = false,
  bool host = true,
}) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final taps = _Taps();
  late BuildContext ctx;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [motionProvider.overrideWith(motion ? _MotionOn.new : _MotionOff.new), ...overrides],
      child: MaterialApp(
        theme: QuiccTheme.dark(),
        builder: host
            ? (context, child) => IslandHost(child: feed ? IntegrationIslandFeed(child: child!) : child!)
            : null,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => taps.background.add(d.globalPosition),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: SizedBox(
                        width: 900,
                        height: 56,
                        child: FilledButton(onPressed: () => taps.sendOut++, child: const Text('SEND OUT')),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (taps, ctx);
}

/// Lets a pill pop in / shrink away.
Future<void> _frames(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final _pills = find.byType(IslandPill);

void main() {
  testWidgets('toast(): a small pill in the top-right corner', (tester) async {
    final (_, ctx) = await _pump(tester);
    toast(ctx, 'Juma is out — 3 orders', rightInset: 160);
    await _frames(tester);
    expect(_pills, findsOneWidget);
    expect(find.text('Juma is out — 3 orders'), findsOneWidget);
    final r = tester.getRect(_pills);
    expect(r.right, closeTo(_screen.width - kIslandRight, 1));
    expect(r.top, closeTo(kIslandTop, 1));
    expect(r.width, lessThanOrEqualTo(380));
    expect(r.height, lessThan(60), reason: 'one line');
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.widget<IslandPill>(_pills).kind, IslandKind.info);
    toast(ctx, 'Not saved', error: true);
    await _frames(tester);
    expect(tester.widget<IslandPill>(_pills.first).kind, IslandKind.error);
    expect(tester.widget<IslandPill>(_pills.first).colorIn(ctx), QuiccColors.statusVoided);
  });

  testWidgets('it goes by itself: info ~2.5 s, warn ~4 s, error ~6 s', (tester) async {
    final (_, ctx) = await _pump(tester);
    final island = Island.maybeOf(ctx)!;
    toast(ctx, 'info');
    island.show('warn', kind: IslandKind.warn);
    toast(ctx, 'error', error: true);
    await _frames(tester);
    expect(_pills, findsNWidgets(3));
    await tester.pump(const Duration(milliseconds: 2000)); // 2.6 s
    await _frames(tester);
    expect(find.text('info'), findsNothing);
    expect(find.text('warn'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1000)); // 4.2 s
    await _frames(tester);
    expect(find.text('warn'), findsNothing);
    expect(find.text('error'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1000)); // 5.8 s
    expect(find.text('error'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await _frames(tester);
    expect(_pills, findsNothing);
  });

  testWidgets('tap or swipe right puts it away; the same text again is one pill', (tester) async {
    final (_, ctx) = await _pump(tester);
    toast(ctx, 'Undone — Juma is out again');
    toast(ctx, 'Undone — Juma is out again');
    await _frames(tester);
    expect(_pills, findsOneWidget);
    await tester.tap(_pills);
    await _frames(tester);
    expect(_pills, findsNothing);

    toast(ctx, 'Swipe me');
    await _frames(tester);
    await tester.drag(_pills, const Offset(320, 0));
    await _frames(tester);
    expect(_pills, findsNothing);
  });

  testWidgets('at most 3, newest on top', (tester) async {
    final (_, ctx) = await _pump(tester);
    for (var i = 1; i <= 5; i++) {
      toast(ctx, 'notice $i');
      await tester.pump(const Duration(milliseconds: 50));
    }
    await _frames(tester);
    expect(_pills, findsNWidgets(3));
    expect(find.text('notice 1'), findsNothing);
    expect(find.text('notice 2'), findsNothing);
    final ys = [
      for (final t in ['notice 5', 'notice 4', 'notice 3']) tester.getTopLeft(find.text(t)).dy,
    ];
    expect(ys[0], lessThan(ys[1]));
    expect(ys[1], lessThan(ys[2]));
  });

  testWidgets('an error pill: lead + what to do, DETAILS and FIX IT inside it', (tester) async {
    final opened = <GuideId>[];
    final before = openGuideHook;
    openGuideHook = (_, g) => opened.add(g);
    addTearDown(() => openGuideHook = before);

    final (_, ctx) = await _pump(tester);
    toastError(
      ctx,
      const AgentException('nothing printed', statusCode: 502, code: 'nothing_printed'),
      lead: 'Not reprinted',
    );
    await _frames(tester);
    final pill = find.ancestor(of: find.text('Not reprinted'), matching: _pills);
    expect(pill, findsOneWidget);
    expect(find.descendant(of: pill, matching: find.text('DETAILS')), findsOneWidget);
    expect(find.descendant(of: pill, matching: find.text('FIX IT')), findsOneWidget);
    expect(tester.getRect(pill).width, lessThanOrEqualTo(kIslandMaxWidthWithActions));

    await tester.tap(find.text('FIX IT'));
    expect(opened, [GuideId.printer]);
    await _frames(tester);
    expect(_pills, findsNothing, reason: 'a button puts the pill away');

    toastError(
      ctx,
      const AgentException('nothing printed', statusCode: 502, code: 'nothing_printed'),
      lead: 'Not reprinted',
    );
    await _frames(tester);
    await tester.tap(find.text('DETAILS'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('nothing_printed'), findsOneWidget);
  });

  testWidgets('the hub\'s toasts (SSE integration.toast) come into the island', (tester) async {
    final (_, _) = await _pump(tester, feed: true, overrides: [floorProvider.overrideWith(_Floor.new)]);
    final c = ProviderScope.containerOf(tester.element(find.byType(IntegrationIslandFeed)));
    c
        .read(floorProvider.notifier)
        .handleEvent(
          SseEvent('integration.toast', jsonEncode({'text': 'POS says #12 — not clocked in', 'severity': 'warn'})),
        );
    await _frames(tester);
    final pill = find.ancestor(of: find.text('POS says #12 — not clocked in'), matching: _pills);
    expect(pill, findsOneWidget);
    expect(tester.widget<IslandPill>(pill).kind, IslandKind.warn);
    expect(tester.getRect(pill).right, closeTo(_screen.width - kIslandRight, 1));
    // Hub toasts stay a little longer than the island's own notices.
    await tester.pump(kIntegrationToastFor - const Duration(seconds: 1));
    expect(pill, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await _frames(tester);
    expect(_pills, findsNothing);
  });

  testWidgets('Motion on pops it in with a scale; Motion off fades only — no transforms', (tester) async {
    var (_, ctx) = await _pump(tester);
    toast(ctx, 'bubbly');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.descendant(of: find.byKey(const ValueKey('island')), matching: find.byType(Transform)), findsWidgets);
    await tester.pumpWidget(const SizedBox());

    (_, ctx) = await _pump(tester, motion: false);
    toast(ctx, 'quiet');
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      final island = find.byKey(const ValueKey('island'));
      expect(island, findsOneWidget);
      expect(find.descendant(of: island, matching: find.byType(Transform)), findsNothing);
      expect(find.descendant(of: island, matching: find.byType(ScaleTransition)), findsNothing);
      expect(find.descendant(of: island, matching: find.byType(Opacity)), findsWidgets);
    }
    await tester.tap(_pills);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.descendant(of: find.byKey(const ValueKey('island')), matching: find.byType(Transform)), findsNothing);
    await _frames(tester);
    expect(_pills, findsNothing);
  });

  testWidgets('the rest of the screen stays tappable while a pill is up', (tester) async {
    final (taps, ctx) = await _pump(tester);
    toast(ctx, 'Juma is out — 3 orders');
    toastError(ctx, const AgentException('x', statusCode: 502, code: 'nothing_printed'), lead: 'Not sent out');
    await _frames(tester);
    expect(_pills, findsNWidgets(2));

    // SEND OUT, where the old snackbar sat.
    await tester.tap(find.text('SEND OUT'));
    expect(taps.sendOut, 1);
    // Just left of the pill, on the same line: the screen under it.
    final r = tester.getRect(_pills.first);
    await tester.tapAt(Offset(r.left - 24, r.center.dy));
    // Between the pills' right edge and the screen edge, and below them.
    await tester.tapAt(Offset(_screen.width - 6, r.center.dy));
    await tester.tapAt(Offset(r.center.dx, tester.getRect(_pills.last).bottom + 24));
    expect(taps.background, hasLength(3));
    // The pill itself takes its own taps (and goes away).
    await tester.tapAt(Offset(r.left + 24, r.center.dy));
    expect(taps.background, hasLength(3));
    await _frames(tester);
    expect(_pills, findsOneWidget);
  });

  testWidgets('no host above (a bare MaterialApp): the root Overlay gets one', (tester) async {
    final (_, ctx) = await _pump(tester, host: false);
    toast(ctx, 'Address chosen');
    await _frames(tester);
    expect(_pills, findsOneWidget);
    expect(tester.getRect(_pills).right, closeTo(_screen.width - kIslandRight, 1));
    await tester.pump(const Duration(seconds: 3));
    await _frames(tester);
    expect(_pills, findsNothing);
  });
}
