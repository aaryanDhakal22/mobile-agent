import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../order_detail/order_detail_view.dart';

class HistoryPane extends ConsumerStatefulWidget {
  const HistoryPane({super.key});

  @override
  ConsumerState<HistoryPane> createState() => _HistoryPaneState();
}

class _HistoryPaneState extends ConsumerState<HistoryPane> {
  int? _selectedId;

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(orderHistoryProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 360,
          child: _ListColumn(
            history: history,
            selectedId: _selectedId,
            onSelect: (o) => setState(() => _selectedId = o.order.orderId),
            onRefresh: () => ref.invalidate(orderHistoryProvider),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: history.maybeWhen(
            data: (orders) {
              final selected = _firstOrNullWhere(orders, (o) => o.order.orderId == _selectedId)
                  ?? (orders.isNotEmpty ? orders.first : null);
              if (selected == null) return const _NoHistoryYet();
              // Lazily sync initial selection so the detail pane isn't blank
              // on first build.
              if (_selectedId == null && orders.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  setState(() => _selectedId = selected.order.orderId);
                });
              }
              return OrderDetailView(
                key: ValueKey(selected.order.orderId),
                order: selected,
                confirmable: false,
                popOnAccept: false,
              );
            },
            orElse: () => const _DetailPlaceholder(
              message: 'Select an order to view details',
            ),
          ),
        ),
      ],
    );
  }
}

T? _firstOrNullWhere<T>(List<T> list, bool Function(T) test) {
  for (final x in list) {
    if (test(x)) return x;
  }
  return null;
}

class _ListColumn extends StatelessWidget {
  final AsyncValue<List<StoredOrder>> history;
  final int? selectedId;
  final ValueChanged<StoredOrder> onSelect;
  final VoidCallback onRefresh;

  const _ListColumn({
    required this.history,
    required this.selectedId,
    required this.onSelect,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.palette.bgSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
            child: Row(
              children: [
                const Text(
                  'History',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.refresh, color: context.palette.textMuted),
                  onPressed: onRefresh,
                  tooltip: 'Refresh',
                ),
              ],
            ),
          ),
          Expanded(
            child: history.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ListError(error: e.toString(), onRetry: onRefresh),
              data: (orders) {
                if (orders.isEmpty) return const _EmptyHistory();
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  itemCount: orders.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, i) {
                    if (i == orders.length) {
                      return const _EndOfPageHint();
                    }
                    final o = orders[i];
                    return _HistoryRow(
                      order: o,
                      selected: o.order.orderId == selectedId,
                      onTap: () => onSelect(o),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final StoredOrder order;
  final bool selected;
  final VoidCallback onTap;
  const _HistoryRow({
    required this.order,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final req = order.order;
    final when = order.status.printedDate ?? order.status.arrivalDate;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: selected ? QuiccColors.brand400.withValues(alpha: 0.10) : context.palette.bgElevated,
            borderRadius: BorderRadius.circular(QuiccRadius.md),
            border: Border.all(
              color: selected ? QuiccColors.brand400.withValues(alpha: 0.55) : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '#${req.orderNumber}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: selected ? QuiccColors.brand400 : context.palette.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '\$${req.orderTotal.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                req.customerName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.palette.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  if (req.serviceType.isNotEmpty)
                    Text(
                      req.serviceType,
                      style: TextStyle(color: context.palette.textMuted, fontSize: 12),
                    ),
                  if (req.serviceType.isNotEmpty && when != null)
                    Text(
                      '  Â·  ',
                      style: TextStyle(color: context.palette.textMuted, fontSize: 12),
                    ),
                  if (when != null)
                    Text(
                      _formatRelative(when),
                      style: TextStyle(color: context.palette.textMuted, fontSize: 12),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No orders yet.',
            style: TextStyle(color: context.palette.textMuted),
          ),
        ),
      );
}

class _EndOfPageHint extends StatelessWidget {
  const _EndOfPageHint();
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Text(
          'Showing the latest 50 orders.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.textMuted, fontSize: 11, letterSpacing: 1.2),
        ),
      );
}

class _ListError extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ListError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off, color: QuiccColors.statusVoided, size: 48),
          const SizedBox(height: 12),
          const Text(
            "Can't load history",
            style: TextStyle(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Text(
            error,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.palette.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('RETRY'),
          ),
        ],
      ),
    );
  }
}

class _NoHistoryYet extends StatelessWidget {
  const _NoHistoryYet();
  @override
  Widget build(BuildContext context) {
    return const _DetailPlaceholder(
      message: 'Nothing to show yet â€” orders will appear here once they come in.',
    );
  }
}

class _DetailPlaceholder extends StatelessWidget {
  final String message;
  const _DetailPlaceholder({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined, size: 72, color: context.palette.textMuted),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.palette.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatRelative(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.isNegative) return 'just now';
  if (diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays < 7) return '${diff.inDays} d ago';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(when.month)}/${two(when.day)}';
}
