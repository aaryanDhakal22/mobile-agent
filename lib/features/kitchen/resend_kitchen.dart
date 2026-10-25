import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../common/widgets.dart';

/// Labels (tooltip + screen reader) of the two print buttons.
const String kReprintReceiptLabel = 'Reprint receipt';
const String kResendKitchenLabel = 'Resend to kitchen';

/// Resend makes sense once the order has a kitchen number (accepted, ready,
/// out, delivered) — or is a POS order, which has its check # instead — not
/// while it is waiting (or scheduled for later) or after it was cancelled.
bool canResendToKitchen(StoredOrder so) =>
    (so.status.kitchenNumber != null || so.isPos) &&
    so.state != OrderState.arrived &&
    so.state != OrderState.scheduled &&
    so.state != OrderState.cancelled;

/// "Send to the kitchen again?" — always asked before resending.
Future<bool> confirmResendKitchen(BuildContext context, StoredOrder so) => confirmDialog(
  context,
  title: 'Send to the kitchen again?',
  message: 'Every kitchen printer for #${so.status.kitchenNumber ?? so.displayNumber} prints its ticket again.',
  confirm: 'SEND',
);

/// The snackbar after a resend: which stations printed (and which didn't).
String resendKitchenMessage(KitchenResend r) {
  final ok = r.printed.isEmpty ? 'Sent to the kitchen' : 'Sent to the kitchen — ${r.printed.join(', ')}';
  return r.failed.isEmpty ? ok : '$ok. Not printed: ${r.failed.join(', ')}';
}

/// Sends the kitchen tickets of [so] again (after the confirm) and shows how
/// it went. [onBusy] wraps the network call (spinner on the button).
Future<void> resendToKitchen(
  BuildContext context,
  WidgetRef ref,
  StoredOrder so, {
  required void Function(bool busy) onBusy,
  String area = 'kitchen',
}) async {
  if (!await confirmResendKitchen(context, so)) return;
  if (!context.mounted) return;
  onBusy(true);
  try {
    final r = await ref.read(floorProvider.notifier).resendKitchen(so.id);
    if (context.mounted) toast(context, resendKitchenMessage(r), error: r.printed.isEmpty && r.failed.isNotEmpty);
  } catch (e) {
    if (context.mounted) toastError(context, e, area: area);
  } finally {
    onBusy(false);
  }
}
