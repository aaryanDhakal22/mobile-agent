import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../core/providers.dart';
import '../../core/sse.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../batch/batch_pane.dart';
import '../deliveries/deliveries_pane.dart';
import '../dev/config_screen.dart';
import '../dev/connections_screen.dart';
import '../dev/dev_gate.dart';
import '../dev/dev_log.dart';
import '../dev/logs_screen.dart';
import '../dev/pos_hub_screen.dart';
import '../dev/tests_screen.dart';
import '../diagnose/diagnose_entry.dart';
import '../diagnose/guide_session.dart';
import '../drivers/driver_fab.dart';
import '../drivers/drivers_pane.dart';
import '../history/history_pane.dart';
import '../integration/integration_alerts.dart';
import '../kitchen/kitchen_pane.dart';
import '../maps/map_layers.dart';
import '../maps/runs_map_pane.dart';
import '../printers/printers_pane.dart';
import '../settings/store_settings_screen.dart';
import '../update/updater.dart';
import '../update/updates_screen.dart';
import 'home_nav.dart';
import 'idle_kitchen.dart';
import 'pi_unreachable_banner.dart';
import 'q_button.dart';
import 'quicc_nav_rail.dart';
import 'rail_modes.dart';
import 'warning_bars.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

/// The shell: the rail (q + the current mode's destinations) and the pane.
/// Kitchen is the start screen — new orders ring full-screen over whatever is
/// showing (AlarmHost). What shows follows [homeNavProvider], so anything
/// (the driver button, a redirect) can send staff somewhere; the rail
/// switches to the mode that holds it. Developer screens need the manager
/// login: asked for while locked, they are ignored.
class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  late HomeDestination _shown;

  /// Where each mode was last, so the q brings you back there.
  final Map<RailMode, HomeDestination> _last = {
    RailMode.kitchen: HomeDestination.kitchen,
    RailMode.store: HomeDestination.batch,
    RailMode.dev: HomeDestination.connections,
  };

  RailMode get _mode => railModeOf(_shown);

  /// The Map pane is built once — as soon as there is a map to draw, or on
  /// the first visit — and then kept (1.7.1): see [_KeptMap].
  bool _mapKept = false;

  /// The minute without a touch before going back to Kitchen (1.7.1).
  Timer? _idle;

  @override
  void initState() {
    super.initState();
    installGuideHook();
    final asked = ref.read(homeNavProvider);
    _shown = _allowed(asked) ? asked : HomeDestination.kitchen;
    _last[railModeOf(_shown)] = _shown;
    ref.listenManual(homeNavProvider, (_, next) => _follow(next));
    ref.listenManual(devGateProvider, (_, unlocked) {
      if (!unlocked && _mode == RailMode.dev) ref.read(homeNavProvider.notifier).go(_last[RailMode.kitchen]!);
    });
    ref.listenManual(floorProvider, (prev, next) => ref.read(devLogProvider.notifier).observeFloor(prev, next));
    // 1.7.1: back to Kitchen after a minute without a touch or a key.
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    ref.listenManual(idleTouchProvider, (_, _) => _armIdle());
    ref.listenManual(idleKitchenProvider, (_, _) => _armIdle());
    _armIdle();
    // A guide was running when the app stopped (e.g. mid SD-card swap):
    // carry on with it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && resumableGuideSession(ref.read(storageProvider)) != null) resumeGuide(context);
    });
  }

  @override
  void dispose() {
    _idle?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent _) {
    _armIdle();
    return false;
  }

  /// The keyboard opened or closed (or the screen changed): the minute
  /// starts again — so it counts from when the keyboard went away.
  @override
  void didChangeMetrics() => _armIdle();

  void _armIdle() {
    _idle?.cancel();
    _idle = mounted && ref.read(idleKitchenProvider) ? Timer(kIdleToKitchen, _onIdle) : null;
  }

  /// Nothing to go back over: the ring / alert is up (it sits above anyway),
  /// the update prompt or Android's install screen, or someone is typing.
  /// (The setup wizard replaces this screen, so its minute never runs then.)
  bool _idleBlocked() {
    final alarm = ref.read(alarmProvider);
    if (alarm.ringing && alarm.visible) return true;
    final u = ref.read(updaterProvider);
    if (u.phase == UpdatePhase.installing) return true;
    if (u.available && u.wantsTap && !u.snoozed(timeNow()) && floorIsQuiet(ref.read(floorProvider), alarm.ringing)) {
      return true;
    }
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return true;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return true;
    final typing = FocusManager.instance.primaryFocus?.context;
    if (typing != null &&
        (typing.widget is EditableText || typing.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return true;
    }
    return false;
  }

  void _onIdle() {
    _idle = null;
    if (!mounted) return;
    if (_idleBlocked()) {
      _armIdle(); // another minute
      return;
    }
    final nav = Navigator.maybeOf(context);
    final covered = nav?.canPop() ?? false;
    if (_shown == HomeDestination.kitchen && !covered) return;
    // Dialogs, sheets and screens opened from here close first.
    nav?.popUntil((r) => r.isFirst);
    ref.read(fobCollapseProvider.notifier).state++;
    final wasDev = _mode == RailMode.dev;
    _go(HomeDestination.kitchen);
    if (wasDev) ref.read(devGateProvider.notifier).lock(why: '1 min idle');
    ref.read(devLogProvider.notifier).add(DevLogKind.app, 'Back to Kitchen (1 min without a touch)');
  }

  bool _allowed(HomeDestination d) => railModeOf(d) != RailMode.dev || ref.read(devGateProvider);

  void _follow(HomeDestination next) {
    if (!mounted || next == _shown) return;
    if (!_allowed(next)) {
      // Developer screens stay shut while locked: put the request back.
      ref.read(homeNavProvider.notifier).go(_shown);
      return;
    }
    final from = _mode;
    setState(() {
      _shown = next;
      _last[railModeOf(next)] = next;
    });
    // A new screen (also one opened for staff, e.g. by the driver button):
    // its own minute.
    _armIdle();
    if (railModeOf(next) != from) {
      ref.read(devLogProvider.notifier).add(DevLogKind.app, switch (railModeOf(next)) {
        RailMode.kitchen => 'Kitchen mode',
        RailMode.store => 'Store mode',
        RailMode.dev => 'Developer mode',
      });
    }
  }

  void _go(HomeDestination d) => ref.read(homeNavProvider.notifier).go(d);

  void _onQTap() {
    switch (_mode) {
      case RailMode.kitchen:
        _go(_last[RailMode.store]!);
      case RailMode.store:
        _go(_last[RailMode.kitchen]!);
      case RailMode.dev:
        _go(_last[RailMode.kitchen]!);
        ref.read(devGateProvider.notifier).lock();
    }
  }

  Future<void> _onQLongPress() async {
    if (_mode == RailMode.dev) return;
    if (ref.read(devGateProvider) || await showDevPinSheet(context)) {
      if (mounted) _go(_last[RailMode.dev]!);
    }
  }

  QuiccNavDestination _dest(HomeDestination d, {int badge = 0}) {
    final look = lookOf(d);
    return QuiccNavDestination(icon: look.icon, selectedIcon: look.selectedIcon, label: look.label, badge: badge);
  }

  @override
  Widget build(BuildContext context) {
    final kitchen = ref.watch(floorProvider.select((s) => s.kitchen.length));
    // Matches the Deliveries pane's "Unassigned · N".
    final unassigned = ref.watch(floorProvider.select((s) => s.unassignedDeliveries.length));
    // A downloaded update not installed yet: a dot on the q, a badge on Updates.
    final updateWaiting = ref.watch(
      updaterProvider.select((u) => u.available && u.phase != UpdatePhase.downloading && u.phase != UpdatePhase.installing),
    );
    final motion = Motion.of(context, ref);
    final mode = _mode;
    final list = kRailDestinations[mode]!;
    final mapShown = _shown == HomeDestination.map;
    _mapKept = _mapKept || mapShown || ref.watch(mapSourceProvider.select((m) => m != null));

    return Scaffold(
      // Don't shrink the body for the keyboard — the rail's evenly spread
      // items would get squashed.
      resizeToAvoidBottomInset: false,
      body: Listener(
        // Any touch restarts the minute back to Kitchen (the app's shell
        // listener covers dialogs and screens on top).
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _armIdle(),
        child: DiagPoller(
          child: Row(
            children: [
              QuiccNavRail(
                modeKey: mode,
                motion: motion,
                selectedIndex: list.indexOf(_shown),
                onDestinationSelected: (i) => _go(list[i]),
                header: Column(
                  children: [
                    QButton(
                      mode: mode,
                      motion: motion,
                      onTap: _onQTap,
                      onLongPress: _onQLongPress,
                      dot: updateWaiting,
                    ),
                    QuiccSpace.gapMd,
                    const _ConnectionDot(),
                  ],
                ),
                destinations: [
                  for (final d in list)
                    _dest(
                      d,
                      badge: switch (d) {
                        HomeDestination.kitchen => kitchen,
                        HomeDestination.deliveries => unassigned,
                        HomeDestination.updates => updateWaiting ? 1 : 0,
                        _ => 0,
                      },
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    const PiUnreachableBanner(),
                    const WarningBars(),
                    const IntegrationBanner(),
                    Expanded(
                      child: Stack(
                        children: [
                          // Under the panes: the kept Map (its pane in the
                          // switcher is only the driver button over it).
                          if (_mapKept) Positioned.fill(child: _KeptMap(shown: mapShown, motion: motion)),
                          Positioned.fill(
                            child: AnimatedSwitcher(
                              duration: motion.full ? motion.scale(const Duration(milliseconds: 260)) : motion.fade,
                              reverseDuration: motion.full
                                  ? motion.scale(const Duration(milliseconds: 140))
                                  : motion.fade,
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              layoutBuilder: (current, previous) => Stack(
                                fit: StackFit.expand,
                                alignment: Alignment.center,
                                children: [...previous, ?current],
                              ),
                              transitionBuilder: (child, anim) => FadeTransition(
                                opacity: anim,
                                child: motion.full
                                    ? SlideTransition(
                                        position: Tween<Offset>(
                                          begin: const Offset(0, 0.015),
                                          end: Offset.zero,
                                        ).animate(anim),
                                        child: child,
                                      )
                                    : child,
                              ),
                              child: KeyedSubtree(key: ValueKey<HomeDestination>(_shown), child: _pane(_shown)),
                            ),
                          ),
                          // Hub info / warnings, top-right over every pane.
                          const Positioned(top: QuiccSpace.md, right: QuiccSpace.lg, child: IntegrationToastHost()),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pane(HomeDestination d) {
    final pane = switch (d) {
      HomeDestination.kitchen => const KitchenPane(),
      HomeDestination.deliveries => const DeliveriesPane(),
      // Drawn by the kept map under the switcher ([_KeptMap]).
      HomeDestination.map => const SizedBox.shrink(),
      HomeDestination.drivers => const DriversPane(),
      HomeDestination.history => const HistoryPane(),
      HomeDestination.batch => const BatchPane(),
      HomeDestination.printers => const PrintersPane(),
      HomeDestination.updates => const UpdatesScreen(),
      HomeDestination.help => const HelpPane(),
      HomeDestination.settings => const StoreSettingsScreen(),
      HomeDestination.connections => const ConnectionsScreen(),
      HomeDestination.posHub => const PosHubScreen(),
      HomeDestination.logs => const DevLogsScreen(),
      HomeDestination.tests => const DevTestsScreen(),
      HomeDestination.config => const DevConfigScreen(),
    };
    if (railModeOf(d) != RailMode.kitchen) return pane;
    // The driver button floats bottom-right over the kitchen-mode panes.
    return Stack(
      children: [
        Positioned.fill(child: pane),
        const Positioned.fill(child: DriverFab()),
      ],
    );
  }
}

/// The kitchen-mode Map, kept built for the whole session (1.7.1): drawing
/// the vector tiles again on every visit made the tab slow to show on the
/// store tablet. Hidden it is offstage — laid out but not painted or hit —
/// with its tickers off, and it rebuilds only when the runs change
/// ([RunsMapPane.active]); one FlutterMap with its 3 MB tile cache stays in
/// memory. Shown, it fades in under the outgoing pane.
class _KeptMap extends StatelessWidget {
  final bool shown;
  final Motion motion;
  const _KeptMap({required this.shown, required this.motion});

  @override
  Widget build(BuildContext context) => Offstage(
    key: const ValueKey('kept-map'),
    offstage: !shown,
    child: TickerMode(
      enabled: shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: motion.full ? motion.scale(const Duration(milliseconds: 260)) : motion.fade,
        curve: Curves.easeOutCubic,
        child: RunsMapPane(active: shown),
      ),
    ),
  );
}

/// Green = live SSE, amber = connecting, red = disconnected (retrying).
class _ConnectionDot extends ConsumerWidget {
  const _ConnectionDot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(floorProvider.select((s) => s.connection));
    final (color, label) = switch (st) {
      SseStatus.connected => (QuiccColors.statusPaid, 'Live'),
      SseStatus.connecting => (QuiccColors.statusFiring, 'Syncing'),
      SseStatus.disconnected => (QuiccColors.statusVoided, 'Offline'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        QuiccSpace.gapXs,
        Text(
          label,
          style: QuiccType.text(QuiccType.caption, weight: FontWeight.w700, color: color),
        ),
      ],
    );
  }
}
