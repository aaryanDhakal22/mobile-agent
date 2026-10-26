import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/device_platform.dart';
import '../../core/diag_models.dart';
import '../../core/format.dart';
import '../../core/friendly_error.dart';
import '../../core/providers.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import '../illustrations/illustration.dart';
import 'guide_session.dart';
import 'guides.dart';
import 'texts.dart';

String guideName(GuideId g) => switch (g) {
  GuideId.piUnreachable => GuideText.piUnreachableName,
  GuideId.printer => GuideText.printerName,
  GuideId.noOrders => GuideText.noOrdersName,
  GuideId.piSwap => GuideText.piSwapName,
};

/// One troubleshooting guide, one big step card at a time: the drawing on the
/// left, what to do on the right, big buttons. Waits re-check by themselves.
/// Pass [start] to begin a guide; without it the saved session is resumed.
class GuideScreen extends ConsumerStatefulWidget {
  final GuideId? start;
  final Map<String, String> params;
  const GuideScreen({super.key, this.start, this.params = const {}});

  @override
  ConsumerState<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends ConsumerState<GuideScreen> {
  Timer? _poll;
  Timer? _tick;
  String? _pollingFor;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    scheduleMicrotask(() {
      if (!mounted) return;
      final c = ref.read(guideControllerProvider.notifier);
      final s = widget.start;
      unawaited(s == null ? c.resume() : c.start(s, params: widget.params));
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  /// Keeps one poll timer running while the current step waits.
  void _syncPoll(GuideView v) {
    final st = v.step;
    final s = v.session;
    final waiting = st != null && s != null && (st.kind == StepKind.wait || s.settling);
    final key = waiting ? '${s.id}/${st.id}/${s.settling}' : null;
    if (key == _pollingFor) return;
    _poll?.cancel();
    _poll = null;
    _pollingFor = key;
    if (key != null) {
      _poll = Timer.periodic(st!.poll, (_) => unawaited(ref.read(guideControllerProvider.notifier).poll()));
    }
  }

  Future<void> _exit() async {
    final v = ref.read(guideControllerProvider);
    final s = v.session;
    if (s != null && !s.concluded && s.history.isNotEmpty) {
      final ok = await confirmDialog(
        context,
        title: GuideText.exitTitle,
        message: GuideText.exitBody,
        confirm: GuideText.exit,
      );
      if (!ok) return;
    }
    await ref.read(guideControllerProvider.notifier).exit();
    _leave();
  }

  /// pop(), not maybePop(): PopScope would send us back to [_exit].
  void _leave() {
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _close() async {
    await ref.read(guideControllerProvider.notifier).clear();
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(guideControllerProvider);
    _syncPoll(v);
    final s = v.session;
    final palette = context.palette;
    final title = s == null ? GuideText.helpTitle : guideName(s.guide);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(s?.concluded == true ? _close() : _exit());
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: palette.bgSurface,
          automaticallyImplyLeading: false,
          title: Row(
            children: [
              Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              if (s != null && !s.concluded) ...[
                const SizedBox(width: 16),
                Text(
                  '${GuideText.stepOf} ${s.history.length + 1}',
                  style: TextStyle(fontSize: 15, color: palette.textMuted),
                ),
              ],
            ],
          ),
          actions: [
            const InfoButton(GuideText.guidesInfo),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: s?.concluded == true
                  ? TextButton(onPressed: _close, child: const Text(GuideText.close))
                  : TextButton.icon(onPressed: _exit, icon: const Icon(Icons.close), label: const Text(GuideText.exit)),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: KeyedSubtree(key: ValueKey('${s?.id}/${s?.stepId}/${s?.concluded}'), child: _body(v)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(GuideView v) {
    final s = v.session;
    if (s == null) return const _Checking(GuideText.checking);
    if (s.concluded) return _ConclusionCard(session: s, onClose: _close);
    final st = v.step;
    if (st == null) return const _Checking(GuideText.checking);
    return _StepCard(view: v, step: st);
  }
}

class _Checking extends StatelessWidget {
  final String label;
  const _Checking(this.label);

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 5)),
        const SizedBox(height: 20),
        Text(label, style: TextStyle(fontSize: 22, color: context.palette.textSecondary)),
      ],
    ),
  );
}

// =============================================================================
// Step card
// =============================================================================

class _StepCard extends ConsumerWidget {
  final GuideView view;
  final GuideStep step;
  const _StepCard({required this.view, required this.step});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final c = ref.read(guideControllerProvider.notifier);
    final s = view.session!;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: LayoutBuilder(
          builder: (context, box) {
            final artWidth = (box.maxWidth * 0.36).clamp(180.0, 360.0);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IllustrationView(step.art, highlight: step.highlight, blink: step.blink, width: artWidth),
                const SizedBox(width: 32),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                step.title,
                                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, height: 1.15),
                              ),
                            ),
                            if (step.info != null) InfoButton(step.info!, size: 26),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(step.body, style: TextStyle(fontSize: 20, height: 1.4, color: palette.textSecondary)),
                        if (view.error != null) ...[const SizedBox(height: 14), InlineError(view.error!.short)],
                        const SizedBox(height: 28),
                        _controls(context, ref, c, s),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _controls(BuildContext context, WidgetRef ref, GuideController c, GuideSession s) {
    final busy = view.checking;
    final canBack = c.canGoBack;
    Widget backBtn() => TextButton.icon(
      onPressed: busy ? null : c.back,
      icon: const Icon(Icons.arrow_back),
      label: const Text(GuideText.back),
    );

    if (step.kind == StepKind.wait || s.settling) {
      final since = s.waitStartedAt ?? timeNow();
      final elapsed = timeNow().difference(since);
      final label = s.settling ? GuideText.checking.replaceAll('…', ' again…') : '${step.title}…';
      return _WaitStatus(label: label, elapsed: elapsed, max: step.timeout);
    }
    if (step.kind == StepKind.auto || busy && step.kind != StepKind.login) {
      return const _WaitStatus(label: GuideText.checking);
    }

    final buttons = <Widget>[];
    switch (step.kind) {
      case StepKind.question:
        buttons.addAll([
          _BigButton(GuideText.yes, onTap: () => c.answer('yes')),
          _BigButton(GuideText.no, onTap: () => c.answer('no'), outlined: true),
        ]);
      case StepKind.info:
        buttons.add(_BigButton(GuideText.next, onTap: () => c.answer('next')));
      case StepKind.action:
        if (step.opens != null) {
          buttons.add(
            _BigButton(
              'OPEN ${step.opens == DeviceSetting.wifi ? 'WI-FI' : 'SETTINGS'}',
              icon: Icons.settings,
              outlined: true,
              onTap: () => ref.read(devicePlatformProvider).openSettings(step.opens!),
            ),
          );
        }
        buttons.add(_BigButton(GuideText.testAgain, icon: Icons.refresh, onTap: c.testAgain));
      case StepKind.choice:
        for (final o in step.options) {
          buttons.add(_BigButton(o.label, onTap: () => c.answer(o.id)));
        }
      case StepKind.pickPrinter:
        final ps = view.snapshot?.printers ?? const <DiagPrinter>[];
        for (final p in ps) {
          buttons.add(
            _BigButton(
              p.name.isEmpty ? p.ip : p.name,
              icon: p.up ? Icons.print : Icons.print_disabled,
              onTap: () => c.answer(p.id),
            ),
          );
        }
      case StepKind.login:
        return _LoginPanel(onBack: canBack ? c.back : null);
      case StepKind.pairCode:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PairCodePanel(),
            const SizedBox(height: 20),
            _BigButton(GuideText.next, onTap: () => c.answer('next')),
          ],
        );
      case StepKind.auto:
      case StepKind.wait:
        break;
    }
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [...buttons, if (canBack) backBtn()],
    );
  }
}

