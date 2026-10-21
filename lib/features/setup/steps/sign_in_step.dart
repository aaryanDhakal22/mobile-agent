import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../../../core/friendly_error.dart';
import '../../../core/local_log.dart';
import '../../../core/providers.dart';
import '../../../theme/quicc_colors.dart';
import '../../common/info_button.dart';
import '../setup_controller.dart';
import '../setup_flow.dart';
import '../setup_texts.dart';
import '../setup_widgets.dart';

/// How often a link waiting for the Pi's internet is retried.
const Duration kLinkRetryEvery = Duration(seconds: 15);

/// "Sign in": a **new Pi** is set up with the store manager login (the Pi
/// links to the restaurant, restores the open batch and pairs this tablet in
/// one go); an already set-up Pi is joined with a 6-digit code from another
/// tablet (Settings → Pair another tablet) or the Pi's web page.
class SignInStep extends ConsumerStatefulWidget {
  const SignInStep({super.key});

  @override
  ConsumerState<SignInStep> createState() => _SignInStepState();
}

class _SignInStepState extends ConsumerState<SignInStep> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _code = TextEditingController();
  late final TextEditingController _name;
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;
  FriendlyError? _error;
  bool _forceCode = false;

  /// The Pi has no internet yet: retrying the link automatically.
  Timer? _retry;
  int _retryIn = 0;

  @override
  void initState() {
    super.initState();
    final last = ref.read(storageProvider).lastDeviceName;
    _name = TextEditingController(text: last.isEmpty ? 'Counter tablet' : last);
  }

  @override
  void dispose() {
    _retry?.cancel();
    _user.dispose();
    _pass.dispose();
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  SetupProgress get _p => ref.read(setupProvider)!;
  bool get _loginMode => (ref.read(setupProvider)?.piIsNew ?? false) && !_forceCode;

  Future<void> _link() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    _stopRetry();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(pairingProvider.notifier)
          .link(address: _p.piAddress, username: _user.text, password: _pass.text, name: _name.text);
      ref.read(setupProvider.notifier).paired(link: LinkSummary.fromLink(r, store: _p.piStore));
    } on AgentException catch (e) {
      if (!mounted) return;
      ref.read(localLogProvider).warn('setup', 'link: ${FriendlyError.from(e).details}');
      if (e.code == 'needs_internet') _startRetry();
      if (e.code == 'already_provisioned') {
        // Someone set it up meanwhile: join it with a code instead.
        ref.read(setupProvider.notifier).update((p) => p.copyWith(piIsNew: false));
      }
      setState(() => _error = FriendlyError.from(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pair() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(pairingProvider.notifier).pair(address: _p.piAddress, code: _code.text, name: _name.text);
      ref.read(setupProvider.notifier).paired(store: _p.piStore);
    } on AgentException catch (e) {
      if (!mounted) return;
      ref.read(localLogProvider).warn('setup', 'pair: ${FriendlyError.from(e).details}');
      setState(() => _error = FriendlyError.from(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startRetry() {
    _retry?.cancel();
    _retryIn = kLinkRetryEvery.inSeconds;
    _retry = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _retryIn--);
      if (_retryIn <= 0) {
        t.cancel();
        unawaited(_link());
      }
    });
  }

  void _stopRetry() {
    _retry?.cancel();
    _retry = null;
    _retryIn = 0;
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(setupProvider);
    final isNew = p?.piIsNew ?? false;
    final login = isNew && !_forceCode;
    final where = (p?.piStore ?? '').isNotEmpty ? p!.piStore : 'this Pi';

    final fields = <Widget>[
      if (login) ...[
        _label('Manager username', SetupInfo.managerLogin),
        TextFormField(
          key: const ValueKey('link-user'),
          controller: _user,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          style: const TextStyle(fontSize: 20),
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Type the username' : null,
        ),
        const SizedBox(height: 14),
        _label('Password', null),
        TextFormField(
          key: const ValueKey('link-pass'),
          controller: _pass,
          obscureText: true,
          textInputAction: TextInputAction.done,
          style: const TextStyle(fontSize: 20),
          validator: (v) => (v == null || v.isEmpty) ? 'Type the password' : null,
          onFieldSubmitted: (_) => _link(),
        ),
      ] else ...[
        _label('Pairing code', SetupInfo.pairingCode),
        TextFormField(
          key: const ValueKey('pair-code'),
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 32, letterSpacing: 12, fontWeight: FontWeight.w700),
          decoration: const InputDecoration(hintText: '000000', counterText: ''),
          validator: (v) => (v == null || v.trim().length != 6) ? 'The code has 6 digits' : null,
        ),
        Text(
          'Get a code on a tablet that already works: Settings → Pair another tablet.',
          style: TextStyle(fontSize: 15, color: context.palette.textSecondary),
        ),
      ],
      const SizedBox(height: 14),
      _label('Name for this tablet', SetupInfo.tabletName),
      TextFormField(
        key: const ValueKey('tablet-name'),
        controller: _name,
        maxLength: 40,
        style: const TextStyle(fontSize: 20),
        decoration: const InputDecoration(hintText: 'Counter tablet', counterText: ''),
        validator: (v) {
          final n = v?.trim() ?? '';
          return (n.isEmpty || n.length > 40) ? '1–40 characters' : null;
        },
      ),
      if (_error != null) ...[const SizedBox(height: 14), _ErrorCard(error: _error!)],
      if (_retry != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Text(
                'Trying again in $_retryIn s…',
                style: TextStyle(fontSize: 16, color: context.palette.textSecondary),
              ),
              const Spacer(),
              TextButton(onPressed: () => setState(_stopRetry), child: const Text('STOP')),
            ],
          ),
        ),
      if (isNew)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _forceCode = !_forceCode;
                    _error = null;
                    _stopRetry();
                  }),
            child: Text(
              _forceCode ? 'Set up with the manager login' : 'I have a pairing code instead',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
    ];

    return StepLayout(
      title: login ? 'This Pi is new' : 'Join $where',
      subtitle: login
          ? "Sign in with the store manager login. Today's orders, drivers and settings come back by themselves."
          : 'Type the 6-digit code from another tablet.',
      info: login ? SetupInfo.managerLogin : SetupInfo.pairingCode,
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: fields),
            ),
          ],
        ),
      ),
      primary: BigButton(
        login ? (_busy ? 'SETTING UP…' : 'SET UP PI') : 'JOIN',
        icon: login ? Icons.login : Icons.link,
        busy: _busy,
        onPressed: () => _loginMode ? _link() : _pair(),
      ),
    );
  }

  Widget _label(String text, InfoText? info) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: info == null
        ? Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))
        : LabelWithInfo(
            label: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            info: info,
          ),
  );
}

/// A friendly error with its technical details one tap away.
class _ErrorCard extends StatefulWidget {
  final FriendlyError error;
  const _ErrorCard({required this.error});

  @override
  State<_ErrorCard> createState() => _ErrorCardState();
}

class _ErrorCardState extends State<_ErrorCard> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.error;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: QuiccColors.statusVoided.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(QuiccRadius.md),
        border: Border.all(color: QuiccColors.statusVoided.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, color: QuiccColors.statusVoided),
              const SizedBox(width: 10),
              Expanded(
                child: Text(e.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              if (e.details.isNotEmpty)
                TextButton(onPressed: () => setState(() => _details = !_details), child: const Text('Details')),
            ],
          ),
          if (e.whatToDo.isNotEmpty) Text(e.whatToDo, style: const TextStyle(fontSize: 16)),
          if (_details) Text(e.details, style: TextStyle(fontSize: 13, color: context.palette.textMuted)),
        ],
      ),
    );
  }
}
