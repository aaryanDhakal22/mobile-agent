import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';

/// How the store hub's problems show (1.5.0): `info` / `warn` as a toast in
/// the top-right corner (once per problem, it fades by itself), `serious`
/// ("POS link down", "Quicc batch not open in SoftTouch") as a full-width
/// banner that stays until the hub clears it.
enum ProblemDisplay { toast, banner }

ProblemDisplay displayFor(Severity s) => s == Severity.serious ? ProblemDisplay.banner : ProblemDisplay.toast;

/// How long a toast stays up.
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

class _Toast {
  final int id;
  final String text;
  final Severity severity;
  Timer? timer;
  _Toast(this.id, this.text, this.severity);
}

/// Top-right toasts: new `info` / `warn` problems from the hub and SSE
/// `integration.toast` messages. Place it in a Stack over the content.
class IntegrationToastHost extends ConsumerStatefulWidget {
  const IntegrationToastHost({super.key});

  @override
  ConsumerState<IntegrationToastHost> createState() => _IntegrationToastHostState();
}

class _IntegrationToastHostState extends ConsumerState<IntegrationToastHost> {
  final List<_Toast> _shown = [];

  /// Minor problems currently reported (a problem that clears and comes
  /// back toasts again).
  Set<String> _known = {};
  int _next = 0;

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
    final keys = {for (final p in minor) p.key};
    for (final p in minor) {
      if (!_known.contains(p.key)) _add(p.text, p.severity, defer: true);
    }
    _known = keys;
  }

  void _add(String text, Severity severity, {bool defer = false}) {
    final t = _Toast(_next++, text, severity);
    t.timer = Timer(kIntegrationToastFor, () => _dismiss(t.id));
    void apply() {
      if (!mounted) return;
      setState(() {
        _shown.add(t);
        while (_shown.length > 3) {
          _shown.removeAt(0).timer?.cancel();
        }
      });
    }

    // From a listener that fires during build: show on the next frame.
    defer ? WidgetsBinding.instance.addPostFrameCallback((_) => apply()) : apply();
  }

  void _dismiss(int id) {
    if (!mounted) return;
    setState(() {
      _shown.removeWhere((t) {
        if (t.id != id) return false;
        t.timer?.cancel();
        return true;
      });
    });
  }

  @override
  void dispose() {
    for (final t in _shown) {
      t.timer?.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_shown.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('integration-toasts'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [for (final t in _shown) _ToastCard(toast: t, onClose: () => _dismiss(t.id))],
    );
  }
}

class _ToastCard extends StatelessWidget {
  final _Toast toast;
  final VoidCallback onClose;
  const _ToastCard({required this.toast, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final c = severityColor(toast.severity);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Material(
          key: ValueKey('integration-toast-${toast.id}'),
          elevation: 6,
          color: context.palette.bgElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(QuiccRadius.md),
            side: BorderSide(color: c, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(toast.severity == Severity.info ? Icons.info_outline : Icons.warning_amber, color: c),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(toast.text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: Icon(Icons.close, size: 18, color: context.palette.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
