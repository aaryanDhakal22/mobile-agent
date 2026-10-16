import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/sse.dart';
import '../../theme/quicc_colors.dart';
import '../arrived/arrived_pane.dart';
import '../batch/batch_pane.dart';
import '../deliveries/deliveries_pane.dart';
import '../drivers/drivers_pane.dart';
import '../history/history_pane.dart';
import '../kitchen/kitchen_pane.dart';
import '../printers/printers_pane.dart';
import '../settings/settings_screen.dart';
import 'quicc_nav_rail.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final arrived = ref.watch(floorProvider.select((s) => s.arrived.length));
    final kitchen = ref.watch(floorProvider.select((s) => s.kitchen.length));
    final ready = ref.watch(floorProvider.select((s) => s.readyDeliveries.length));

    return Scaffold(
      // Don't shrink the body for the keyboard — the rail's evenly spread
      // items would get squashed.
      resizeToAvoidBottomInset: false,
      body: Row(
        children: [
          QuiccNavRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            header: Column(
              children: [
                _ThemeToggleLogo(
                  onTap: () {
                    final m = ref.read(themeModeProvider);
                    ref.read(themeModeProvider.notifier).state = m == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
                  },
                ),
                const SizedBox(height: 10),
                const _ConnectionDot(),
              ],
            ),
            destinations: [
              QuiccNavDestination(
                icon: Icons.notifications_active_outlined,
                selectedIcon: Icons.notifications_active,
                label: 'Arrived',
                badge: arrived,
                badgeColor: QuiccColors.statusFiring,
              ),
              QuiccNavDestination(
                icon: Icons.soup_kitchen_outlined,
                selectedIcon: Icons.soup_kitchen,
                label: 'Kitchen',
                badge: kitchen,
              ),
              QuiccNavDestination(
                icon: Icons.delivery_dining_outlined,
                selectedIcon: Icons.delivery_dining,
                label: 'Deliveries',
                badge: ready,
              ),
              const QuiccNavDestination(icon: Icons.groups_outlined, selectedIcon: Icons.groups, label: 'Drivers'),
              const QuiccNavDestination(
                icon: Icons.receipt_long_outlined,
                selectedIcon: Icons.receipt_long,
                label: 'History',
              ),
              const QuiccNavDestination(icon: Icons.layers_outlined, selectedIcon: Icons.layers, label: 'Batch'),
              const QuiccNavDestination(icon: Icons.print_outlined, selectedIcon: Icons.print, label: 'Printers'),
              const QuiccNavDestination(icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: 'Settings'),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              reverseDuration: const Duration(milliseconds: 140),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (current, previous) =>
                  Stack(fit: StackFit.expand, alignment: Alignment.center, children: [...previous, ?current]),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(begin: const Offset(0, 0.015), end: Offset.zero).animate(anim),
                  child: child,
                ),
              ),
              child: KeyedSubtree(key: ValueKey<int>(_index), child: _buildSection(_index)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(int i) {
    return switch (i) {
      0 => const ArrivedPane(),
      1 => const KitchenPane(),
      2 => const DeliveriesPane(),
      3 => const DriversPane(),
      4 => const HistoryPane(),
      5 => const BatchPane(),
      6 => const PrintersPane(),
      _ => const SettingsScreen(),
    };
  }
}

/// Green = live SSE, amber = connecting, red = disconnected (retrying).
class _ConnectionDot extends ConsumerWidget {
  const _ConnectionDot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(floorProvider.select((s) => s.connection));
    final (color, label) = switch (st) {
      SseStatus.connected => (QuiccColors.statusPaid, 'LIVE'),
      SseStatus.connecting => (QuiccColors.statusFiring, 'SYNC'),
      SseStatus.disconnected => (QuiccColors.statusVoided, 'OFF'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(fontSize: 10, letterSpacing: 1, color: color, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

/// The `q` logo tile that doubles as the theme toggle.
class _ThemeToggleLogo extends StatefulWidget {
  final VoidCallback onTap;
  const _ThemeToggleLogo({required this.onTap});

  @override
  State<_ThemeToggleLogo> createState() => _ThemeToggleLogoState();
}

class _ThemeToggleLogoState extends State<_ThemeToggleLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
      reverseDuration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Toggle theme',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press.forward(),
        onTapUp: (_) {
          _press.reverse();
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        onTapCancel: () => _press.reverse(),
        child: AnimatedBuilder(
          animation: _press,
          builder: (_, child) => Transform.scale(scale: 1.0 - (_press.value * 0.08), child: child),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: QuiccColors.brand400, borderRadius: BorderRadius.circular(QuiccRadius.md)),
            alignment: Alignment.center,
            child: const Text(
              'q',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: QuiccColors.brand900, height: 1),
            ),
          ),
        ),
      ),
    );
  }
}
