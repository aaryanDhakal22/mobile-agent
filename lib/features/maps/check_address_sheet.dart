import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/friendly_error.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import 'delivery_map.dart';

/// Check address (1.5.0): main found more than one place for a delivery's
/// address (`geo.state == "check"`). Staff pick one of up to 3 candidates
/// (`POST /api/orders/{id}/geo/choose`) or drop a pin on the map (the
/// existing pin flow). Opened from the delivery row and the order detail.
Future<void> showCheckAddressSheet(BuildContext context, StoredOrder order) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => CheckAddressSheet(order: order),
);

/// The amber "CHECK ADDRESS" button (order detail).
class CheckAddressButton extends StatelessWidget {
  final StoredOrder order;
  const CheckAddressButton({super.key, required this.order});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: FilledButton.icon(
      key: const ValueKey('check-address'),
      style: FilledButton.styleFrom(backgroundColor: QuiccColors.statusFiring, foregroundColor: QuiccColors.brand900),
      onPressed: () => showCheckAddressSheet(context, order),
      icon: const Icon(Icons.wrong_location_outlined),
      label: const Text('CHECK ADDRESS'),
    ),
  );
}

/// A small tappable amber tag for the delivery row.
class CheckAddressTag extends StatelessWidget {
  final StoredOrder order;
  const CheckAddressTag({super.key, required this.order});

  @override
  Widget build(BuildContext context) => Material(
    color: QuiccColors.statusFiring.withValues(alpha: 0.18),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
      side: BorderSide(color: QuiccColors.statusFiring.withValues(alpha: 0.8)),
    ),
    child: InkWell(
      key: ValueKey('check-address-${order.id}'),
      borderRadius: BorderRadius.circular(6),
      onTap: () => showCheckAddressSheet(context, order),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wrong_location_outlined, size: 16, color: QuiccColors.statusFiring),
            SizedBox(width: 4),
            Text(
              'CHECK ADDRESS',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: QuiccColors.statusFiring),
            ),
          ],
        ),
      ),
    ),
  );
}

class CheckAddressSheet extends ConsumerStatefulWidget {
  final StoredOrder order;
  const CheckAddressSheet({super.key, required this.order});

  @override
  ConsumerState<CheckAddressSheet> createState() => _CheckAddressSheetState();
}

class _CheckAddressSheetState extends ConsumerState<CheckAddressSheet> {
  int? _sending;
  String? _error;

  Future<void> _choose(int index) async {
    setState(() {
      _sending = index;
      _error = null;
    });
    try {
      await ref.read(floorProvider.notifier).chooseGeo(widget.order.id, index);
      if (!mounted) return;
      final nav = Navigator.of(context);
      final messenger = ScaffoldMessenger.maybeOf(context);
      nav.pop();
      messenger?.showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Address chosen — the route shows in a moment'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = switch (e) {
          AgentException(code: kSettingsUnsupported) => 'This Pi needs an update to check addresses.',
          AgentException(code: kMainOffline) => "The Pi can't reach Quicc right now — try again in a minute.",
          _ => 'Not saved. ${FriendlyError.from(e).short}.',
        },
      );
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  void _pin() {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => PinAddressScreen(orderId: widget.order.id, initial: widget.order),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final so = ref.watch(floorProvider.select((s) => s.orders[widget.order.id])) ?? widget.order;
    final typed = so.order.fulfillment.address;
    final candidates = so.geo?.candidates ?? const <GeoCandidate>[];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Which address is it? · ${so.displayNumber}',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Typed: ${typed == null || typed.isEmpty ? 'no address' : typed.oneLine}',
              style: TextStyle(fontSize: 16, color: context.palette.textSecondary),
            ),
            const SizedBox(height: 16),
            if (candidates.isEmpty)
              Text(
                'No suggestions for this one — drop a pin where the door is.',
                style: TextStyle(color: context.palette.textMuted, fontSize: 16),
              ),
            for (final (i, c) in candidates.indexed)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  key: ValueKey('candidate-$i'),
                  minVerticalPadding: 14,
                  leading: const Icon(Icons.place_outlined, color: QuiccColors.brand400, size: 30),
                  title: Text(c.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
                  trailing: _sending == i
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3))
                      : const Text('THIS ONE', style: TextStyle(fontWeight: FontWeight.w800)),
                  onTap: _sending == null ? () => _choose(i) : null,
                ),
              ),
            if (_error != null) ...[const SizedBox(height: 8), InlineError(_error!)],
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                key: const ValueKey('drop-pin'),
                onPressed: _sending == null ? _pin : null,
                icon: const Icon(Icons.push_pin_outlined),
                label: const Text('NONE OF THESE — DROP A PIN'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen map to place the door of an address by hand (the existing
/// pin flow, bigger).
class PinAddressScreen extends ConsumerWidget {
  final String orderId;
  final StoredOrder initial;
  const PinAddressScreen({super.key, required this.orderId, required this.initial});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final so = ref.watch(floorProvider.select((s) => s.orders[orderId])) ?? initial;
    final a = so.order.fulfillment.address;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: context.palette.bgSurface,
        title: Text('Drop a pin · ${so.displayNumber}${a == null || a.isEmpty ? '' : ' · ${a.oneLine}'}'),
      ),
      body: LayoutBuilder(
        builder: (context, box) => ListView(
          padding: const EdgeInsets.all(24),
          children: [
            DeliveryMap(key: ValueKey('pin-map-$orderId'), order: so, height: (box.maxHeight - 80).clamp(280, 900)),
            const SizedBox(height: 8),
            if (so.geo?.state == GeoState.located)
              Text(
                'Located${so.geo!.isPinned ? ' from your pin' : ''} — ${clock(so.geo!.updatedAt)}',
                style: const TextStyle(color: QuiccColors.statusPaid, fontWeight: FontWeight.w700),
              ),
          ],
        ),
      ),
    );
  }
}
