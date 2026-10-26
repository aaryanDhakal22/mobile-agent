import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/diag_models.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/sse.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import '../settings/settings_card.dart';
import '../settings/settings_texts.dart';

// The Pi and this tablet (developer mode: Connections and Config). Moved out
// of Settings in 1.6.0.

/// Asks whatever answers at an address whether it is a Quicc Pi (`GET
/// /api/session`) — the address field's live check. Overridden in tests.
final piProbeProvider = Provider<Future<AgentProbe> Function(String address)>(
  (_) =>
      (address) => AgentClient.probe(address: address),
);

/// How long typing must pause before the address is checked.
const Duration kAddressCheckDelay = Duration(milliseconds: 700);

enum _Check { idle, checking, found, nothing }

class PiAddressCard extends ConsumerStatefulWidget {
  const PiAddressCard({super.key});

  @override
  ConsumerState<PiAddressCard> createState() => _PiAddressCardState();
}

class _PiAddressCardState extends ConsumerState<PiAddressCard> {
  late final TextEditingController _addrCtrl;
  Timer? _debounce;
  int _seq = 0;
  _Check _check = _Check.idle;
  AgentProbe? _found;

  @override
  void initState() {
    super.initState();
    _addrCtrl = TextEditingController(text: _shortAddress(ref.read(pairingProvider)?.address ?? ''));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _addrCtrl.dispose();
    super.dispose();
  }

  static String _shortAddress(String base) => base.replaceFirst(RegExp(r'^http://'), '');

  void _onChanged(String text) {
    _debounce?.cancel();
    final seq = ++_seq;
    if (normalizeAgentAddress(text).isEmpty) {
      setState(() => _check = _Check.idle);
      return;
    }
    setState(() => _check = _Check.checking);
    _debounce = Timer(kAddressCheckDelay, () async {
      try {
        final p = await ref.read(piProbeProvider)(text);
        if (mounted && seq == _seq) {
          setState(() {
            _check = _Check.found;
            _found = p;
          });
        }
      } catch (_) {
        if (mounted && seq == _seq) setState(() => _check = _Check.nothing);
      }
    });
  }

  Future<void> _save() async {
    final next = normalizeAgentAddress(_addrCtrl.text);
    if (next.isEmpty) return;
    await ref.read(pairingProvider.notifier).setAddress(next);
    if (!mounted) return;
    _addrCtrl.text = _shortAddress(next);
    toast(context, 'Pi address saved: ${_shortAddress(next)}');
  }

  @override
  Widget build(BuildContext context) {
    final fs = ref.watch(floorProvider);
    final unsynced = fs.floor?.unsyncedEvents ?? 0;
    return SettingsCard(
      title: 'The Pi',
      info: kPiAddressInfo,
      subtitle: 'Its address on the store Wi-Fi. The tablet stays paired when you change it.',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _addrCtrl,
                keyboardType: TextInputType.url,
                style: QuiccType.text(QuiccType.heading),
                decoration: const InputDecoration(hintText: '192.168.1.219', prefixIcon: Icon(Icons.router_outlined)),
                onChanged: _onChanged,
                onSubmitted: (_) => _save(),
              ),
            ),
            QuiccSpace.gapMd,
            SizedBox(
              height: 56,
              child: FilledButton(onPressed: _save, child: const Text('SAVE')),
            ),
          ],
        ),
        QuiccSpace.gapSm,
        _AddressCheck(check: _check, found: _found),
        QuiccSpace.gapMd,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Wrap(
                spacing: 32,
                runSpacing: 8,
                children: [
                  _Info('Connection', switch (fs.connection) {
                    SseStatus.connected => 'Live',
                    SseStatus.connecting => 'Connecting…',
                    SseStatus.disconnected => 'Can\'t reach the Pi — retrying',
                  }, warn: fs.connection == SseStatus.disconnected),
                  _Info('Last sync', fs.lastSyncAt == null ? '—' : clock(fs.lastSyncAt)),
                  _Info('Sync backlog', '$unsynced change${unsynced == 1 ? '' : 's'}', warn: unsynced > 0),
                ],
              ),
            ),
            const InfoButton(kConnectionInfo),
          ],
        ),
        if (unsynced > 0) ...[
          QuiccSpace.gapSm,
          Text(
            'The Pi has changes it has not yet sent to the Quicc website. It keeps trying by itself.',
            style: QuiccType.text(QuiccType.caption, color: context.palette.textMuted),
          ),
        ],
      ],
    );
  }
}

