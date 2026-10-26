import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import '../deliveries/delivery_widgets.dart';

/// NOT DELIVERED (1.7.1, Pi 2.2.1) — the driver came back with the food. It
/// is offered for a delivery of the open batch that is out or marked
/// delivered (not one already waiting in "Came back"), and hidden once the
/// Pi said it doesn't know the route (an older Pi).
bool canMarkNotDelivered(StoredOrder so, int? currentBatchId) =>
    so.isDelivery &&
    !so.status.cameBack &&
    (so.state == OrderState.onDelivery || so.state == OrderState.delivered) &&
    currentBatchId != null &&
    so.status.batchId == currentBatchId;

/// "This Pi needs an update" — the toast for an older Pi.
const String kNotDeliveredNeedsUpdate = 'This Pi needs an update';

/// TRY AGAIN or CANCEL ORDER (no reason asked). CANCEL ORDER asks once more:
/// "Cancel #1104? It moves to History as cancelled." Null = staff backed out.
Future<NotDeliveredAction?> askNotDelivered(BuildContext context, StoredOrder so) async {
  final n = orderNumber(so);
  final pick = await showDialog<NotDeliveredAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('$n came back'),
      content: const Text('The driver brought it back. Try the delivery again, or cancel the order?'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Back')),
        OutlinedButton(
          key: const ValueKey('not-delivered-cancel'),
          style: OutlinedButton.styleFrom(
            foregroundColor: QuiccColors.statusVoided,
            side: const BorderSide(color: QuiccColors.statusVoided),
          ),
          onPressed: () => Navigator.of(ctx).pop(NotDeliveredAction.cancel),
          child: const Text('CANCEL ORDER'),
        ),
        FilledButton(
          key: const ValueKey('not-delivered-retry'),
          onPressed: () => Navigator.of(ctx).pop(NotDeliveredAction.retry),
          child: const Text('TRY AGAIN'),
        ),
      ],
    ),
  );
  if (pick != NotDeliveredAction.cancel || !context.mounted) return pick;
  final sure = await confirmDialog(
    context,
    title: 'Cancel $n?',
    message: 'It moves to History as cancelled.',
    confirm: 'CANCEL ORDER',
    cancel: 'Back',
    destructive: true,
  );
  return sure ? NotDeliveredAction.cancel : null;
}

/// Asks (above), tells the Pi and says how it went. [onBusy] wraps the call.
Future<void> markNotDelivered(
  BuildContext context,
  WidgetRef ref,
  StoredOrder so, {
  required void Function(bool busy) onBusy,
}) async {
  final action = await askNotDelivered(context, so);
  if (action == null || !context.mounted) return;
  final floor = ref.read(floorProvider.notifier);
  final n = orderNumber(so);
  onBusy(true);
  try {
    await floor.notDelivered(so.id, action);
    if (!context.mounted) return;
    toast(
      context,
      action == NotDeliveredAction.retry
          ? '$n is back on Deliveries, under Came back'
          : '$n cancelled — it is in History',
    );
  } catch (e) {
    if (!context.mounted) return;
    final msg = switch (e) {
      AgentException(code: kNotDeliveredUnsupported) => kNotDeliveredNeedsUpdate,
      AgentException(code: 'not_out_or_delivered') => "$n isn't out or delivered any more — refreshed.",
      AgentException(code: 'not_found') => '$n is gone — refreshed.',
      _ => null,
    };
    msg == null ? toastError(context, e, lead: 'Not saved', area: 'order') : toast(context, msg, error: true);
  } finally {
    onBusy(false);
  }
}

/// The order details' NOT DELIVERED button.
class NotDeliveredButton extends ConsumerWidget {
  final StoredOrder order;
  final bool busy;
  final void Function(bool busy) onBusy;
  const NotDeliveredButton({super.key, required this.order, required this.busy, required this.onBusy});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
    height: 56,
    child: OutlinedButton.icon(
      key: const ValueKey('not-delivered'),
      style: OutlinedButton.styleFrom(
        foregroundColor: QuiccColors.statusVoided,
        side: BorderSide(color: QuiccColors.statusVoided.withValues(alpha: 0.7)),
      ),
      onPressed: busy ? null : () => markNotDelivered(context, ref, order, onBusy: onBusy),
      icon: const Icon(Icons.assignment_return_outlined),
      label: const Text('NOT DELIVERED'),
    ),
  );
}
