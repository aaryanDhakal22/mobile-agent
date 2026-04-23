import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';

/// Order detail pane with the right-hand confirm/reprint action column.
/// `confirmable=true` shows a big lavender "CONFIRM & PRINT" button — used
/// when the order is in `arrived` state. `confirmable=false` hides it
/// (history view, already-accepted orders).
class OrderDetailScreen extends ConsumerStatefulWidget {
  final StoredOrder order;
  final bool confirmable;
  const OrderDetailScreen({
    super.key,
    required this.order,
    this.confirmable = true,
  });

  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  late StoredOrder _order = widget.order;
  bool _accepting = false;
  bool _reprinting = false;
  String? _printerError;

  Future<void> _accept() async {
    if (_accepting) return;
    setState(() {
      _accepting = true;
      _printerError = null;
    });
    try {
      final updated = await ref.read(agentClientProvider).accept(_order.order.orderId);
      if (!mounted) return;
      ref.invalidate(arrivedOrdersProvider);
      setState(() => _order = updated);
      Navigator.of(context).pop();
    } on AgentException catch (e) {
      if (!mounted) return;
      if (e.isAlreadyAccepted) {
        ref.invalidate(arrivedOrdersProvider);
        Navigator.of(context).pop();
        return;
      }
      setState(() => _printerError = e.isPrinterFailure ? 'Printer offline' : e.message);
    } catch (e) {
      if (!mounted) return;
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
    return Scaffold(
      appBar: AppBar(
        backgroundColor: QuiccColors.bgCanvas,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Row(
          children: [
            Text(
              'Ticket #${req.orderNumber}',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w500,
                color: QuiccColors.textPrimary,
              ),
            ),
            const SizedBox(width: 12),
            _StateChip(status: _order.status),
          ],
        ),
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(32, 16, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CustomerCard(req: req),
                  const SizedBox(height: 16),
                  _ItemsCard(items: req.items),
                  if (req.notes.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _NotesCard(notes: req.notes),
                  ],
                  const SizedBox(height: 16),
                  _TotalsCard(req: req),
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
      ),
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
      color: QuiccColors.bgSurface,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'TOTAL',
            style: const TextStyle(
              fontSize: 12,
              letterSpacing: 2,
              color: QuiccColors.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '\$${total.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 48,
              fontWeight: FontWeight.w600,
              color: QuiccColors.textPrimary,
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
                color: QuiccColors.bgElevated,
                borderRadius: BorderRadius.circular(QuiccRadius.cta),
              ),
              child: Text(
                'ACCEPTED',
                style: const TextStyle(
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

class _StateChip extends StatelessWidget {
  final OrderStatus status;
  const _StateChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status.state) {
      'arrived' => (QuiccColors.statusFiring, 'ARRIVED'),
      'accepted' => (QuiccColors.statusPaid, 'ACCEPTED'),
      _ => (QuiccColors.textMuted, status.state.toUpperCase()),
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
              Text(req.customer.phone, style: const TextStyle(color: QuiccColors.textSecondary)),
            ],
            if (req.serviceType.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.restaurant_menu, size: 16, color: QuiccColors.textMuted),
                  const SizedBox(width: 6),
                  Text(req.serviceType, style: const TextStyle(color: QuiccColors.textSecondary)),
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
                style: const TextStyle(color: QuiccColors.textSecondary),
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
      if (item.quantity > 1) '${item.quantity} ×',
      item.name,
      if (item.sizeName.isNotEmpty) '· ${item.sizeName}',
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
                '· ${mod.name}',
                style: const TextStyle(color: QuiccColors.textSecondary, fontSize: 14),
              ),
            ),
          if (item.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                item.notes,
                style: const TextStyle(
                  color: QuiccColors.textMuted,
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
      color: emphasised ? QuiccColors.textPrimary : QuiccColors.textSecondary,
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
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 2,
        color: QuiccColors.textMuted,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
