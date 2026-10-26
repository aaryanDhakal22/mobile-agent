import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../core/providers.dart';
import '../../core/sse.dart';
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
import '../dev/tests_screen.dart';
import '../diagnose/diagnose_entry.dart';
import '../diagnose/guide_session.dart';
import '../drivers/driver_fab.dart';
import '../drivers/drivers_pane.dart';
import '../history/history_pane.dart';
import '../integration/integration_alerts.dart';
import '../kitchen/kitchen_pane.dart';
import '../printers/printers_pane.dart';
import '../settings/store_settings_screen.dart';
import 'home_nav.dart';
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
class _HomeScreenState extends ConsumerState<HomeScreen> {
  late HomeDestination _shown;

  /// Where each mode was last, so the q brings you back there.
  final Map<RailMode, HomeDestination> _last = {
    RailMode.kitchen: HomeDestination.kitchen,
    RailMode.store: HomeDestination.batch,
    RailMode.dev: HomeDestination.connections,
  };

  RailMode get _mode => railModeOf(_shown);

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
    // A guide was running when the app stopped (e.g. mid SD-card swap):
    // carry on with it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && resumableGuideSession(ref.read(storageProvider)) != null) resumeGuide(context);
    });
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
    if (ref.read(devGateProvider) || await showDevLoginSheet(context)) {
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
    final motion = Motion.of(context, ref);
    final mode = _mode;
    final list = kRailDestinations[mode]!;

    return Scaffold(
      // Don't shrink the body for the keyboard — the rail's evenly spread
      // items would get squashed.
      resizeToAvoidBottomInset: false,
      body: DiagPoller(
        child: Row(
          children: [
            QuiccNavRail(
              modeKey: mode,
              motion: motion,
              selectedIndex: list.indexOf(_shown),
              onDestinationSelected: (i) => _go(list[i]),
              header: Column(
                children: [
                  QButton(mode: mode, motion: motion, onTap: _onQTap, onLongPress: _onQLongPress),
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
    );
  }

  Widget _pane(HomeDestination d) {
    final pane = switch (d) {
      HomeDestination.kitchen => const KitchenPane(),
      HomeDestination.deliveries => const DeliveriesPane(),
      HomeDestination.drivers => const DriversPane(),
      HomeDestination.history => const HistoryPane(),
      HomeDestination.batch => const BatchPane(),
      HomeDestination.printers => const PrintersPane(),
      HomeDestination.help => const HelpPane(),
      HomeDestination.settings => const StoreSettingsScreen(),
      HomeDestination.connections => const ConnectionsScreen(),
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
