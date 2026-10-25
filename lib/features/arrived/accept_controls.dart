import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/friendly_error.dart';
import '../../core/local_log.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';
import 'time_picker.dart';

/// Shown while a timed-out accept is being read back from the agent.
const String kAcceptChecking = "Couldn't confirm — checking…";

/// Staff-facing message for a failed accept. A transport error / timeout is
/// ambiguous (the agent may have claimed the order before the answer was
/// lost), so it only says we're checking — see [acceptRecheckMessage].
String acceptErrorMessage(Object e) {
  if (e is AgentException) {
    if (e.isPrinterFailure) {
      return 'Printer problem — order NOT accepted. Check the printers and try again.';
    }
    if (e.isNetwork) return kAcceptChecking;
    if (e.isConflict) {
      return switch (e.code) {
        'already_accepted' => 'Already accepted on another screen.',
        'invalid_state' => 'This order was cancelled or closed with its batch — it can\'t be accepted.',
        _ => 'Not accepted. ${FriendlyError.from(e).short}.',
      };
    }
    if (e.isNotFound) return 'This order is no longer on the agent.';
  }
  return 'Not accepted. ${FriendlyError.from(e).short}.';
}

/// After [kAcceptChecking]: what the agent says about the order now. null
/// = the order was accepted after all (it leaves the arrived queue).
String? acceptRecheckMessage(StoredOrder? o) {
  if (o == null) {
    return "Can't reach the agent — couldn't confirm the accept. Check the Kitchen tab before trying again.";
  }
  return switch (o.state) {
    OrderState.arrived => 'The agent didn\'t get it — order NOT accepted. Try again.',
    OrderState.cancelled => 'This order was cancelled or closed with its batch — it can\'t be accepted.',
    OrderState.unknown => 'Couldn\'t confirm the accept. Check the Kitchen tab before trying again.',
    _ => null,
  };
}

/// What a failed first confirm of a future order says.
String scheduleErrorMessage(Object e) {
  if (e is AgentException) {
    if (e.isNetwork) return "Couldn't reach the Pi — not scheduled. Try again.";
    if (e.isConflict) return 'This order is not a later order any more — the screen will refresh.';
    if (e.isNotFound) return 'This order is no longer on the agent.';
    if (e.code == kSettingsUnsupported) return 'This Pi needs an update for later orders.';
  }
  return 'Not scheduled. ${FriendlyError.from(e).short}.';
}

/// The time picker + CONFIRM, used on the order detail screen and the
/// full-screen alert (1.5.0). Errors render inline (the alert sits above the
/// navigator, so no dialogs / snackbars there). Three cases:
///
/// * a normal order: X / X+5 / X+10 prep time → ACCEPT (prints);
/// * a future order's first ring: the same picker sets the lead time →
///   `POST /schedule` (nothing prints; it waits in the Later strip);
/// * a future order ringing again (`rerung`): no picker, one CONFIRM prints
///   it with the lead picked before.
class AcceptControls extends ConsumerStatefulWidget {
  final StoredOrder order;

  /// Colors for the lavender alert surface.
  final bool onBrand;
  final double chipFontSize;

  const AcceptControls({super.key, required this.order, this.onBrand = false, this.chipFontSize = 22});

  @override
  ConsumerState<AcceptControls> createState() => _AcceptControlsState();
}

class _AcceptControlsState extends ConsumerState<AcceptControls> {
  int? _prep;
  bool _busy = false;
  String? _error;

  /// The technical text behind [_error] (Details link + local log).
  String _details = '';

  Future<void> _accept(int? prep) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _details = '';
    });
    try {
      await ref.read(floorProvider.notifier).accept(widget.order.id, prep);
      // On success the order leaves the arrived queue and this widget unmounts.
    } catch (e) {
      if (!mounted) return;
      final f = FriendlyError.from(e);
      ref.read(localLogProvider).warn('accept', '${widget.order.id}: ${f.details}');
      setState(() {
        _error = acceptErrorMessage(e);
        _details = f.details;
      });
      if (e is AgentException && e.isNetwork) {
        // The claim may have landed: read the order back before saying no.
        final o = await ref.read(floorProvider.notifier).recheck(widget.order.id);
        if (mounted) setState(() => _error = acceptRecheckMessage(o));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _schedule(int lead) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _details = '';
    });
    try {
      await ref.read(floorProvider.notifier).schedule(widget.order.id, lead);
      // On success the order goes to the Later strip and this widget unmounts.
    } catch (e) {
      if (!mounted) return;
      final f = FriendlyError.from(e);
      ref.read(localLogProvider).warn('schedule', '${widget.order.id}: ${f.details}');
      setState(() {
        _error = scheduleErrorMessage(e);
        _details = f.details;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final so = widget.order;
    final times = ref.watch(floorProvider.select((s) => s.settings.times));
    final base = defaultMinutesFor(so, times);
    final selected = _prep ?? base;
    final fg = widget.onBrand ? QuiccColors.brand900 : null;
    final muted = fg?.withValues(alpha: 0.7) ?? context.palette.textMuted;
    final rerung = so.status.rerung;
    final lead = so.needsLead;
    final due = so.dueAt;

    final String eyebrow;
    final String action;
    final VoidCallback onConfirm;
    final IconData icon;
    if (rerung) {
      eyebrow = due == null ? 'LATER ORDER — TIME TO COOK' : 'LATER ORDER — DUE ${clock(due)}';
      final l = so.status.scheduledLeadMinutes;
      action = 'CONFIRM · PRINT';
      onConfirm = () => _accept(l);
      icon = Icons.print;
    } else if (lead) {
      eyebrow = 'LATER ORDER — START COOKING HOW LONG BEFORE IT IS DUE? (MIN)';
      action = 'CONFIRM · $selected MIN BEFORE';
      onConfirm = () => _schedule(selected);
      icon = Icons.schedule;
    } else {
      eyebrow = 'PREP TIME (MIN)';
      action = 'ACCEPT · $selected MIN';
      onConfirm = () => _accept(selected);
      icon = Icons.print;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          eyebrow,
          style: TextStyle(fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.w600, color: muted),
        ),
        const SizedBox(height: 8),
        if (!rerung)
          TimePicker(
            key: const ValueKey('time-picker'),
            base: base,
            value: selected,
            onBrand: widget.onBrand,
            fontSize: widget.chipFontSize,
            enabled: !_busy,
            onChanged: (m) => setState(() => _prep = m),
          ),
        if (lead && due != null) ...[
          const SizedBox(height: 8),
          Text(
            'Due ${clock(due)} — rings again at ${clock(due.subtract(Duration(minutes: selected)))}. Nothing prints now.',
            style: TextStyle(fontSize: 15, color: fg ?? context.palette.textSecondary),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          height: 64,
          child: FilledButton.icon(
            key: const ValueKey('accept-confirm'),
            style: widget.onBrand
                ? FilledButton.styleFrom(backgroundColor: QuiccColors.brand900, foregroundColor: QuiccColors.brand50)
                : null,
            onPressed: _busy ? null : onConfirm,
            icon: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3))
                : Icon(icon, size: 26),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _busy ? (lead ? 'SAVING…' : 'PRINTING…') : action,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 1),
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          InlineError(_error!, details: _details, onRetry: _busy ? null : onConfirm),
        ],
      ],
    );
  }
}
