import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../home/idle_kitchen.dart';
import 'dev_log.dart';

/// Developer mode relocks after this long without a touch.
const Duration kDevIdleLimit = Duration(minutes: 15);

/// Developer mode's lock (1.6.0): unlocked by the developer PIN (1.8.1; was
/// the store manager login), in
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

/// The developer-mode PIN (1.8.1). Not a secret — a deterrent so staff
/// don't wander into the developer screens by accident.
const String kDevPin = '1024';

/// Asks for the developer PIN and unlocks developer mode when it is right.
/// Returns true when unlocked.
Future<bool> showDevPinSheet(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const DevPinSheet(),
  );
  return ok == true;
}

/// A 4-digit PIN pad: big digit buttons, four dots, checked on the 4th
/// digit. Right → unlocked; wrong → a shake and the dots clear (no lockout).
class DevPinSheet extends ConsumerStatefulWidget {
  const DevPinSheet({super.key});

  @override
  ConsumerState<DevPinSheet> createState() => _DevPinSheetState();
}

class _DevPinSheetState extends ConsumerState<DevPinSheet> with SingleTickerProviderStateMixin {
  String _pin = '';
  bool _wrong = false;
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  void _digit(int d) {
    if (_pin.length >= kDevPin.length) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += '$d';
      _wrong = false;
    });
    if (_pin.length == kDevPin.length) _check();
  }

  void _back() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _check() {
    if (_pin == kDevPin) {
      ref.read(devGateProvider.notifier).unlock();
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(true);
      return;
    }
    ref.read(devLogProvider.notifier).add(DevLogKind.app, 'Developer PIN wrong');
    HapticFeedback.heavyImpact();
    setState(() {
      _pin = '';
      _wrong = true;
    });
    unawaited(_shake.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(QuiccSpace.pane, 0, QuiccSpace.pane, QuiccSpace.pane),
          child: Column(
            key: const ValueKey('dev-pin-pad'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Developer mode', style: QuiccType.text(QuiccType.title, weight: FontWeight.w700)),
              QuiccSpace.gapXs,
              Text(
                'Connections, logs, tests and the Pi settings. Type the developer PIN — '
                'it locks again after 15 minutes without a touch.',
                textAlign: TextAlign.center,
                style: QuiccType.text(QuiccType.body, color: palette.textSecondary),
              ),
              QuiccSpace.gapLg,
              AnimatedBuilder(
                animation: _shake,
                builder: (context, child) {
                  // Three damped swings left-right.
                  final t = _shake.value;
                  final dx = t == 0 || t == 1 ? 0.0 : math.sin(t * math.pi * 6) * 14 * (1 - t);
                  return Transform.translate(offset: Offset(dx, 0), child: child);
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < kDevPin.length; i++)
                      Container(
                        key: ValueKey('dev-pin-dot-$i'),
                        margin: const EdgeInsets.symmetric(horizontal: QuiccSpace.sm),
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < _pin.length ? palette.textPrimary : Colors.transparent,
                          border: Border.all(
                            color: _wrong ? QuiccColors.statusVoided : palette.textSecondary,
                            width: 2,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                height: QuiccSpace.xxl,
                child: _wrong
                    ? Center(
                        child: Text(
                          'Wrong PIN — try again.',
                          key: const ValueKey('dev-pin-wrong'),
                          style: QuiccType.text(
                            QuiccType.label,
                            weight: FontWeight.w600,
                            color: QuiccColors.statusVoided,
                          ),
                        ),
                      )
                    : null,
              ),
              for (final row in const [
                [1, 2, 3],
                [4, 5, 6],
                [7, 8, 9],
              ])
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [for (final d in row) _key(ValueKey('dev-pin-digit-$d'), Text('$d'), () => _digit(d))],
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _key(
                    const ValueKey('dev-pin-cancel'),
                    const Icon(Icons.close),
                    () => Navigator.of(context).pop(false),
                    quiet: true,
                  ),
                  _key(const ValueKey('dev-pin-digit-0'), const Text('0'), () => _digit(0)),
                  _key(const ValueKey('dev-pin-back'), const Icon(Icons.backspace_outlined), _back, quiet: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _key(Key key, Widget label, VoidCallback onTap, {bool quiet = false}) => Padding(
    padding: const EdgeInsets.all(QuiccSpace.xs),
    child: SizedBox(
      width: 96,
      height: 72,
      child: quiet
          ? TextButton(key: key, onPressed: onTap, child: label)
          : FilledButton.tonal(
              key: key,
              onPressed: onTap,
              style: FilledButton.styleFrom(textStyle: QuiccType.number(QuiccType.title, weight: FontWeight.w700)),
              child: label,
            ),
    ),
  );
}

/// Wraps the app: any touch while developer mode is unlocked restarts its
/// idle clock.
class DevActivityListener extends ConsumerWidget {
  final Widget child;
  const DevActivityListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _touch(ref),
    onPointerSignal: (_) => _touch(ref),
    child: child,
  );

  /// Developer mode's 15 min, and (1.7.1) the 1 min back to Kitchen.
  static void _touch(WidgetRef ref) {
    ref.read(devGateProvider.notifier).touch();
    ref.read(idleTouchProvider.notifier).state++;
  }
}