class _BigButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool outlined;
  const _BigButton(this.label, {this.onTap, this.icon, this.outlined = false});

  @override
  Widget build(BuildContext context) {
    const pad = EdgeInsets.symmetric(horizontal: 32, vertical: 22);
    const text = TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 0.5);
    final child = icon == null
        ? Text(label)
        : Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 24), const SizedBox(width: 10), Text(label)]);
    final b = outlined
        ? OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(padding: pad, textStyle: text, minimumSize: const Size(140, 64)),
            child: child,
          )
        : FilledButton(
            onPressed: onTap,
            style: FilledButton.styleFrom(padding: pad, textStyle: text, minimumSize: const Size(140, 64)),
            child: child,
          );
    return b;
  }
}

/// Spinner + live status ("Starting the new card… 1:20 of up to 15:00").
class _WaitStatus extends StatelessWidget {
  final String label;
  final Duration? elapsed;
  final Duration max;
  const _WaitStatus({required this.label, this.elapsed, this.max = Duration.zero});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final e = elapsed;
    return Row(
      children: [
        const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 4)),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              if (e != null) ...[
                const SizedBox(height: 4),
                Text(
                  max > Duration.zero ? '${duration(e)} (up to ${duration(max)})' : duration(e),
                  style: TextStyle(fontSize: 17, color: palette.textMuted),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Login (swap / relink)
// =============================================================================

class _LoginPanel extends ConsumerStatefulWidget {
  final VoidCallback? onBack;
  const _LoginPanel({this.onBack});

  @override
  ConsumerState<_LoginPanel> createState() => _LoginPanelState();
}

class _LoginPanelState extends ConsumerState<_LoginPanel> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  FriendlyError? _error;

  /// The Pi has no internet yet: retry by itself every 15 s.
  int? _retryIn;
  Timer? _retry;

  @override
  void dispose() {
    _retry?.cancel();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    _retry?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _retryIn = null;
    });
    try {
      await ref.read(guideControllerProvider.notifier).login(username: _user.text, password: _pass.text);
    } catch (e) {
      if (!mounted) return;
      final f = FriendlyError.from(e is StateError ? const AgentException("Can't reach the Pi") : e);
      final needsInternet = e is AgentException && (e.code == 'needs_internet' || e.code == 'server_unreachable');
      setState(() {
        _error = f;
        if (needsInternet) {
          _retryIn = 15;
          _retry = Timer.periodic(const Duration(seconds: 1), (t) {
            if (!mounted) return t.cancel();
            setState(() => _retryIn = (_retryIn ?? 1) - 1);
            if ((_retryIn ?? 0) <= 0) {
              t.cancel();
              unawaited(_submit());
            }
          });
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _user,
          enabled: !_busy,
          style: const TextStyle(fontSize: 20),
          decoration: const InputDecoration(labelText: 'Username'),
          textInputAction: TextInputAction.next,
          autocorrect: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pass,
          enabled: !_busy,
          obscureText: true,
          style: const TextStyle(fontSize: 20),
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          InlineError(_retryIn == null ? _error!.short : '${_error!.title}. Trying again in $_retryIn s…'),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 14,
          children: [
            _BigButton(_busy ? 'SIGNING IN…' : 'SIGN IN', onTap: _busy ? null : _submit),
            if (widget.onBack != null)
              TextButton.icon(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back), label: const Text('BACK')),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// Pairing code
// =============================================================================

/// This tablet's 6-digit pairing code, big, with its expiry countdown.
class PairCodePanel extends ConsumerStatefulWidget {
  const PairCodePanel({super.key});

  @override
  ConsumerState<PairCodePanel> createState() => _PairCodePanelState();
}

class _PairCodePanelState extends ConsumerState<PairCodePanel> {
  PairingCode? _code;
  FriendlyError? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_load);
  }

  Future<void> _load() async {
    final c = ref.read(agentClientProvider);
    if (c == null || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final code = await c.pairingCode();
      if (mounted) setState(() => _code = code);
    } catch (e) {
      if (mounted) setState(() => _error = FriendlyError.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (_error != null) return InlineError(_error!.short, onRetry: _load);
    final code = _code;
    if (code == null) {
      return _loading ? const _WaitStatus(label: GuideText.checking) : const SizedBox.shrink();
    }
    return Ticker(
      builder: (context, now) {
        final left = code.expiresAt?.difference(now);
        final expired = left != null && left.isNegative;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              decoration: BoxDecoration(
                color: palette.bgElevated,
                borderRadius: BorderRadius.circular(QuiccRadius.lg),
                border: Border.all(color: QuiccColors.brand400.withValues(alpha: 0.6), width: 2),
              ),
              child: Text(
                expired ? '— — —' : '${code.code.substring(0, 3)} ${code.code.substring(3)}',
                style: TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 8,
                  color: expired ? palette.textMuted : QuiccColors.brand400,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  expired ? 'This code expired.' : (left == null ? '' : 'Works for ${duration(left)}'),
                  style: TextStyle(fontSize: 17, color: palette.textMuted),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('NEW CODE'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// "Pair another tablet" as a screen of its own (Help, Settings).
class PairAnotherTabletScreen extends StatelessWidget {
  const PairAnotherTabletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(GuideText.pairAnother)),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Row(
          children: [
            const IllustrationView(Illustration.tablet, highlight: IllustrationPart.wifi, width: 260),
            const SizedBox(width: 32),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    StepText.pairCode.body,
                    style: TextStyle(fontSize: 20, height: 1.4, color: context.palette.textSecondary),
                  ),
                  const SizedBox(height: 24),
                  const PairCodePanel(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Conclusion
// =============================================================================

class _ConclusionCard extends StatelessWidget {
  final GuideSession session;
  final VoidCallback onClose;
  const _ConclusionCard({required this.session, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final c = session.conclusion!;
    final good = c.outcome.good;
    final color = good ? QuiccColors.statusPaid : QuiccColors.statusFiring;
    final palette = context.palette;
    final heading = switch (c.outcome) {
      Outcome.fixed || Outcome.ok => GuideText.worked,
      Outcome.info => GuideText.nothingWrong,
      _ => GuideText.ownerTold,
    };
    final sent = switch (session.sent) {
      'sent' => ReportText.sent,
      'saved' => ReportText.saved,
      _ => c.report ? ReportText.sending : null,
    };
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        side: BorderSide(color: color.withValues(alpha: 0.7), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(good ? Icons.check_circle : Icons.support_agent, color: color, size: 52),
                  const SizedBox(width: 16),
                  Text(
                    heading,
                    style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: color),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(c.headline, style: const TextStyle(fontSize: 24, height: 1.3, fontWeight: FontWeight.w600)),
              if (c.meanwhile.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(QuiccRadius.md),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.lightbulb_outline, color: color),
                      const SizedBox(width: 12),
                      Expanded(child: Text(c.meanwhile, style: const TextStyle(fontSize: 19, height: 1.35))),
                    ],
                  ),
                ),
              ],
              if (c.note != null) ...[
                const SizedBox(height: 12),
                Text(c.note!, style: TextStyle(fontSize: 16, color: palette.textMuted)),
              ],
              if (session.guide == GuideId.printer) ...[
                const SizedBox(height: 12),
                const Row(
                  children: [
                    LabelWithInfo(label: Text('What REROUTED means'), info: GuideText.rerouted),
                    SizedBox(width: 24),
                    LabelWithInfo(label: Text('How to reprint'), info: GuideText.reprint),
                  ],
                ),
              ],
              if (sent != null) ...[
                const SizedBox(height: 18),
                Row(
                  children: [
                    Icon(
                      session.sent == 'sent' ? Icons.mark_email_read_outlined : Icons.schedule_send_outlined,
                      color: palette.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(sent, style: TextStyle(fontSize: 17, color: palette.textMuted)),
                  ],
                ),
              ],
              const SizedBox(height: 26),
              _BigButton(GuideText.close, onTap: onClose),
            ],
          ),
        ),
      ),
    );
  }
}
