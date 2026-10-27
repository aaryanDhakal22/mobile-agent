import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/auto_preview.dart';
import '../../core/delivery_models.dart';
import '../../core/floor_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/squish.dart';
import '../common/widgets.dart';
import '../home/home_nav.dart';
import 'delivery_widgets.dart';

/// Room left for the bottom-right driver button (the select bar stops short
/// of it). Toasts used it too until the notification island (1.9.0), where
/// `rightInset` does nothing.
const double kSendOutToastInset = 160;

/// A pool / send-out named a delivery that came back (409 `came_back`).
const String kCameBackFirst =
    'A delivery in there came back — hold it under Came back to send it to Unassigned first. List refreshed.';

/// One stop a send-out takes: a pooled delivery, or an AUTO suggestion
/// (yellow, still unassigned on the Pi) that rides along with it.
typedef SendOutStop = ({StoredOrder order, bool suggested});

/// What SEND OUT would take for [driverId]: the pool in driving order, then
/// AUTO's yellow stops for that driver.
List<SendOutStop> sendOutStops(FloorState fs, AutoPreview? preview, String driverId) => [
  for (final o in fs.poolFor(driverId)) (order: o, suggested: false),
  for (final id in preview?.suggestedFor(driverId) ?? const <String>[])
    if (fs.orders[id] != null) (order: fs.orders[id]!, suggested: true),
];

/// "#1106 isn't marked ready — send anyway?" Resolves true on SEND ANYWAY.
Future<bool> confirmCooking(BuildContext context, List<String> numbers, String driver) {
  final one = numbers.length == 1;
  return confirmDialog(
    context,
    title: "${numbersList(numbers)} ${one ? "isn't" : "aren't"} marked ready — send anyway?",
    message: 'SEND ANYWAY marks ${one ? 'it' : 'them'} ready and sends ${one ? 'it' : 'them'} out with $driver.',
    confirm: 'SEND ANYWAY',
  );
}

/// "1634 Gleneagle Rd is the other way — hold it for Abdul (back ~6 min)?"
/// (2.2.1). Resolves true on HOLD (send without them), false on SEND BOTH /
/// SEND ALL, null when dismissed (send nothing).
Future<bool?> confirmHold(BuildContext context, List<HeldStop> held, Map<String, StoredOrder> orders, int stops) {
  final now = timeNow();
  String where(HeldStop h) =>
      h.address.isNotEmpty ? h.address : (orders[h.orderId] == null ? 'A delivery' : orderNumber(orders[h.orderId]!));
  String forWhom(HeldFor? f) {
    if (f == null) return 'a driver on his way back';
    final back = f.backIn(now);
    return back == null ? f.name : '${f.name} (back $back)';
  }

  final one = held.length == 1;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        one
            ? '${where(held.single)} is the other way — hold it for ${forWhom(held.single.heldFor)}?'
            : '${held.length} stops are the other way — hold them for the drivers on their way back?',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!one)
            for (final h in held)
              Padding(
                padding: const EdgeInsets.only(bottom: QuiccSpace.xs),
                child: Text('${where(h)} — ${forWhom(h.heldFor)}'),
              ),
          Text(
            'HOLD sends the rest now; ${one ? 'it goes' : 'they go'} back to Unassigned.',
            style: QuiccType.text(QuiccType.label, color: ctx.palette.textSecondary),
          ),
        ],
      ),
      actions: [
        OutlinedButton(
          key: const ValueKey('send-all'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(stops == 2 ? 'SEND BOTH' : 'SEND ALL'),
        ),
        FilledButton(
          key: const ValueKey('hold'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('HOLD'),
        ),
      ],
    ),
  );
}

