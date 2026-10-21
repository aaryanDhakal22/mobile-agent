import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../../../core/device_platform.dart';
import '../../../core/discovery.dart';
import '../../../core/friendly_error.dart';
import '../../../core/providers.dart';
import '../../../theme/quicc_colors.dart';
import '../../common/info_button.dart';
import '../setup_controller.dart';
import '../setup_texts.dart';
import '../setup_widgets.dart';

/// "Find the Pi": lists the Pis on the store network (discovery) as big
/// cards; tap one. "My Pi isn't listed" opens a typed-address box that checks
/// as you type (a bare IP is enough — :8080 is added).
class FindPiStep extends ConsumerStatefulWidget {
  const FindPiStep({super.key});

  @override
  ConsumerState<FindPiStep> createState() => _FindPiStepState();
}

class _FindPiStepState extends ConsumerState<FindPiStep> {
  StreamSubscription<List<DiscoveredPi>>? _sub;
  List<DiscoveredPi> _found = const [];
  bool _searching = false;
  bool _typing = false;
  bool _choosing = false;
  String? _error;

  final _addr = TextEditingController();
  Timer? _debounce;
  int _probeSeq = 0;

  /// Result of checking the typed address: null = not checked yet.
  DiscoveredPi? _typedPi;
  String? _typedMessage;
  bool _typedChecking = false;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(setupProvider)?.piAddress ?? '';
    final last = saved.isNotEmpty ? saved : ref.read(storageProvider).lastAddress;
    _addr.text = last.replaceFirst(RegExp(r'^http://'), '').replaceFirst(RegExp(r':8080$'), '');
    _error = ref.read(pairingProvider.notifier).lastUnpairReason;
    scheduleMicrotask(_search);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    _addr.dispose();
    super.dispose();
  }

  void _search() {
    _sub?.cancel();
    setState(() {
      _searching = true;
      _found = const [];
    });
    final saved = ref.read(storageProvider).lastAddress;
    _sub = ref
        .read(piDiscoveryProvider)
        .discover(savedAddress: saved)
        .listen(
          (list) {
            if (mounted) setState(() => _found = list);
          },
          onDone: () {
            if (mounted) setState(() => _searching = false);
          },
        );
  }

  void _onTyped(String _) {
    _debounce?.cancel();
    setState(() {
      _typedPi = null;
      _typedMessage = null;
    });
    _debounce = Timer(const Duration(milliseconds: 600), _checkTyped);
  }

  Future<void> _checkTyped() async {
    final address = _addr.text.trim();
    if (address.isEmpty) return;
    final seq = ++_probeSeq;
    setState(() => _typedChecking = true);
    try {
      final base = normalizeAgentAddress(address);
      final p = await ref.read(agentProbeProvider)(base);
      if (!mounted || seq != _probeSeq) return;
      setState(() {
        _typedPi = DiscoveredPi(address: base, via: 'typed').withProbe(p);
        _typedMessage = null;
      });
    } catch (e) {
      if (!mounted || seq != _probeSeq) return;
      setState(() {
        _typedPi = null;
        _typedMessage = e is AgentException && !e.isNetwork
            ? 'Something answered, but it isn\'t a Quicc Pi'
            : 'Nothing there — check the numbers';
      });
    } finally {
      if (mounted && seq == _probeSeq) setState(() => _typedChecking = false);
    }
  }

  Future<void> _choose(DiscoveredPi pi) async {
    setState(() {
      _choosing = true;
      _error = null;
    });
    try {
      // Re-read its state right now (it may have been set up meanwhile).
      final p = await ref.read(agentProbeProvider)(pi.address);
      if (!mounted) return;
      ref.read(setupProvider.notifier).choosePi(address: pi.address, isNew: p.isNew, store: p.storeName);
    } catch (e) {
      if (mounted) setState(() => _error = FriendlyError.from(e).short);
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      children: [
        if (_error != null) ...[_ErrorBox(_error!), const SizedBox(height: 12)],
        for (final pi in _found) _PiCard(pi: pi, onTap: _choosing ? null : () => _choose(pi)),
        if (_searching)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Row(
              children: [
                const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(width: 16),
                Text(
                  'Looking for the Pi on this Wi-Fi…',
                  style: TextStyle(fontSize: 18, color: context.palette.textSecondary),
                ),
              ],
            ),
          ),
        if (!_searching && _found.isEmpty)
          _NothingFound(onWifi: () => ref.read(devicePlatformProvider).openSettings(DeviceSetting.wifi)),
        const SizedBox(height: 8),
        if (!_typing)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _typing = true;
                if (_addr.text.isNotEmpty) unawaited(_checkTyped());
              }),
              icon: const Icon(Icons.keyboard),
              label: const Text("My Pi isn't listed — type its address", style: TextStyle(fontSize: 17)),
            ),
          )
        else
          _typedBox(context),
      ],
    );
    return StepLayout(
      title: 'Find the Pi',
      subtitle: 'Make sure this tablet is on the store Wi-Fi. Tap your Pi below.',
      info: SetupInfo.findPi,
      body: body,
      secondary: OutlinedButton.icon(
        onPressed: _searching ? null : _search,
        icon: const Icon(Icons.refresh),
        label: const Text('SEARCH AGAIN'),
      ),
    );
  }

  Widget _typedBox(BuildContext context) {
    final pi = _typedPi;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabelWithInfo(
              label: const Text("The Pi's address", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              info: SetupInfo.typedAddress,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _addr,
              keyboardType: TextInputType.url,
              autocorrect: false,
              style: const TextStyle(fontSize: 22),
              decoration: const InputDecoration(hintText: '192.168.0.40'),
              onChanged: _onTyped,
              onSubmitted: (_) => _checkTyped(),
            ),
            const SizedBox(height: 10),
            if (_typedChecking)
              const Text('Checking…', style: TextStyle(fontSize: 16))
            else if (pi != null)
              _PiCard(pi: pi, onTap: _choosing ? null : () => _choose(pi))
            else if (_typedMessage != null)
              Row(
                children: [
                  const Icon(Icons.cancel, color: QuiccColors.statusVoided),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_typedMessage!, style: const TextStyle(fontSize: 16))),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _PiCard extends StatelessWidget {
  final DiscoveredPi pi;
  final VoidCallback? onTap;
  const _PiCard({required this.pi, this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = pi.isNew ? 'New Pi — not set up yet' : (pi.storeName.isNotEmpty ? pi.storeName : 'Quicc Pi');
    final sub = pi.isNew ? 'Set it up with the store manager login' : 'Ready — join it with a pairing code';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(QuiccRadius.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            children: [
              Icon(pi.isNew ? Icons.fiber_new : Icons.router, size: 40, color: QuiccColors.brand400),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(sub, style: TextStyle(fontSize: 16, color: context.palette.textSecondary)),
                  ],
                ),
              ),
              Text(pi.ip, style: TextStyle(fontSize: 14, color: context.palette.textMuted)),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right, size: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _NothingFound extends StatelessWidget {
  final VoidCallback onWifi;
  const _NothingFound({required this.onWifi});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('No Pi found yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text(
            '• Is this tablet on the store Wi-Fi (not a guest Wi-Fi)?\n'
            '• Is the Pi plugged in, with its network cable in the router?\n'
            '• A new Pi takes about 10 minutes the first time it starts.',
            style: TextStyle(fontSize: 17, height: 1.5),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onWifi,
            icon: const Icon(Icons.wifi),
            label: const Text('OPEN WI-FI SETTINGS'),
          ),
        ],
      ),
    ),
  );
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox(this.message);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: QuiccColors.statusFiring.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(QuiccRadius.md),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline, color: QuiccColors.statusFiring),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 16))),
      ],
    ),
  );
}
