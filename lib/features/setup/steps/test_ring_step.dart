import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/alert_player.dart';
import '../../../core/device_platform.dart';
import '../../../core/local_log.dart';
import '../../../core/providers.dart';
import '../../../core/ring_bridge.dart';
import '../../../theme/quicc_colors.dart';
import '../setup_widgets.dart';

/// How long a test ring plays.
const Duration kTestRingFor = Duration(seconds: 8);

/// "Did you hear it?": plays the order chime on the alarm volume, then asks.
/// A second test waits for the screen to go off and rings the real way (sound
/// + the full-screen notification that wakes the tablet).
class TestRingPanel extends ConsumerStatefulWidget {
  final ValueChanged<bool>? onResult;
  const TestRingPanel({super.key, this.onResult});

  @override
  ConsumerState<TestRingPanel> createState() => _TestRingPanelState();
}

enum _Phase { idle, playing, ask, notHeard, screenOffCountdown, screenOffRinging, askScreenOff }

class _TestRingPanelState extends ConsumerState<TestRingPanel> {
  _Phase _phase = _Phase.idle;
  Timer? _timer;
  int _count = 0;
  bool? _heard;
  bool? _woke;

  @override
  void dispose() {
    _timer?.cancel();
    // A preview stop never silences a real order's alarm (AlertPlayer).
    unawaited(AlertPlayer.stop(preview: true));
    super.dispose();
  }

  /// A real order may be ringing: never silence it.
  bool get _realAlarm => ref.read(alarmProvider).ringing;

  Future<void> _stopTest() async {
    if (_realAlarm) return;
    await AlertPlayer.stop(preview: true);
  }

  Future<void> _play() async {
    if (_realAlarm) return _busyWithOrder();
    setState(() => _phase = _Phase.playing);
    await AlertPlayer.start(ref.read(alertSoundProvider), preview: true);
    _timer?.cancel();
    _timer = Timer(kTestRingFor, () async {
      await _stopTest();
      if (mounted) setState(() => _phase = _Phase.ask);
    });
  }

  void _answer(bool heard) {
    _timer?.cancel();
    unawaited(_stopTest());
    setState(() {
      _heard = heard;
      _phase = heard ? _Phase.idle : _Phase.notHeard;
    });
    if (!heard) ref.read(localLogProvider).warn('setup', 'test ring not heard');
    widget.onResult?.call(heard);
  }

  void _screenOffTest() {
    if (_realAlarm) return _busyWithOrder();
    setState(() {
      _phase = _Phase.screenOffCountdown;
      _count = 10;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) return t.cancel();
      setState(() => _count--);
      if (_count > 0) return;
      t.cancel();
      if (_realAlarm) return;
      setState(() => _phase = _Phase.screenOffRinging);
      final ring = ref.read(ringPlatformProvider);
      await AlertPlayer.start(ref.read(alertSoundProvider), preview: true);
      await ring.showRing(title: 'Test ring', text: 'This is only a test — tap to go back');
      _timer = Timer(const Duration(seconds: 15), () async {
        await _stopTest();
        await ring.cancelRing();
        if (mounted) setState(() => _phase = _Phase.askScreenOff);
      });
    });
  }

  void _answerScreenOff(bool woke) {
    setState(() {
      _woke = woke;
      _phase = _Phase.idle;
    });
    if (!woke) ref.read(localLogProvider).warn('setup', 'screen-off test ring did not wake the tablet');
  }

  void _busyWithOrder() => setState(() => _phase = _Phase.idle);

  @override
  Widget build(BuildContext context) {
    final big = const TextStyle(fontSize: 24, fontWeight: FontWeight.w700);
    Widget yesNo(void Function(bool) f) => Row(
      children: [
        Expanded(
          child: BigButton('YES', icon: Icons.check, onPressed: () => f(true)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: SizedBox(
            height: 64,
            child: OutlinedButton.icon(
              onPressed: () => f(false),
              icon: const Icon(Icons.close),
              label: const Text('NO', style: TextStyle(fontSize: 20)),
            ),
          ),
        ),
      ],
    );

    final content = switch (_phase) {
      _Phase.playing => [Text('Ringing now…', style: big), const SizedBox(height: 12), const LinearProgressIndicator()],
      _Phase.ask => [Text('Did you hear it?', style: big), const SizedBox(height: 16), yesNo(_answer)],
      _Phase.notHeard => [
        Text("Let's make it louder", style: big),
        const SizedBox(height: 10),
        const Text(
          '• Press the volume-up button a few times (the order alarm uses the alarm volume).\n'
          '• Turn off "Do not disturb" if it is on.',
          style: TextStyle(fontSize: 18, height: 1.5),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => ref.read(devicePlatformProvider).openSettings(DeviceSetting.sound),
              icon: const Icon(Icons.volume_up),
              label: const Text('SOUND SETTINGS'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(onPressed: _play, icon: const Icon(Icons.replay), label: const Text('TRY AGAIN')),
          ],
        ),
      ],
      _Phase.screenOffCountdown => [
        Text('Press the power button now', style: big),
        const SizedBox(height: 8),
        Text('The screen goes off. It should ring and wake up in $_count s.', style: const TextStyle(fontSize: 18)),
      ],
      _Phase.screenOffRinging => [
        Text('Ringing…', style: big),
        const SizedBox(height: 12),
        const LinearProgressIndicator(),
      ],
      _Phase.askScreenOff => [
        Text('Did the screen turn on and ring?', style: big),
        const SizedBox(height: 16),
        yesNo(_answerScreenOff),
      ],
      _Phase.idle => [
        if (_heard == true) _result('The chime works', true),
        if (_woke != null)
          _result(
            _woke! ? 'It rings with the screen off' : 'It did not wake up — check the tablet checks in Settings',
            _woke!,
          ),
        Row(
          children: [
            BigButton(
              _heard == null ? 'PLAY TEST RING' : 'PLAY AGAIN',
              icon: Icons.notifications_active,
              onPressed: _play,
            ),
            const SizedBox(width: 16),
            OutlinedButton.icon(
              onPressed: _screenOffTest,
              icon: const Icon(Icons.phonelink_lock),
              label: const Text('TEST WITH THE SCREEN OFF', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ],
    };
    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: content),
          ),
        ),
      ],
    );
  }

  Widget _result(String text, bool ok) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.warning_amber,
          color: ok ? QuiccColors.statusPaid : QuiccColors.statusFiring,
          size: 30,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 19))),
      ],
    ),
  );
}
