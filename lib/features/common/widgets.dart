import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/friendly_error.dart';
import '../../core/local_log.dart';
import '../../core/models.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';

/// Pane title row: big title on the left, optional subtitle + trailing.
class PaneHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const PaneHeader({super.key, required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
          // The subtitle takes the free space and ellipsizes rather than
          // pushing the trailing action off a narrow tablet.
          if (subtitle != null) ...[
            const SizedBox(width: 16),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.palette.textSecondary),
                ),
              ),
            ),
          ] else
            const Spacer(),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

/// Small caps label used above card sections.
class Eyebrow extends StatelessWidget {
  final String text;
  const Eyebrow(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(fontSize: 11, letterSpacing: 2, color: context.palette.textMuted, fontWeight: FontWeight.w500),
  );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  const EmptyState({super.key, required this.icon, required this.title, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 88, color: context.palette.textMuted),
            const SizedBox(height: 20),
            Text(title, style: TextStyle(fontSize: 22, color: context.palette.textSecondary)),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.palette.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Rebuilds its child every [interval] — for live elapsed timers.
class Ticker extends StatefulWidget {
  final Duration interval;
  final Widget Function(BuildContext context, DateTime now) builder;
  const Ticker({super.key, this.interval = const Duration(seconds: 1), required this.builder});

  @override
  State<Ticker> createState() => _TickerState();
}

class _TickerState extends State<Ticker> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(widget.interval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, timeNow());
}

/// Colored pill naming the order's floor state.
class StatePill extends StatelessWidget {
  final OrderState state;
  final bool large;
  const StatePill(this.state, {super.key, this.large = false});

  @override
  Widget build(BuildContext context) {
    final c = stateColor(state);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 14 : 10, vertical: large ? 6 : 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(QuiccRadius.sm),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Text(
        state.label,
        style: TextStyle(color: c, fontSize: large ? 14 : 11, letterSpacing: 1.2, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Pickup / delivery / dine-in tag.
class FulfillmentTag extends StatelessWidget {
  final FulfillmentType type;
  final Color? color;
  final double size;
  const FulfillmentTag(this.type, {super.key, this.color, this.size = 13});

  @override
  Widget build(BuildContext context) {
    if (type == FulfillmentType.unknown) return const SizedBox.shrink();
    final c = color ?? (type == FulfillmentType.delivery ? QuiccColors.brand400 : context.palette.textSecondary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(fulfillmentIcon(type), size: size + 5, color: c),
        const SizedBox(width: 6),
        Text(
          type.label,
          style: TextStyle(color: c, fontSize: size, fontWeight: FontWeight.w700, letterSpacing: 1.2),
        ),
      ],
    );
  }
}

/// Compact item lines: "2× 12 Medium Pepperoni" + modifiers + notes.
class ItemLines extends StatelessWidget {
  final List<LineItem> items;
  final int? maxItems;
  final double fontSize;
  final Color? color;

  /// POS lines voided at the terminal (1.8.0): struck through in red with
  /// REMOVED, after the items.
  final List<LineItem> removed;

  /// Mark ADDED lines (rung at the terminal later) with a blue band.
  final bool marks;
  const ItemLines(
    this.items, {
    super.key,
    this.maxItems,
    this.fontSize = 15,
    this.color,
    this.removed = const [],
    this.marks = true,
  });

  @override
  Widget build(BuildContext context) {
    final muted = context.palette.textMuted;
    final shown = maxItems == null ? items : items.take(maxItems!).toList();
    final rest = items.length - shown.length;
    Widget line(LineItem i) {
      final title = Text(
        itemTitle(i),
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: marks && i.added ? QuiccColors.changeBlueDeep : color,
        ),
      );
      if (!marks || !i.added) return title;
      return Container(
        key: ValueKey('added-${i.id}'),
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: QuiccColors.changeBlueSoft,
          border: const Border(left: BorderSide(color: QuiccColors.changeBlue, width: 4)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Expanded(child: title),
            const SizedBox(width: 6),
            Text(
              'ADDED',
              style: TextStyle(
                fontSize: fontSize - 5,
                fontWeight: FontWeight.w800,
                color: QuiccColors.changeBlue,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final i in shown) ...[
          line(i),
          for (final c in i.children)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                '+ ${itemTitle(c)}',
                style: TextStyle(fontSize: fontSize - 2, color: color ?? muted),
              ),
            ),
          if (i.notes.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                '“${i.notes.trim()}”',
                style: TextStyle(
                  fontSize: fontSize - 2,
                  fontStyle: FontStyle.italic,
                  color: color ?? QuiccColors.statusFiring,
                ),
              ),
            ),
        ],
        if (rest > 0)
          Text(
            '+ $rest more item${rest == 1 ? '' : 's'}',
            style: TextStyle(fontSize: fontSize - 2, color: color ?? muted),
          ),
        for (final r in removed) RemovedLine(r, fontSize: fontSize),
      ],
    );
  }
}

/// A line voided at the terminal: struck through, red, REMOVED.
class RemovedLine extends StatelessWidget {
  final LineItem item;
  final double fontSize;
  const RemovedLine(this.item, {super.key, this.fontSize = 15});

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('removed-${item.id}'),
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Flexible(
            child: Text(
              itemTitle(item),
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: QuiccColors.removedRed,
                decoration: TextDecoration.lineThrough,
                decorationColor: QuiccColors.removedRed,
                decorationThickness: 2,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'REMOVED',
            style: TextStyle(
              fontSize: fontSize - 5,
              fontWeight: FontWeight.w800,
              color: QuiccColors.removedRed,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens one of the troubleshooting guides. features/diagnose sets
/// [openGuideHook] at startup; until then FIX IT does nothing.
typedef OpenGuide = void Function(BuildContext context, GuideId guide);

OpenGuide openGuideHook = (_, _) {};

/// Writes a friendly error's technical text to the on-tablet log (best
/// effort: no ProviderScope above [context] in some tests).
void logErrorDetails(BuildContext context, String area, FriendlyError f) {
  if (f.details.isEmpty) return;
  try {
    ProviderScope.containerOf(context, listen: false).read(localLogProvider).warn(area, '${f.title} · ${f.details}');
  } catch (_) {}
}

/// An error snackbar in plain words: [lead] (what didn't happen, e.g. "Not
/// printed") or the error's title, then what to do. DETAILS shows the
/// technical text; FIX IT opens the matching guide (or runs [onFix]). The
/// details go to the local log under [area].
void toastError(
  BuildContext context,
  Object e, {
  String? lead,
  String area = 'app',
  VoidCallback? onFix,
  double rightInset = 0,
}) {
  final f = e is FriendlyError ? e : FriendlyError.from(e);
  logErrorDetails(context, area, f);
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  final guide = f.guide;
  final fix = onFix ?? (guide == null ? null : () => openGuideHook(context, guide));
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: rightInset > 0 ? EdgeInsets.fromLTRB(24, 0, rightInset, 24) : null,
      backgroundColor: QuiccColors.statusVoided,
      duration: const Duration(seconds: 6),
      content: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(lead ?? f.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                if ((lead == null ? f.whatToDo : f.short).isNotEmpty) Text(lead == null ? f.whatToDo : f.short),
              ],
            ),
          ),
          if (f.details.isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () {
                m.hideCurrentSnackBar();
                showErrorDetails(context, f);
              },
              child: const Text('DETAILS'),
            ),
        ],
      ),
      action: fix == null ? null : SnackBarAction(label: 'FIX IT', textColor: Colors.white, onPressed: fix),
    ),
  );
}

