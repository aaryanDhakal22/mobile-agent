import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/auto_preview.dart';
import '../../core/floor_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import '../home/home_nav.dart';
import 'delivery_widgets.dart';

/// Toasts from a send-out stay left of the bottom-right driver button.
const double kSendOutToastInset = 160;

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

/// The one send-out flow (the driver button's NEXT card and the Deliveries
/// bar both use it): asks "send anyway?" when something is cooking, sends the
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

  var markReady = false;
  final cooking = stops.where((s) => s.order.state != OrderState.ready).toList();
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
  try {
    while (true) {
      try {
        final out = await floor.sendOut(
          d.id,
          markReady: markReady,
          includeOrderIds: taken.isEmpty ? null : taken,
          planId: taken.isEmpty ? null : preview?.planId,
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
    return SizedBox(
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
    );
  }
}
