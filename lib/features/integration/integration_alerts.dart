import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/island.dart';

/// How the store hub's problems show (1.5.0): `info` / `warn` as a pill in
/// the notification island (once per problem, it fades by itself), `serious`
/// ("POS link down", "Quicc batch not open in SoftTouch") as a full-width
/// banner that stays until the hub clears it.
enum ProblemDisplay { toast, banner }

ProblemDisplay displayFor(Severity s) => s == Severity.serious ? ProblemDisplay.banner : ProblemDisplay.toast;

/// How long a hub toast stays up (longer than the island's own notices).
const Duration kIntegrationToastFor = Duration(seconds: 8);

/// The serious problems, full width under the other warning bars.
class IntegrationBanner extends ConsumerWidget {
  const IntegrationBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problems = ref.watch(
      floorProvider.select((s) => s.floor?.integration?.problems ?? const <IntegrationProblem>[]),
    );
    final serious = [
      for (final p in problems)
        if (displayFor(p.severity) == ProblemDisplay.banner) p,
    ];
    if (serious.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('integration-banner'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in serious)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
            color: QuiccColors.statusVoided,
            child: Row(
              children: [
                const Icon(Icons.link_off, color: QuiccColors.brand900, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    p.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: QuiccColors.brand900),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The island's kind for a hub problem / toast.
IslandKind islandKindFor(Severity s) => switch (s) {
  Severity.info => IslandKind.info,
  Severity.warn => IslandKind.warn,
  Severity.serious => IslandKind.error,
};

/// Feeds the notification island (1.9.0; it was its own top-right toast
/// host): new `info` / `warn` problems from the hub (once per problem — one
/// that clears and comes back shows again) and every SSE `integration.toast`
/// (the hub's messages, "Printed Juma's report"; a failed `driver.route`,
/// "Couldn't send Abdul's route", comes the same way). Each stays
/// [kIntegrationToastFor]. Mount it under an [IslandHost], once paired.
class IntegrationIslandFeed extends ConsumerStatefulWidget {
  final Widget child;
  const IntegrationIslandFeed({super.key, required this.child});

  @override
  ConsumerState<IntegrationIslandFeed> createState() => _IntegrationIslandFeedState();
}

class _IntegrationIslandFeedState extends ConsumerState<IntegrationIslandFeed> {
  /// Minor problems currently reported.
  Set<String> _known = {};

  @override
  void initState() {
    super.initState();
    ref.listenManual<List<IntegrationProblem>>(
      floorProvider.select((s) => s.floor?.integration?.problems ?? const <IntegrationProblem>[]),
      (_, problems) => _onProblems(problems),
      fireImmediately: true,
    );
    ref.listenManual<int>(floorProvider.select((s) => s.toasts), (prev, next) {
      final t = ref.read(floorProvider).toast;
      if (t != null && next > (prev ?? 0)) _add(t.text, t.severity);
    });
  }

  void _onProblems(List<IntegrationProblem> problems) {
    final minor = [
      for (final p in problems)
        if (displayFor(p.severity) == ProblemDisplay.toast) p,
    ];
    for (final p in minor) {
      if (!_known.contains(p.key)) _add(p.text, p.severity);
    }
    _known = {for (final p in minor) p.key};
  }

  void _add(String text, Severity severity) {
    if (!mounted) return;
    Island.maybeOf(context)?.show(text, kind: islandKindFor(severity), duration: kIntegrationToastFor);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