/// "Found the Pi ✓ — Lombardi's" / "Nothing there ✗" under the address.
class _AddressCheck extends StatelessWidget {
  final _Check check;
  final AgentProbe? found;
  const _AddressCheck({required this.check, required this.found});

  @override
  Widget build(BuildContext context) {
    final (Widget? lead, String text, Color? color) = switch (check) {
      _Check.idle => (null, '', null),
      _Check.checking => (
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        'Looking for the Pi…',
        context.palette.textMuted,
      ),
      _Check.found => (
        const Icon(Icons.check_circle, color: QuiccColors.statusPaid, size: 20),
        found?.isNew == true
            ? 'Found the Pi ✓ — not set up yet'
            : (found?.storeName.isNotEmpty ?? false)
            ? 'Found the Pi ✓ — ${found!.storeName}'
            : 'Found the Pi ✓',
        QuiccColors.statusPaid,
      ),
      _Check.nothing => (
        const Icon(Icons.cancel, color: QuiccColors.statusVoided, size: 20),
        'Nothing there ✗ — check the numbers, and that the Pi is on',
        QuiccColors.statusVoided,
      ),
    };
    if (lead == null) return const SizedBox(height: 22);
    return SizedBox(
      height: 22,
      child: Row(
        children: [
          lead,
          QuiccSpace.gapSm,
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// This tablet: rename, pair another, unpair
// =============================================================================

class TabletCard extends ConsumerWidget {
  const TabletCard({super.key});

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final current = ref.read(pairingProvider)?.deviceName ?? '';
    final name = await textDialog(
      context,
      title: 'Rename this tablet',
      initial: current,
      hint: 'For example "Counter tablet"',
      confirm: 'RENAME',
    );
    if (name == null || name.isEmpty || name == current || !context.mounted) return;
    final client = ref.read(agentClientProvider);
    if (client == null) return;
    try {
      final saved = await client.renameSelf(name);
      await ref.read(pairingProvider.notifier).rename(saved.isEmpty ? name : saved);
      if (context.mounted) toast(context, 'Renamed to ${saved.isEmpty ? name : saved}');
    } catch (e) {
      if (context.mounted) toastError(context, e, lead: 'Not renamed', area: 'settings');
    }
  }

  Future<void> _unpair(BuildContext context, WidgetRef ref) async {
    final ok = await confirmDialog(
      context,
      title: 'Unpair this tablet?',
      message:
          'It stops ringing for orders and goes back to the setup screen. To connect it again you '
          'need a code from another tablet or the manager login.',
      confirm: 'UNPAIR',
      destructive: true,
    );
    if (!ok) return;
    try {
      // Best effort: revoke the key on the agent so it stops working.
      await ref.read(agentClientProvider)?.unpairSelf();
    } catch (_) {
      // Agent unreachable — the key is still forgotten locally.
    }
    await ref.read(pairingProvider.notifier).unpair();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairing = ref.watch(pairingProvider);
    final name = pairing?.deviceName.isNotEmpty == true ? pairing!.deviceName : 'Paired tablet';
    return SettingsCard(
      title: 'This tablet',
      info: kTabletNameInfo,
      subtitle: 'The name the Pi knows it by. Pair a second tablet from here, or unpair this one.',
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700)),
                  if (pairing?.deviceId.isNotEmpty == true)
                    Text(
                      'device ${pairing!.deviceId}',
                      style: QuiccType.text(QuiccType.caption, color: context.palette.textMuted),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                onPressed: () => _rename(context, ref),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('RENAME'),
              ),
            ),
          ],
        ),
        QuiccSpace.gapLg,
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: () =>
                        showDialog<void>(context: context, builder: (_) => const PairAnotherTabletDialog()),
                    icon: const Icon(Icons.tablet_android),
                    label: const Text('PAIR ANOTHER TABLET'),
                  ),
                ),
                const InfoButton(kPairAnotherInfo),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 56,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: QuiccColors.statusVoided),
                    onPressed: () => _unpair(context, ref),
                    icon: const Icon(Icons.link_off),
                    label: const Text('UNPAIR'),
                  ),
                ),
                const InfoButton(kUnpairInfo),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// Mints a 6-digit pairing code on the Pi and shows it big, with a countdown
