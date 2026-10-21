import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/friendly_error.dart';
import '../../core/printer_models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';

/// Read-only printer reachability (the agent probes every ~25 s). Printers
/// are configured in main's web app, not here.
class PrintersPane extends ConsumerWidget {
  const PrintersPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printers = ref.watch(printerStatusProvider);
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        PaneHeader(
          title: 'Printers',
          subtitle: printers.valueOrNull == null
              ? null
              : '${printers.valueOrNull!.where((p) => p.up).length} of ${printers.valueOrNull!.length} online',
        ),
        Text(
          'Printers are set up in the Quicc web app (Store → Printers). Status can be up to ~25 s old.',
          style: TextStyle(color: context.palette.textMuted),
        ),
        const SizedBox(height: 16),
        if (printers.hasError) ...[
          InlineError.from(printers.error!, lead: 'Could not load printer status', area: 'printers'),
          const SizedBox(height: 12),
        ],
        if (printers.valueOrNull == null && !printers.hasError)
          const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (printers.valueOrNull != null && printers.valueOrNull!.isEmpty)
          const EmptyState(
            icon: Icons.print_disabled_outlined,
            title: 'No printers',
            message: 'The agent has no printers yet. Add them in the Quicc web app.',
          ),
        for (final p in printers.valueOrNull ?? const <PrinterStatus>[]) _PrinterCard(p),
      ],
    );
  }
}

class _PrinterCard extends StatelessWidget {
  final PrinterStatus p;
  const _PrinterCard(this.p);

  @override
  Widget build(BuildContext context) {
    final c = p.up ? QuiccColors.statusPaid : QuiccColors.statusVoided;
    final since = p.up ? p.upSince : p.downSince;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  Text(
                    p.hasIP ? p.ip : 'No address configured',
                    style: TextStyle(color: context.palette.textSecondary),
                  ),
                  if (!p.up && p.hasIP) ...[
                    const Text(
                      'Not answering. Check it is switched on and its cable is plugged in.',
                      style: TextStyle(color: QuiccColors.statusVoided),
                    ),
                    if (p.lastError.isNotEmpty) DetailsToggle(p.lastError),
                  ],
                ],
              ),
            ),
            if (!p.up && p.hasIP) ...[
              OutlinedButton.icon(
                onPressed: () => openGuideHook(context, GuideId.printer),
                icon: const Icon(Icons.build_outlined),
                label: const Text('FIX IT'),
              ),
              const SizedBox(width: 16),
            ],
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  p.up ? 'ONLINE' : 'OFFLINE',
                  style: TextStyle(color: c, fontWeight: FontWeight.w800, letterSpacing: 1.5),
                ),
                if (since != null) Text('since ${clock(since)}', style: TextStyle(color: context.palette.textMuted)),
                if (p.lastChecked != null)
                  Text(
                    'checked ${clock(p.lastChecked)}',
                    style: TextStyle(color: context.palette.textMuted, fontSize: 12),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
