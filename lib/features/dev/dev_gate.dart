import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import 'dev_log.dart';

/// Developer mode relocks after this long without a touch.
const Duration kDevIdleLimit = Duration(minutes: 15);

/// Developer mode's lock (1.6.0): unlocked by the store manager login, in
/// memory only. It relocks when staff leave developer mode, after
/// [kDevIdleLimit] without any touch on the screen, on a restart, or when the
/// tablet's Pi changes.
class DevGate extends Notifier<bool> {
  Timer? _idle;

  @override
  bool build() {
    ref.watch(pairingProvider.select((p) => p?.address));
    ref.onDispose(() => _idle?.cancel());
    _idle?.cancel();
    return false;
  }

  bool get unlocked => state;

  void unlock() {
    state = true;
    _arm();
    ref.read(devLogProvider.notifier).add(DevLogKind.app, 'Developer mode unlocked');
  }

  void lock({String why = 'left'}) {
    _idle?.cancel();
    _idle = null;
    if (!state) return;
    state = false;
    ref.read(devLogProvider.notifier).add(DevLogKind.app, 'Developer mode locked ($why)');
  }

  /// Any pointer activity: restart the idle clock.
  void touch() {
    if (state) _arm();
  }

  void _arm() {
    _idle?.cancel();
    _idle = Timer(kDevIdleLimit, () => lock(why: '15 min idle'));
  }
}

final devGateProvider = NotifierProvider<DevGate, bool>(DevGate.new);

/// A manager login the Pi refused (or couldn't check), in plain words.
class DevLoginException implements Exception {
  final String message;
  const DevLoginException(this.message);
  @override
  String toString() => message;
}

typedef ManagerLoginCheck =
    Future<void> Function({required String address, required String username, required String password});

/// Checks the store manager login with the Pi — overridden in tests.
final managerLoginProvider = Provider<ManagerLoginCheck>((_) => verifyManagerLogin);

/// `POST /api/login {username, password}` on the Pi (the same login its web
/// UI takes). 200 = right; the session it hands out is signed out again at
/// once, since developer mode keeps its own lock. Throws [DevLoginException].
Future<void> verifyManagerLogin({
  required String address,
  required String username,
  required String password,
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final c = client ?? http.Client();
  final base = normalizeAgentAddress(address);
  try {
    final http.Response resp;
    try {
      resp = await c
          .post(
            Uri.parse('$base/api/login'),
            headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({'username': username.trim(), 'password': password}),
          )
          .timeout(timeout);
    } catch (_) {
      throw const DevLoginException("Can't reach the Pi — check the tablet is on the store Wi-Fi.");
    }
    switch (resp.statusCode) {
      case 200:
        final cookie = resp.headers['set-cookie']?.split(';').first;
        if (cookie != null && cookie.isNotEmpty) {
          try {
            await c
                .post(Uri.parse('$base/api/logout'), headers: {'Cookie': cookie})
                .timeout(const Duration(seconds: 3));
          } catch (_) {
            // Only tidiness: the session expires on its own.
          }
        }
        return;
      case 401:
        throw const DevLoginException('Wrong username or password.');
      case 429:
        throw const DevLoginException('Too many wrong tries — wait a minute and try again.');
      case 409:
        throw const DevLoginException("The Pi isn't set up yet, so it has no manager login.");
      default:
        throw DevLoginException('The Pi could not check the login (HTTP ${resp.statusCode}).');
    }
  } finally {
    if (client == null) c.close();
  }
}

/// Asks for the store manager login and unlocks developer mode when the Pi
/// accepts it. Returns true when unlocked.
Future<bool> showDevLoginSheet(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const DevLoginSheet(),
  );
  return ok == true;
}

class DevLoginSheet extends ConsumerStatefulWidget {
  const DevLoginSheet({super.key});

  @override
  ConsumerState<DevLoginSheet> createState() => _DevLoginSheetState();
}

class _DevLoginSheetState extends ConsumerState<DevLoginSheet> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final address = ref.read(pairingProvider)?.address;
    if (address == null) {
      setState(() => _error = 'This tablet is not paired with a Pi.');
      return;
    }
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Type the manager username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(managerLoginProvider)(address: address, username: _user.text, password: _pass.text);
      if (!mounted) return;
      ref.read(devGateProvider.notifier).unlock();
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ref.read(devLogProvider.notifier).add(DevLogKind.app, 'Developer login refused: $e');
      setState(() {
        _busy = false;
        _error = e is DevLoginException ? e.message : 'Could not check the login.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(QuiccSpace.pane, 0, QuiccSpace.pane, QuiccSpace.pane),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Developer mode', style: QuiccType.text(QuiccType.title, weight: FontWeight.w700)),
                QuiccSpace.gapXs,
                Text(
                  'Connections, logs, tests and the Pi settings. Sign in with the store manager login — '
                  'it locks again after 15 minutes without a touch.',
                  style: QuiccType.text(QuiccType.body, color: palette.textSecondary),
                ),
                QuiccSpace.gapLg,
                TextField(
                  key: const ValueKey('dev-username'),
                  controller: _user,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline)),
                ),
                QuiccSpace.gapMd,
                TextField(
                  key: const ValueKey('dev-password'),
                  controller: _pass,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
                  onSubmitted: (_) => _submit(),
                ),
                SizedBox(
                  height: QuiccSpace.xxl,
                  child: _error == null
                      ? null
                      : Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _error!,
                            style: QuiccType.text(
                              QuiccType.label,
                              weight: FontWeight.w600,
                              color: QuiccColors.statusVoided,
                            ),
                          ),
                        ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    QuiccSpace.gapMd,
                    SizedBox(
                      height: 56,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.lock_open),
                        label: const Text('UNLOCK'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps the app: any touch while developer mode is unlocked restarts its
/// idle clock.
class DevActivityListener extends ConsumerWidget {
  final Widget child;
  const DevActivityListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => ref.read(devGateProvider.notifier).touch(),
    onPointerSignal: (_) => ref.read(devGateProvider.notifier).touch(),
    child: child,
  );
}
