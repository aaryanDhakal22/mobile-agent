import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/printer_models.dart';
import '../../core/providers.dart';
import '../../theme/pop_in.dart';
import '../../theme/quicc_colors.dart';
import 'edit_printer_ip_dialog.dart';

class PrinterPane extends ConsumerWidget {
  const PrinterPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printers = ref.watch(printerStatusStreamProvider);
    final anyUp = printers.maybeWhen(
      data: (list) => list.any((p) => p.up),
      orElse: () => false,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                'Printers',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 16),
              _PollIndicator(healthy: anyUp),
              const Spacer(),
              _HeaderSummary(printers: printers),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Live status â€” polls the agent every 5 seconds.',
            style: TextStyle(color: context.palette.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: printers.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _UnreachableAgent(error: e.toString()),
              data: (list) {
                if (list.isEmpty) {
                  return Center(
                    child: Text(
                      'No printers registered.',
                      style: TextStyle(color: context.palette.textMuted),
                    ),
                  );
                }
                return _PrinterGrid(printers: list);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderSummary extends StatelessWidget {
  final AsyncValue<List<PrinterStatus>> printers;
  const _HeaderSummary({required this.printers});

  @override
  Widget build(BuildContext context) {
    return printers.maybeWhen(
      data: (list) {
        final up = list.where((p) => p.up).length;
        final total = list.length;
        final color = up == total
            ? QuiccColors.statusPaid
            : up == 0
                ? QuiccColors.statusVoided
                : QuiccColors.statusFiring;
        return Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              '$up of $total online',
              style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _PollIndicator extends StatefulWidget {
  final bool healthy;
  const _PollIndicator({required this.healthy});
  @override
  State<_PollIndicator> createState() => _PollIndicatorState();
}

class _PollIndicatorState extends State<_PollIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, _) {
          final t = _pulse.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: (1 - t).clamp(0, 1),
                child: Container(
                  width: 8 + (t * 14),
                  height: 8 + (t * 14),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (widget.healthy ? QuiccColors.statusPaid : QuiccColors.statusVoided)
                        .withValues(alpha: 0.35),
                  ),
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.healthy ? QuiccColors.statusPaid : QuiccColors.statusVoided,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PrinterGrid extends StatelessWidget {
  final List<PrinterStatus> printers;
  const _PrinterGrid({required this.printers});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cross = c.maxWidth >= 1100 ? 3 : (c.maxWidth >= 720 ? 2 : 1);
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 1.35,
          ),
          itemCount: printers.length,
          itemBuilder: (_, i) => PopIn.stagger(
            index: i,
            child: _PrinterCard(printer: printers[i]),
          ),
        );
      },
    );
  }
}

class _PrinterCard extends StatelessWidget {
  final PrinterStatus printer;
  const _PrinterCard({required this.printer});

  Color get _accent =>
      printer.up ? QuiccColors.statusPaid : QuiccColors.statusVoided;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.palette.bgSurface,
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        border: Border.all(
          color: _accent.withValues(alpha: printer.hasIP ? 0.28 : 0.15),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PrinterIcon(up: printer.up, hasIP: printer.hasIP),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      printer.name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _StatusPill(up: printer.up, hasIP: printer.hasIP),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _IPRow(printer: printer),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          _MetaRows(printer: printer),
          if (printer.lastError.isNotEmpty && !printer.up) ...[
            const SizedBox(height: 12),
            _ErrorBanner(text: _friendlyError(printer.lastError)),
          ],
        ],
      ),
    );
  }
}

class _PrinterIcon extends StatelessWidget {
  final bool up;
  final bool hasIP;
  const _PrinterIcon({required this.up, required this.hasIP});

