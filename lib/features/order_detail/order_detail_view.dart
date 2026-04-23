import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/pop_in.dart';
import '../../theme/quicc_colors.dart';

/// Body-only order detail: left column of cards (customer, items, notes,
/// totals) + right-side action panel (Confirm / Reprint). No Scaffold or
/// AppBar so it embeds cleanly inside a split-pane parent (History) or under
/// a pushed Scaffold (OrderDetailScreen).
class OrderDetailView extends ConsumerStatefulWidget {
  final StoredOrder order;
  final bool confirmable;

  /// When true, a successful accept (or a 409 "already accepted") pops the
  /// top route. History embeds this in-place, so it passes false.
  final bool popOnAccept;

  const OrderDetailView({
    super.key,
    required this.order,
    this.confirmable = true,
    this.popOnAccept = true,
  });

  @override
  ConsumerState<OrderDetailView> createState() => _OrderDetailViewState();
}

class _OrderDetailViewState extends ConsumerState<OrderDetailView> {
  late StoredOrder _order = widget.order;
  bool _accepting = false;
  bool _reprinting = false;
  String? _printerError;

  @override
  void didUpdateWidget(OrderDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.order.order.orderId != widget.order.order.orderId) {
      // Parent swapped the order in place (history row selection). Reset the
      // local UI state so errors from the previous order don't bleed over.
      _order = widget.order;
      _printerError = null;
    }
  }

  Future<void> _accept() async {
    if (_accepting) return;
    setState(() {
      _accepting = true;
      _printerError = null;
    });
    try {
      final id = _order.order.orderId;
      // Optimistic removal so the Arrived list reflects the accept
      // immediately â€” even before the agent round-trip completes and before
      // the next refetch.
      ref.read(arrivedOrdersProvider.notifier).remove(id);
      final updated = await ref.read(agentClientProvider).accept(id);
      if (!mounted) return;
      setState(() => _order = updated);
      if (widget.popOnAccept) Navigator.of(context).pop();
    } on AgentException catch (e) {
      if (!mounted) return;
      if (e.isAlreadyAccepted) {
        // Already gone from arrived on the agent side â€” keep our optimistic
        // remove in place and just bail out of the screen.
        if (widget.popOnAccept) Navigator.of(context).pop();
        return;
      }
      // Accept failed â€” put the order back in the arrived list so the cashier
      // can retry. (The agent kept it in arrived state; we undo our optimistic
      // remove.)
      ref.read(arrivedOrdersProvider.notifier).prepend(_order);
      setState(() => _printerError = e.isPrinterFailure ? 'Printer offline' : e.message);
    } catch (e) {
      if (!mounted) return;
      // Same rollback for unexpected errors.
      ref.read(arrivedOrdersProvider.notifier).prepend(_order);
      setState(() => _printerError = e.toString());
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  Future<void> _reprint() async {
    if (_reprinting) return;
    setState(() {
      _reprinting = true;
      _printerError = null;
    });
    try {
      await ref.read(agentClientProvider).reprint(_order.order.orderId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Reprint sent'),
        ),
      );
    } on AgentException catch (e) {
      if (!mounted) return;
      setState(() => _printerError = e.isPrinterFailure ? 'Printer offline' : e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _printerError = e.toString());
    } finally {
      if (mounted) setState(() => _reprinting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final req = _order.order;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(32, 24, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Ticket #${req.orderNumber}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OrderStateChip(status: _order.status),
                  ],
                ),
                const SizedBox(height: 16),
                PopIn.stagger(index: 0, child: _CustomerCard(req: req)),
                const SizedBox(height: 16),
                PopIn.stagger(index: 1, child: _ItemsCard(items: req.items)),
                if (req.notes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  PopIn.stagger(index: 2, child: _NotesCard(notes: req.notes)),
                ],
                const SizedBox(height: 16),
                PopIn.stagger(index: 3, child: _TotalsCard(req: req)),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 340,
          child: _ActionPanel(
            confirmable: widget.confirmable && _order.status.isArrived,
            accepting: _accepting,
            reprinting: _reprinting,
            printerError: _printerError,
            onAccept: _accept,
            onReprint: _reprint,
            total: req.orderTotal,
          ),
        ),
      ],
    );
  }
}

class _ActionPanel extends StatelessWidget {
  final bool confirmable;
  final bool accepting;
  final bool reprinting;
  final String? printerError;
  final VoidCallback onAccept;
  final VoidCallback onReprint;
  final double total;