/// The technical text behind an error, in a dialog.
Future<void> showErrorDetails(BuildContext context, FriendlyError f) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text(f.title),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (f.whatToDo.isNotEmpty) Text(f.whatToDo, style: const TextStyle(fontSize: 17)),
          const SizedBox(height: 12),
          const Eyebrow('Details (for the owner)'),
          const SizedBox(height: 4),
          SelectableText(f.details, style: TextStyle(fontSize: 13, color: ctx.palette.textMuted)),
        ],
      ),
    ),
    actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('CLOSE'))],
  ),
);

/// A small "Details" link that unfolds the technical text in place (works
/// where no dialog can open, e.g. on the full-screen alert).
class DetailsToggle extends StatefulWidget {
  final String details;
  final Color? color;
  const DetailsToggle(this.details, {super.key, this.color});

  @override
  State<DetailsToggle> createState() => _DetailsToggleState();
}

class _DetailsToggleState extends State<DetailsToggle> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.color ?? context.palette.textMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Details',
                  style: TextStyle(color: c, fontSize: 13, decoration: TextDecoration.underline, decorationColor: c),
                ),
                Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: c),
              ],
            ),
          ),
        ),
        if (_open) SelectableText(widget.details, style: TextStyle(color: c, fontSize: 13)),
      ],
    );
  }
}

/// Inline error banner: [message], then [whatToDo], a Details link for
/// [details], RETRY and FIX IT (opens [guide]'s guide, or runs [onFix]).
class InlineError extends StatefulWidget {
  final String message;
  final String whatToDo;
  final String details;
  final GuideId? guide;
  final VoidCallback? onRetry;
  final VoidCallback? onFix;

  /// When set, [details] are written to the local log under this area (once
  /// per distinct text).
  final String? logArea;

  const InlineError(
    this.message, {
    super.key,
    this.whatToDo = '',
    this.details = '',
    this.guide,
    this.onRetry,
    this.onFix,
    this.logArea,
  });