/// The one send-out flow (the driver button's NEXT card and the Deliveries
/// bar both use it): asks (2.2.1) whether to hold a stop that is the other
/// way for a driver on his way back, then "send anyway?" when something is
/// cooking, sends the
/// pool plus the driver's AUTO yellow stops (with the plan id), asks again if
/// the Pi finds something not ready, and explains failures in plain words.
/// Resolves true when the driver went out. [onSending] fires once the
/// questions are answered and the request is about to go (show a spinner
/// from there, not under the dialog).
///
/// Works on the provider container, not a WidgetRef, so it finishes cleanly
/// even if the calling widget goes away mid-flight.
Future<bool> sendOutDriver(
  BuildContext context,
  Driver d, {
  double toastInset = kSendOutToastInset,
  VoidCallback? onSending,
}) async {
  final c = ProviderScope.containerOf(context, listen: false);
  final floor = c.read(floorProvider.notifier);
  final previews = c.read(autoPreviewProvider.notifier);
  final preview = c.read(autoPreviewProvider);
  final stops = sendOutStops(c.read(floorProvider), preview, d.id);
  if (stops.isEmpty) return false;

  void say(String msg, {bool error = false}) {
    if (context.mounted) toast(context, msg, error: error, rightInset: toastInset);
  }

  // 2.2.1: the far one first. An older Pi (null), an error or a slow answer
  // never blocks the send-out.
  var held = const <HeldStop>[];
  try {
    held = await floor.sendCheck(d.id, [for (final s in stops) s.order.id]).timeout(const Duration(seconds: 4)) ??
        const <HeldStop>[];
  } catch (_) {}
  final ids = {for (final s in stops) s.order.id};
  held = held.where((h) => ids.contains(h.orderId)).toList();
  if (!context.mounted) return false;
  var exclude = const <String>{};
  if (held.isNotEmpty) {
    final hold = await confirmHold(context, held, c.read(floorProvider).orders, stops.length);
    if (hold == null || !context.mounted) return false;
    if (hold) exclude = {for (final h in held) h.orderId};
  }
  final going = stops.where((s) => !exclude.contains(s.order.id)).toList();
  if (going.isEmpty) {
    say('Nothing left to send — every stop is held.');
    return false;
  }
  // Held pooled stops go back to Unassigned on the Pi; held yellow ones just
  // aren't sent (they were never pooled).
  final excludePooled = [
    for (final s in stops)
      if (!s.suggested && exclude.contains(s.order.id)) s.order.id,
  ];

  var markReady = false;
  final cooking = going.where((s) => s.order.state != OrderState.ready).toList();
  if (cooking.isNotEmpty) {
    if (!await confirmCooking(context, [for (final s in cooking) orderNumber(s.order)], d.name)) return false;
    markReady = true;
  }
  if (!context.mounted) return false;
  onSending?.call();
  // Sending is "acting on" the deliveries: any glow asking for attention goes.
  c.read(deliveryHighlightProvider.notifier).clear();
  // The yellow stops leave the preview while they go out, so the send's own
  // echo isn't taken for someone else's change.
  final hasYellow = stops.any((s) => s.suggested);
  final taken = hasYellow ? previews.takeRun(d.id) : const <String>[];
  final include = [for (final id in taken) if (!exclude.contains(id)) id];
  try {
    while (true) {
      try {
        final out = await floor.sendOut(
          d.id,
          markReady: markReady,
          includeOrderIds: include.isEmpty ? null : include,
          excludeOrderIds: excludePooled.isEmpty ? null : excludePooled,
          planId: include.isEmpty ? null : preview?.planId,
        );
        say('${out.length} order${out.length == 1 ? '' : 's'} out with ${d.name}');
        return true;
      } on NotReadyException catch (e) {
        // The Pi knows better: something we thought ready isn't.
        if (markReady || !context.mounted) rethrow;
        final now = c.read(floorProvider).orders;
        final numbers = [for (final id in e.orderIds) now[id] == null ? '#?' : orderNumber(now[id]!)];
        if (!await confirmCooking(context, numbers, d.name)) {
          if (preview != null) previews.restoreRun(preview, d.id, taken);
          return false;
        }
        markReady = true;
      }
    }
  } catch (e) {
    if (preview != null) previews.restoreRun(preview, d.id, taken);
    if (!context.mounted) return false;
    final msg = switch (e) {
      AgentException(code: 'driver_not_available') =>
        "${d.name} isn't available — clocked out or already out. List refreshed.",
      AgentException(code: 'driver_not_found') => '${d.name} was removed — list refreshed.',
      AgentException(code: 'bad_request') => "${d.name}'s pool is empty now — list refreshed.",
      AgentException(code: 'invalid_state') || AgentException(code: 'not_ready') =>
        "Something in ${d.name}'s pool changed — list refreshed.",
      AgentException(code: kPoolsUnsupported) => 'This Pi needs an update for driver pools.',
      AgentException(code: kCameBack) => kCameBackFirst,
      _ => null,
    };
    msg == null
        ? toastError(context, e, lead: 'Not sent out', area: 'deliveries', rightInset: toastInset)
        : say(msg, error: true);
    return false;
  }
}

/// The one SEND OUT on the Deliveries screen (1.6.0), pinned under the pools
/// column: "SEND OUT · JUMA · 3 orders" for the next driver only — drivers
/// leave in queue order. Disabled, with a hint, while his box is empty.
class NextSendOutBar extends StatelessWidget {
  final Driver driver;
  final int stops;
  final bool sending;
  final VoidCallback onPressed;
  const NextSendOutBar({
    super.key,
    required this.driver,
    required this.stops,
    required this.sending,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final empty = stops == 0;
    // 1.9.0: squishes when pressed.
    return Squish(
      enabled: !(empty || sending),
      child: SizedBox(
        height: 64,
        child: FilledButton(
          key: const ValueKey('send-next'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.lg),
            backgroundColor: QuiccColors.brand400,
            foregroundColor: QuiccColors.brand900,
            disabledBackgroundColor: p.bgElevated,
            disabledForegroundColor: p.textMuted,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(QuiccRadius.lg)),
          ),
          onPressed: (empty || sending) ? null : onPressed,
          child: Row(
            children: [
              sending
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Icon(Icons.delivery_dining, size: 28),
              QuiccSpace.gapMd,
              Expanded(
                child: empty
                    ? Text(
                        "${driver.name} is next — drag deliveries into their box first",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: QuiccType.text(QuiccType.body, weight: FontWeight.w500, color: p.textMuted),
                      )
                    : Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'SEND OUT · ${driver.name.toUpperCase()}',
                              style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700),
                            ),
                            TextSpan(
                              text: ' · $stops order${stops == 1 ? '' : 's'}',
                              style: QuiccType.text(QuiccType.body, weight: FontWeight.w500),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