  @override
  Widget build(BuildContext context) {
    final color = !hasIP
        ? context.palette.textMuted
        : (up ? QuiccColors.statusPaid : QuiccColors.statusVoided);
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(QuiccRadius.md),
      ),
      alignment: Alignment.center,
      child: Icon(
        up ? Icons.print_rounded : Icons.print_disabled_rounded,
        size: 30,
        color: color,
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool up;
  final bool hasIP;
  const _StatusPill({required this.up, required this.hasIP});

  @override
  Widget build(BuildContext context) {
    final (label, color) = !hasIP
        ? ('NOT CONFIGURED', context.palette.textMuted)
        : up
            ? ('ONLINE', QuiccColors.statusPaid)
            : ('OFFLINE', QuiccColors.statusVoided);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _IPRow extends ConsumerWidget {
  final PrinterStatus printer;
  const _IPRow({required this.printer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Icon(Icons.lan_outlined, size: 16, color: context.palette.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            printer.hasIP ? printer.ip : 'No IP configured',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: printer.hasIP ? context.palette.textPrimary : context.palette.textMuted,
              fontStyle: printer.hasIP ? FontStyle.normal : FontStyle.italic,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.edit_outlined, size: 18),
          color: QuiccColors.brand400,
          tooltip: 'Edit IP',
          onPressed: () async {
            final newIp = await showEditPrinterIpDialog(
              context,
              name: printer.name,
              currentIp: printer.ip,
            );
            if (newIp == null) return;
            try {
              await ref.read(agentClientProvider).setPrinterIP(printer.name, newIp);
              ref.invalidate(printerStatusStreamProvider);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text('Set ${printer.name} IP to $newIp'),
                  ),
                );
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    backgroundColor: QuiccColors.statusVoided,
                    content: Text('Failed: $e'),
                  ),
                );
              }
            }
          },
        ),
      ],
    );
  }
}

class _MetaRows extends StatelessWidget {
  final PrinterStatus printer;
  const _MetaRows({required this.printer});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (printer.up && printer.upSince != null)
          _MetaLine(
            icon: Icons.arrow_upward_rounded,
            iconColor: QuiccColors.statusPaid,
            text: 'Online for ${_formatDuration(printer.upSince!)}',
          )
        else if (!printer.up && printer.downSince != null)
          _MetaLine(
            icon: Icons.arrow_downward_rounded,
            iconColor: QuiccColors.statusVoided,
            text: 'Offline for ${_formatDuration(printer.downSince!)}',
          )
        else
          _MetaLine(
            icon: Icons.help_outline,
            iconColor: context.palette.textMuted,
            text: 'Awaiting first probe',
          ),
        const SizedBox(height: 6),
        _MetaLine(
          icon: Icons.check_circle_outline,
          iconColor: context.palette.textMuted,
          text: printer.lastChecked == null
              ? 'Never probed'
              : 'Last checked ${_formatRelative(printer.lastChecked!)}',
        ),
      ],
    );
  }
}

class _MetaLine extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String text;
  const _MetaLine({
    required this.icon,
    required this.iconColor,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, color: context.palette.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String text;
  const _ErrorBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: QuiccColors.statusVoided.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(QuiccRadius.sm),
        border: Border.all(color: QuiccColors.statusVoided.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: QuiccColors.statusVoided),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: QuiccColors.statusVoided),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnreachableAgent extends StatelessWidget {
  final String error;
  const _UnreachableAgent({required this.error});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 72, color: QuiccColors.statusVoided),
            const SizedBox(height: 16),
            const Text(
              "Can't reach the agent",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 6),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.palette.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(DateTime from) {
  final diff = DateTime.now().difference(from);
  if (diff.isNegative) return '0 s';
  if (diff.inSeconds < 60) return '${diff.inSeconds} s';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min';
  if (diff.inHours < 24) {
    final h = diff.inHours;
    final m = diff.inMinutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
  return '${diff.inDays}d';
}

String _formatRelative(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.isNegative) return 'just now';
  if (diff.inSeconds < 10) return 'just now';
  if (diff.inSeconds < 60) return '${diff.inSeconds} s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return '${diff.inDays} d ago';
}

/// Maps common Go-side probe errors to short human labels. Raw Go network
/// errors like `dial tcp 192.168.1.50:9100: connect: connection refused`
/// blow out the card layout and read as noise to the cashier, so we catch
/// the patterns we know and truncate the rest to the last ':'-delimited
/// fragment.
String _friendlyError(String raw) {
  if (raw.isEmpty) return 'Probe failed';
  final lower = raw.toLowerCase();
  if (lower.contains('connection refused')) return 'Connection refused';
  if (lower.contains('i/o timeout') || lower.contains('deadline exceeded')) {
    return 'Connection timed out';
  }
  if (lower.contains('no route to host')) return 'No route to host';
  if (lower.contains('network is unreachable')) return 'Network unreachable';
  if (lower.contains('host is down')) return 'Host is down';
  if (lower.contains('name resolution') || lower.contains('no such host')) {
    return 'Host not found';
  }
  // Fallback: take the last colon-separated fragment â€” strips the Go-style
  // `dial tcp <ip>:<port>: connect: <reason>` prefix that wraps most errors.
  final parts = raw.split(':');
  final tail = parts.last.trim();
  return tail.isEmpty ? raw : tail;
}