/// and the steps for the other tablet.
class PairAnotherTabletDialog extends ConsumerStatefulWidget {
  const PairAnotherTabletDialog({super.key});

  @override
  ConsumerState<PairAnotherTabletDialog> createState() => _PairAnotherTabletDialogState();
}

class _PairAnotherTabletDialogState extends ConsumerState<PairAnotherTabletDialog> {
  Future<PairingCode>? _code;

  @override
  void initState() {
    super.initState();
    _code = _mint();
  }

  Future<PairingCode> _mint() {
    final client = ref.read(agentClientProvider);
    return client == null ? Future.error(const AgentException('This tablet is not paired')) : client.pairingCode();
  }

  void _newCode() => setState(() => _code = _mint());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pair another tablet'),
      content: SizedBox(
        width: 560,
        child: FutureBuilder<PairingCode>(
          future: _code,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
            }
            if (snap.hasError) {
              return InlineError.from(snap.error!, lead: 'No code', area: 'settings', onRetry: _newCode);
            }
            final code = snap.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Ticker(
                  builder: (context, now) {
                    final left = code.expiresAt?.difference(now);
                    final expired = left != null && left.isNegative;
                    return Column(
                      children: [
                        Text(
                          code.code,
                          textAlign: TextAlign.center,
                          // The one oversized number: read across the counter.
                          style: QuiccType.number(
                            QuiccType.display * 2,
                            weight: FontWeight.w800,
                            color: expired ? context.palette.textMuted : QuiccColors.brand400,
                          ).copyWith(letterSpacing: 12, decoration: expired ? TextDecoration.lineThrough : null),
                        ),
                        Text(
                          left == null
                              ? 'Valid for a few minutes'
                              : expired
                              ? 'This code has expired — get a new one'
                              : 'Expires in ${duration(left)}',
                          style: QuiccType.text(
                            QuiccType.body,
                            weight: FontWeight.w600,
                            color: expired ? QuiccColors.statusVoided : context.palette.textSecondary,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                QuiccSpace.gapXl,
                const Eyebrow('On the new tablet'),
                QuiccSpace.gapSm,
                for (final (i, step) in const [
                  'Open Quibase',
                  'Pick this Pi',
                  'Tap "I have a code"',
                  'Type the 6 digits above',
                ].indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: QuiccSpace.xs),
                    child: Text('${i + 1}.  $step', style: QuiccType.text(QuiccType.heading)),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: _newCode, child: const Text('NEW CODE')),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('DONE')),
      ],
    );
  }
}

class _Info extends StatelessWidget {
  final String label;
  final String value;
  final bool warn;
  const _Info(this.label, this.value, {this.warn = false});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Eyebrow(label),
      QuiccSpace.gapXs,
      Text(
        value,
        style: QuiccType.text(QuiccType.body, weight: FontWeight.w600, color: warn ? QuiccColors.statusFiring : null),
      ),
    ],
  );
}
