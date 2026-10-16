import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../common/widgets.dart';

/// First launch (or after a revoke): agent address + the 6-digit code from
/// the agent web UI (Settings → Pair tablet) + a name for this tablet.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  late final TextEditingController _addr;
  late final TextEditingController _code;
  late final TextEditingController _name;
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final storage = ref.read(storageProvider);
    _addr = TextEditingController(text: storage.lastAddress.replaceFirst(RegExp(r'^http://'), ''));
    _code = TextEditingController();
    _name = TextEditingController(text: storage.lastDeviceName.isEmpty ? 'Counter tablet' : storage.lastDeviceName);
    _error = ref.read(pairingProvider.notifier).lastUnpairReason;
  }

  @override
  void dispose() {
    _addr.dispose();
    _code.dispose();
    _name.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
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
                          const Text('Pair this tablet', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'On the agent web UI open Settings → Pair tablet to get a 6-digit code (valid 5 minutes).',
                        style: TextStyle(color: context.palette.textSecondary),
                      ),
                      const SizedBox(height: 24),
                      const Eyebrow('Agent address'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _addr,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(hintText: '192.168.1.219:8080'),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the agent host:port' : null,
                      ),
                      const SizedBox(height: 16),
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
                        onFieldSubmitted: (_) => _pair(),
                      ),
                      if (_error != null) ...[const SizedBox(height: 16), InlineError(_error!)],
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 60,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _pair,
                          icon: _busy
                              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3))
                              : const Icon(Icons.link),
                          label: const Text('PAIR'),
                        ),
                      ),
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
