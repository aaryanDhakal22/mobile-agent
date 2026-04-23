import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../drivers/driver_fab.dart';
import '../drivers/drivers_pane.dart';
import '../history/history_pane.dart';
import '../order_detail/order_detail_screen.dart';
import '../printer/printer_pane.dart';
import '../settings/settings_screen.dart';
import 'quicc_nav_rail.dart';

const int _settingsIndex = 4;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Do NOT shrink the body when the on-screen keyboard opens â€” otherwise
      // the left rail's evenly-spread items get squashed below their minimum
      // size and the icons overflow. TextFields in descendant Scrollables
      // (ListView in Settings etc.) still auto-scroll into view on focus via
      // Flutter's built-in `scrollPadding` behaviour.
      resizeToAvoidBottomInset: false,
      body: Row(
        children: [
          QuiccNavRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            header: _ThemeToggleLogo(
              onTap: () {
                final m = ref.read(themeModeProvider);
                ref.read(themeModeProvider.notifier).state =
                    m == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
              },
            ),
            destinations: const [
              QuiccNavDestination(
                icon: Icons.notifications_active_outlined,
                selectedIcon: Icons.notifications_active,
                label: 'Arrived',
              ),
              QuiccNavDestination(
                icon: Icons.receipt_long_outlined,
                selectedIcon: Icons.receipt_long,
                label: 'History',
              ),
              QuiccNavDestination(
                icon: Icons.print_outlined,
                selectedIcon: Icons.print,
                label: 'Printer',
              ),
              QuiccNavDestination(
                icon: Icons.local_shipping_outlined,
                selectedIcon: Icons.local_shipping,
                label: 'Drivers',
              ),
              QuiccNavDestination(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
                label: 'Settings',
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    reverseDuration: const Duration(milliseconds: 140),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (current, previous) => Stack(
                      fit: StackFit.expand,
                      alignment: Alignment.center,
                      children: [
                        ...previous,
                        ?current,
                      ],
                    ),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.015),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey<int>(_index),
                      child: _buildSection(_index),
                    ),
                  ),
                ),
                // FAB rides on top of every pane except Settings.
                if (_index != _settingsIndex)
                  const Positioned.fill(child: DriverFab()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(int i) {
    return switch (i) {
      0 => const _ArrivedPane(),
      1 => const HistoryPane(),
      2 => const PrinterPane(),
      3 => const DriversPane(),
      _ => const SettingsScreen(),
    };
  }
}

class _ArrivedPane extends ConsumerWidget {
  const _ArrivedPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arrived = ref.watch(arrivedOrdersProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(arrivedOrdersProvider),
      child: arrived.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ConnectionError(
          error: e.toString(),
          onRetry: () => ref.invalidate(arrivedOrdersProvider),
        ),
        data: (orders) {
          if (orders.isEmpty) {
            return _EmptyState();
          }
          return ListView.separated(
            padding: const EdgeInsets.all(32),
            itemCount: orders.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Arrived',
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${orders.length} waiting',
                        style: TextStyle(color: context.palette.textSecondary),
                      ),
                    ],
                  ),
                );
              }
              return _ArrivedRow(order: orders[i - 1]);
            },
          );
        },
      ),
    );
  }
}

class _ArrivedRow extends StatelessWidget {
  final StoredOrder order;
  const _ArrivedRow({required this.order});

  @override
  Widget build(BuildContext context) {
    final req = order.order;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => OrderDetailScreen(order: order),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  '#${req.orderNumber}',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: QuiccColors.brand400,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      req.customerName,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${req.serviceType} Â· ${req.items.length} item${req.items.length == 1 ? '' : 's'}',
                      style: TextStyle(color: context.palette.textSecondary),
                    ),
                  ],
                ),
              ),
              Text(
                '\$${req.orderTotal.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              Icon(Icons.chevron_right, color: context.palette.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(48),
      children: [
        const SizedBox(height: 120),
        Icon(Icons.inbox_outlined, size: 96, color: context.palette.textMuted),
        const SizedBox(height: 24),
        Center(
          child: Text(
            'No orders waiting',
            style: TextStyle(fontSize: 22, color: context.palette.textSecondary),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            "You'll see new orders here the moment they land.",
            style: TextStyle(color: context.palette.textMuted),
          ),
        ),
      ],
    );
  }
}

class _ConnectionError extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ConnectionError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(48),
      children: [
        const SizedBox(height: 80),
        const Icon(Icons.wifi_off, size: 72, color: QuiccColors.statusVoided),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            "Can't reach the agent",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            error,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.palette.textMuted),
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('RETRY'),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'Check the URL in Settings if this keeps failing.',
            style: TextStyle(color: context.palette.textMuted, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// The `q` logo tile that doubles as the theme toggle. Tap to flip between
/// dark and light. A subtle scale-down while pressed + haptic tick makes the
/// tap feel alive; the underlying tile stays on brand (lavender anchor).
class _ThemeToggleLogo extends StatefulWidget {
  final VoidCallback onTap;
  const _ThemeToggleLogo({required this.onTap});

  @override
  State<_ThemeToggleLogo> createState() => _ThemeToggleLogoState();
}

class _ThemeToggleLogoState extends State<_ThemeToggleLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
      reverseDuration: const Duration(milliseconds: 200),
      lowerBound: 0,
      upperBound: 1,
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _fire() {
    HapticFeedback.selectionClick();
    widget.onTap();
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
          _fire();
        },
        onTapCancel: () => _press.reverse(),
        child: AnimatedBuilder(
          animation: _press,
          builder: (_, child) {
            final scale = 1.0 - (_press.value * 0.08);
            return Transform.scale(scale: scale, child: child);
          },
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: QuiccColors.brand400,
              borderRadius: BorderRadius.circular(QuiccRadius.md),
            ),
            alignment: Alignment.center,
            child: const Text(
              'q',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: QuiccColors.brand900,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

