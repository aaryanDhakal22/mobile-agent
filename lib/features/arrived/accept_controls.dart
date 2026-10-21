import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/friendly_error.dart';
import '../../core/local_log.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';

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

/// Prep-time quick picks + ACCEPT. Used on the Arrived pane and the
/// full-screen alert. Errors render inline (the alert sits above the
/// navigator, so no dialogs / snackbars there).
class AcceptControls extends ConsumerStatefulWidget {
  final StoredOrder order;

  /// Colors for the lavender alert surface.
  final bool onBrand;
  final double chipFontSize;

  const AcceptControls({super.key, required this.order, this.onBrand = false, this.chipFontSize = 18});

  @override
  ConsumerState<AcceptControls> createState() => _AcceptControlsState();
}

class _AcceptControlsState extends ConsumerState<AcceptControls> {
  int? _prep;
  bool _busy = false;
  String? _error;

  /// The technical text behind [_error] (Details link + local log).
  String _details = '';

  Future<void> _accept(int prep) async {
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

  @override
  Widget build(BuildContext context) {
    final floor = ref.watch(floorProvider.select((s) => s.floor));
    final choices = floor?.prepChoices ?? kDefaultPrepChoices;
    final selected = _prep ?? floor?.defaultPrep ?? choices.first;
    final fg = widget.onBrand ? QuiccColors.brand900 : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'PREP TIME (MIN)',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
            color: fg?.withValues(alpha: 0.7) ?? context.palette.textMuted,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in choices)
              _PrepChip(
                minutes: m,
                selected: m == selected,
                onBrand: widget.onBrand,
                fontSize: widget.chipFontSize,
                onTap: _busy ? null : () => setState(() => _prep = m),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 64,
          child: FilledButton.icon(
            style: widget.onBrand
                ? FilledButton.styleFrom(backgroundColor: QuiccColors.brand900, foregroundColor: QuiccColors.brand50)
                : null,
            onPressed: _busy ? null : () => _accept(selected),
            icon: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3))
                : const Icon(Icons.print, size: 26),
            label: Text(
              _busy ? 'PRINTING…' : 'ACCEPT · $selected MIN',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 1),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          InlineError(_error!, details: _details, onRetry: _busy ? null : () => _accept(selected)),
        ],
      ],
    );
  }
}

class _PrepChip extends StatelessWidget {
  final int minutes;
  final bool selected;
  final bool onBrand;
  final double fontSize;
  final VoidCallback? onTap;

  const _PrepChip({
    required this.minutes,
    required this.selected,
    required this.onBrand,
    required this.fontSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final Color border;
    if (onBrand) {
      bg = selected ? QuiccColors.brand900 : Colors.transparent;
      fg = selected ? QuiccColors.brand50 : QuiccColors.brand900;
      border = QuiccColors.brand900;
    } else {
      bg = selected ? QuiccColors.brand400 : context.palette.bgElevated;
      fg = selected ? QuiccColors.brand900 : context.palette.textPrimary;
      border = selected ? QuiccColors.brand400 : context.palette.borderSoft;
    }
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        side: BorderSide(color: border, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 72, minHeight: 52),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                '$minutes',
                style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