  /// [e] in plain words ([FriendlyError.from]); [lead] names what didn't
  /// happen ("Reports not loaded") and the error's own title follows it.
  /// [fixIt] false hides FIX IT (e.g. above the navigator).
  factory InlineError.from(
    Object e, {
    Key? key,
    String? lead,
    String? area,
    VoidCallback? onRetry,
    VoidCallback? onFix,
    bool fixIt = true,
  }) {
    final f = e is FriendlyError ? e : FriendlyError.from(e);
    return InlineError(
      lead ?? f.title,
      key: key,
      whatToDo: lead == null ? f.whatToDo : f.short,
      details: f.details,
      guide: fixIt ? f.guide : null,
      onRetry: onRetry,
      onFix: fixIt ? onFix : null,
      logArea: area,
    );
  }

  @override
  State<InlineError> createState() => _InlineErrorState();
}

class _InlineErrorState extends State<InlineError> {
  @override
  void initState() {
    super.initState();
    _log();
  }

  @override
  void didUpdateWidget(InlineError old) {
    super.didUpdateWidget(old);
    if (old.details != widget.details) _log();
  }

  void _log() {
    final area = widget.logArea;
    if (area == null || widget.details.isEmpty) return;
    logErrorDetails(context, area, FriendlyError(widget.message, details: widget.details));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final guide = w.guide;
    final fix = w.onFix ?? (guide == null ? null : () => openGuideHook(context, guide));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: QuiccColors.statusVoided.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        border: Border.all(color: QuiccColors.statusVoided.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: QuiccColors.statusVoided),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  w.message,
                  style: const TextStyle(color: QuiccColors.statusVoided, fontWeight: FontWeight.w600),
                ),
                if (w.whatToDo.isNotEmpty) Text(w.whatToDo, style: TextStyle(color: context.palette.textSecondary)),
                if (w.details.isNotEmpty) DetailsToggle(w.details),
              ],
            ),
          ),
          if (fix != null) TextButton(onPressed: fix, child: const Text('FIX IT')),
          if (w.onRetry != null) TextButton(onPressed: w.onRetry, child: const Text('RETRY')),
        ],
      ),
    );
  }
}

/// Simple confirm dialog. Resolves true on confirm.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = 'CONFIRM',
  String cancel = 'CANCEL',
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(cancel)),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: QuiccColors.statusVoided) : null,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Single text-field dialog (driver add / rename). Resolves the trimmed text.
Future<String?> textDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String confirm = 'SAVE',
  int maxLength = 40,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _TextDialog(title: title, initial: initial, hint: hint, confirm: confirm, maxLength: maxLength),
  );
}

// Owns its controller: disposing it when showDialog's future completes is too
// early — the TextField still builds during the exit animation.
class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.confirm,
    required this.maxLength,
  });

  final String title, initial, hint, confirm;
  final int maxLength;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          maxLength: widget.maxLength,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: widget.hint),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()), child: Text(widget.confirm)),
      ],
    );
  }
}

/// The small "POS" tag on an order pulled from the store's old POS (1.5.0).
class PosTag extends StatelessWidget {
  final Color? color;
  final double size;
  const PosTag({super.key, this.color, this.size = 11});

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.palette.textSecondary;
    return Container(
      key: const ValueKey('pos-tag'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c, width: 1.5),
      ),
      child: Text(
        'POS',
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: c, height: 1.2),
      ),
    );
  }
}

/// "PAID": settled at the POS (or an inserted online cash pickup settled).
class PaidBadge extends StatelessWidget {
  final double size;
  const PaidBadge({super.key, this.size = 11});

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('paid-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: QuiccColors.statusPaid, borderRadius: BorderRadius.circular(6)),
    child: Text(
      'PAID',
      style: TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
        color: QuiccColors.brand900,
        height: 1.2,
      ),
    ),
  );
}

/// Colour for a hub severity: info blue, warn amber, serious red.
Color severityColor(Severity s) => switch (s) {
  Severity.info => QuiccColors.statusOpen,
  Severity.warn => QuiccColors.statusFiring,
  Severity.serious => QuiccColors.statusVoided,
};

/// An order's `flag` (e.g. "Settle manually: unmapped item X"): an icon and
/// the text in the severity colour, on a tinted strip.
class OrderFlagLine extends StatelessWidget {
  final OrderFlag flag;
  final double fontSize;
  const OrderFlagLine(this.flag, {super.key, this.fontSize = 13});

  @override
  Widget build(BuildContext context) {
    final c = severityColor(flag.severity);
    return Container(
      key: const ValueKey('order-flag'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(QuiccRadius.sm),
        border: Border.all(color: c.withValues(alpha: 0.7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(flag.severity == Severity.info ? Icons.info_outline : Icons.warning_amber, size: fontSize + 5, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              flag.text,
              style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