  const _ActionPanel({
    required this.confirmable,
    required this.accepting,
    required this.reprinting,
    required this.printerError,
    required this.onAccept,
    required this.onReprint,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.palette.bgSurface,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'TOTAL',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 2,
              color: context.palette.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '\$${total.toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 48,
              fontWeight: FontWeight.w600,
              color: context.palette.textPrimary,
            ),
          ),
          const Spacer(),
          if (confirmable)
            SizedBox(
              height: 88,
              child: FilledButton(
                onPressed: accepting ? null : onAccept,
                child: accepting
                    ? const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: QuiccColors.brand900,
                        ),
                      )
                    : const Text(
                        'CONFIRM & PRINT',
                        style: TextStyle(fontSize: 20, letterSpacing: 2, fontWeight: FontWeight.w600),
                      ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(vertical: 20),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.palette.bgElevated,
                borderRadius: BorderRadius.circular(QuiccRadius.cta),
              ),
              child: const Text(
                'ACCEPTED',
                style: TextStyle(
                  fontSize: 16,
                  letterSpacing: 3,
                  color: QuiccColors.statusPaid,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const SizedBox(height: 12),
          SizedBox(
            height: 64,
            child: OutlinedButton.icon(
              onPressed: reprinting ? null : onReprint,
              icon: reprinting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: QuiccColors.brand400,
                      ),
                    )
                  : Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const Icon(Icons.print_outlined),
                        if (printerError != null)
                          Positioned(
                            right: -4,
                            top: -4,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: const BoxDecoration(
                                color: QuiccColors.statusVoided,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
              label: const Text('REPRINT', style: TextStyle(letterSpacing: 2)),
            ),
          ),
          if (printerError != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: QuiccColors.statusVoided.withValues(alpha: 0.12),
                border: Border.all(color: QuiccColors.statusVoided.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(QuiccRadius.sm),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: QuiccColors.statusVoided, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      printerError!,
                      style: const TextStyle(
                        color: QuiccColors.statusVoided,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class OrderStateChip extends StatelessWidget {
  final OrderStatus status;
  const OrderStateChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status.state) {
      'arrived' => (QuiccColors.statusFiring, 'ARRIVED'),
      'accepted' => (QuiccColors.statusPaid, 'ACCEPTED'),
      _ => (context.palette.textMuted, status.state.toUpperCase()),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(QuiccRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: color)),
        ],
      ),
    );
  }
}

class _CustomerCard extends StatelessWidget {
  final OrderRequest req;
  const _CustomerCard({required this.req});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionLabel('CUSTOMER'),
            const SizedBox(height: 8),
            Text(
              req.customerName,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
            ),
            if (req.customer.phone.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(req.customer.phone, style: TextStyle(color: context.palette.textSecondary)),
            ],
            if (req.serviceType.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.restaurant_menu, size: 16, color: context.palette.textMuted),
                  const SizedBox(width: 6),
                  Text(req.serviceType, style: TextStyle(color: context.palette.textSecondary)),
                ],
              ),
            ],
            if (req.deliveryAddress != null) ...[
              const SizedBox(height: 8),
              Text(
                [
                  req.deliveryAddress!.street,
                  if (req.deliveryAddress!.suite.isNotEmpty) '#${req.deliveryAddress!.suite}',
                  req.deliveryAddress!.city,
                ].where((s) => s.isNotEmpty).join(', '),
                style: TextStyle(color: context.palette.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ItemsCard extends StatelessWidget {
  final List<Item> items;
  const _ItemsCard({required this.items});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionLabel('ITEMS'),
            const SizedBox(height: 12),
            for (final item in items) _ItemRow(item: item),
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final Item item;
  const _ItemRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final title = [
      if (item.quantity > 1) '${item.quantity} Ã—',
      item.name,
      if (item.sizeName.isNotEmpty) 'Â· ${item.sizeName}',
    ].join(' ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
              Text(
                '\$${(item.price * item.quantity).toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 16),
              ),
            ],
          ),
          for (final mod in item.modifiers)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                'Â· ${mod.name}',
                style: TextStyle(color: context.palette.textSecondary, fontSize: 14),
              ),
            ),
          if (item.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                item.notes,
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NotesCard extends StatelessWidget {
  final String notes;
  const _NotesCard({required this.notes});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionLabel('NOTES'),
            const SizedBox(height: 8),
            Text(notes, style: const TextStyle(fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  final OrderRequest req;
  const _TotalsCard({required this.req});

  @override
  Widget build(BuildContext context) {
    final subtotal = req.items.fold<double>(0, (sum, i) => sum + i.price * i.quantity);
    final tax = req.taxes.fold<double>(0, (sum, t) => sum + t.amount);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _LineRow('Subtotal', subtotal),
            if (tax > 0) _LineRow('Tax', tax),
            if (req.tip > 0) _LineRow('Tip', req.tip),
            const Divider(height: 24),
            _LineRow('Total', req.orderTotal, emphasised: true),
          ],
        ),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  final String label;
  final double value;
  final bool emphasised;
  const _LineRow(this.label, this.value, {this.emphasised = false});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: emphasised ? 20 : 15,
      fontWeight: emphasised ? FontWeight.w600 : FontWeight.w400,
      color: emphasised ? context.palette.textPrimary : context.palette.textSecondary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text('\$${value.toStringAsFixed(2)}', style: style),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 2,
        color: context.palette.textMuted,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
