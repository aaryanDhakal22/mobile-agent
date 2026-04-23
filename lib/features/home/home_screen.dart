import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../order_detail/order_detail_screen.dart';
import '../settings/settings_screen.dart';

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
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
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
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.notifications_active_outlined),
                selectedIcon: Icon(Icons.notifications_active),
                label: Text('Arrived'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.receipt_long_outlined),
                selectedIcon: Icon(Icons.receipt_long),
                label: Text('History'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.print_outlined),
                selectedIcon: Icon(Icons.print),
                label: Text('Printer'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _buildSection(_index)),
        ],
      ),
    );
  }

  Widget _buildSection(int i) {
    return switch (i) {
      0 => const _ArrivedPane(),
      1 => const _PlaceholderPane(
          title: 'History',
          body: 'Recent orders will live here once the history pane lands.',
        ),
      2 => const _PlaceholderPane(
          title: 'Printer',
          body: 'Printer health polls arrive once the agent exposes the status endpoint.',
        ),
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
                        style: const TextStyle(color: QuiccColors.textSecondary),
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
                      '${req.serviceType} · ${req.items.length} item${req.items.length == 1 ? '' : 's'}',
                      style: const TextStyle(color: QuiccColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Text(
                '\$${req.orderTotal.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right, color: QuiccColors.textMuted),
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
        const Icon(Icons.inbox_outlined, size: 96, color: QuiccColors.textMuted),
        const SizedBox(height: 24),
        const Center(
          child: Text(
            'No orders waiting',
            style: TextStyle(fontSize: 22, color: QuiccColors.textSecondary),
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            "You'll see new orders here the moment they land.",
            style: TextStyle(color: QuiccColors.textMuted),
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
            style: const TextStyle(color: QuiccColors.textMuted),
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
        const Center(
          child: Text(
            'Check the URL in Settings if this keeps failing.',
            style: TextStyle(color: QuiccColors.textMuted, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _PlaceholderPane extends StatelessWidget {
  final String title;
  final String body;
  const _PlaceholderPane({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text(body, style: const TextStyle(color: QuiccColors.textSecondary)),
        ],
      ),
    );
  }
}
