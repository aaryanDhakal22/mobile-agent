import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';

/// Probes an agent address (`GET /api/session`) — overridden in tests.
final agentProbeProvider = Provider<Future<AgentProbe> Function(String address)>(
  (_) =>
      (address) => AgentClient.probe(address: address),
);

/// How often a link waiting for the Pi's internet is retried.
const Duration kLinkRetryEvery = Duration(seconds: 15);

/// First launch, after a revoke, or after an SD-card swap. Two ways in:
///
/// * a **new Pi** (the agent says `unconfigured`): sign in with the store
///   manager login — the Pi links to the restaurant, restores the open batch
///   and pairs this tablet in one go;
/// * an already set-up Pi: the 6-digit code from the agent web UI
///   (Settings → Pair tablet).
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  late final TextEditingController _addr;
  late final TextEditingController _code;
  late final TextEditingController _name;
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  /// The Pi at the typed address is new → manager-login mode.
  bool _newPi = false;

  /// Staff chose "I have a pairing code" on a new Pi.
  bool _forceCode = false;
  Timer? _probeDebounce;
  int _probeSeq = 0;

  /// The Pi has no internet yet: retrying the link automatically.
  Timer? _retry;
  int _retryIn = 0;

  bool get _loginMode => _newPi && !_forceCode;

  @override
  void initState() {
    super.initState();
    final storage = ref.read(storageProvider);
    _addr = TextEditingController(text: storage.lastAddress.replaceFirst(RegExp(r'^http://'), ''));
    _code = TextEditingController();
    _name = TextEditingController(text: storage.lastDeviceName.isEmpty ? 'Counter tablet' : storage.lastDeviceName);
    _error = ref.read(pairingProvider.notifier).lastUnpairReason;
    if (_addr.text.trim().isNotEmpty) scheduleMicrotask(_probe);
  }

  @override
  void dispose() {
    _probeDebounce?.cancel();
    _retry?.cancel();
    _addr.dispose();
    _code.dispose();
    _name.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _onAddressChanged(String _) {
    _probeDebounce?.cancel();
    _probeDebounce = Timer(const Duration(milliseconds: 700), _probe);
  }

  Future<void> _probe() async {
    final address = _addr.text.trim();
    if (address.isEmpty) return;
    final seq = ++_probeSeq;
    try {
      final p = await ref.read(agentProbeProvider)(address);
      if (!mounted || seq != _probeSeq) return;
      setState(() {
        _newPi = p.isNew;
        if (_newPi) _error = null; // "unpaired by the agent" is expected after a swap
      });
    } catch (_) {
      if (mounted && seq == _probeSeq) setState(() => _newPi = false);
    }
  }

  Future<void> _pair() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(pairingProvider.notifier).pair(address: _addr.text, code: _code.text, name: _name.text);
    } on AgentException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = switch (e.code) {
          'invalid_code' => 'Wrong or expired code. Show a new code in the agent web UI and try again.',
          'name_required' => 'Give this tablet a name (1–40 characters).',
          _ => e.isNetwork ? "Can't reach the agent at that address. Check the IP and port." : e.message,
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _link() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    _stopRetry();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(pairingProvider.notifier)
          .link(address: _addr.text, username: _user.text, password: _pass.text, name: _name.text);
    } on AgentException catch (e) {
      if (!mounted) return;
      if (e.code == 'needs_internet') {
        _startRetry();
        setState(() => _error = "The Pi can't reach the internet yet. Check its network cable and the router.");
        return;
      }
      setState(
        () => _error = switch (e.code) {
          'invalid_credentials' => 'Wrong username or password. Use the store manager login.',
          'too_many_attempts' => 'Too many tries — wait a few minutes, then try again.',
          'already_provisioned' => 'This Pi is already set up. Pair with a code from its web UI instead.',
          'link_in_progress' => 'Already setting up — wait a moment.',
          _ => e.isNetwork ? "Can't reach the Pi at that address. Check the IP and that it's powered on." : e.message,
        },
      );
      if (e.code == 'already_provisioned') _newPi = false;
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
    final login = _loginMode;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: QuiccColors.brand400,
                              borderRadius: BorderRadius.circular(QuiccRadius.md),
                            ),
                            child: const Text(
                              'q',
                              style: TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w700,
                                color: QuiccColors.brand900,
                                height: 1,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              login ? 'This Pi is new' : 'Pair this tablet',
                              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        login
                            ? "Sign in with the store manager login to set it up. Today's orders, drivers and settings come back automatically."
                            : 'On the agent web UI open Settings → Pair tablet to get a 6-digit code (valid 5 minutes).',
                        style: TextStyle(color: context.palette.textSecondary),
                      ),
                      const SizedBox(height: 24),
                      const Eyebrow('Agent address'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _addr,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        onChanged: _onAddressChanged,
                        decoration: const InputDecoration(hintText: '192.168.1.219:8080'),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the agent host:port' : null,
                      ),
                      const SizedBox(height: 16),
                      if (login) ...[
                        const Eyebrow('Manager username'),
                        const SizedBox(height: 6),
                        TextFormField(
                          key: const ValueKey('link-user'),
                          controller: _user,
                          autocorrect: false,
                          enableSuggestions: false,
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the username' : null,
                        ),
                        const SizedBox(height: 16),
                        const Eyebrow('Password'),
                        const SizedBox(height: 6),
                        TextFormField(
                          key: const ValueKey('link-pass'),
                          controller: _pass,
                          obscureText: true,
                          validator: (v) => (v == null || v.isEmpty) ? 'Enter the password' : null,
                        ),
                      ] else ...[
                        const Eyebrow('Pairing code'),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: _code,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          style: const TextStyle(fontSize: 28, letterSpacing: 10, fontWeight: FontWeight.w700),
                          decoration: const InputDecoration(hintText: '000000', counterText: ''),
                          validator: (v) => (v == null || v.trim().length != 6) ? 'The code has 6 digits' : null,
                        ),
                      ],
                      const SizedBox(height: 16),
                      const Eyebrow('Tablet name'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _name,
                        maxLength: 40,
                        decoration: const InputDecoration(hintText: 'Counter tablet', counterText: ''),
                        validator: (v) {
                          final n = v?.trim() ?? '';
                          return (n.isEmpty || n.length > 40) ? '1–40 characters' : null;
                        },
                        onFieldSubmitted: (_) => login ? _link() : _pair(),
                      ),
                      if (_error != null) ...[const SizedBox(height: 16), InlineError(_error!)],
                      if (_retry != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              'Trying again in $_retryIn s…',
                              style: TextStyle(color: context.palette.textSecondary),
                            ),
                            const Spacer(),
                            TextButton(onPressed: () => setState(_stopRetry), child: const Text('STOP')),
                          ],
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 60,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : (login ? _link : _pair),
                          icon: _busy
                              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3))
                              : Icon(login ? Icons.login : Icons.link),
                          label: Text(login ? (_busy ? 'SETTING UP…' : 'SET UP PI') : 'PAIR'),
                        ),
                      ),
                      if (_newPi) ...[
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _forceCode = !_forceCode;
                                  _error = null;
                                  _stopRetry();
                                }),
                          child: Text(_forceCode ? 'Set up with the manager login' : 'I have a pairing code instead'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
