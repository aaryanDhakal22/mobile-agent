import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models.dart';
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
  Widget build(BuildContext context) => widget.builder(context, DateTime.now());
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
  const ItemLines(this.items, {super.key, this.maxItems, this.fontSize = 15, this.color});

  @override
  Widget build(BuildContext context) {
    final muted = context.palette.textMuted;
    final shown = maxItems == null ? items : items.take(maxItems!).toList();
    final rest = items.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final i in shown) ...[
          Text(
            itemTitle(i),
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600, color: color),
          ),
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
      ],
    );
  }
}

/// Inline error banner with an optional action.
class InlineError extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const InlineError(this.message, {super.key, this.onRetry});

  @override
  Widget build(BuildContext context) {
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
            child: Text(
              message,
              style: const TextStyle(color: QuiccColors.statusVoided, fontWeight: FontWeight.w600),
            ),
          ),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('RETRY')),
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
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('CANCEL')),
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
    builder: (ctx) => _TextDialog(
      title: title,
      initial: initial,
      hint: hint,
      confirm: confirm,
      maxLength: maxLength,
    ),
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
