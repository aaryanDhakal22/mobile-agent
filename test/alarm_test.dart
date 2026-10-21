import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/alarm.dart';

void main() {
  group('AlarmRule', () {
    test('silent with nothing arrived', () {
      final s = AlarmRule.onArrived(AlarmState.silent, const []);
      expect(s.ringing, isFalse);
      expect(s.visible, isFalse);
    });

    test('a new arrival rings and shows the alert', () {
      final s = AlarmRule.onArrived(AlarmState.silent, ['a']);
      expect(s.ringing, isTrue);
      expect(s.visible, isTrue);
      expect(s.loud, isFalse);
    });

    test('tapping / hiding never stops the ringing', () {
      var s = AlarmRule.onArrived(AlarmState.silent, ['a']);
      s = AlarmRule.onHide(s);
      expect(s.visible, isFalse);
      expect(s.ringing, isTrue);
      // A re-read of the same queue (poll / reconnect) keeps it ringing and
      // does not force the hidden alert back.
      s = AlarmRule.onArrived(s, ['a']);
      expect(s.ringing, isTrue);
      expect(s.visible, isFalse);
    });

    test('keeps ringing while any order is arrived; stops only when none are', () {
      var s = AlarmRule.onArrived(AlarmState.silent, ['a', 'b']);
      s = AlarmRule.onArrived(s, ['b']); // a accepted
      expect(s.ringing, isTrue);
      s = AlarmRule.onArrived(s, ['b', 'c']); // c arrives
      expect(s.ringing, isTrue);
      s = AlarmRule.onArrived(s, ['c']); // b accepted
      expect(s.ringing, isTrue);
      s = AlarmRule.onArrived(s, const []); // c accepted
      expect(s.ringing, isFalse);
      expect(s.visible, isFalse);
      expect(s.loud, isFalse);
    });

    test('another new order re-shows a hidden alert', () {
      var s = AlarmRule.onHide(AlarmRule.onArrived(AlarmState.silent, ['a']));
      s = AlarmRule.onArrived(s, ['a', 'b']);
      expect(s.visible, isTrue);
    });

    test('escalation makes it loud and visible again; reset when queue empties', () {
      var s = AlarmRule.onHide(AlarmRule.onArrived(AlarmState.silent, ['a']));
      s = AlarmRule.onEscalated(s);
      expect(s.loud, isTrue);
      expect(s.visible, isTrue);
      expect(s.ringing, isTrue);
      // Loudness sticks while the queue still has orders.
      s = AlarmRule.onArrived(s, ['a']);
      expect(s.loud, isTrue);
      s = AlarmRule.onArrived(s, const []);
      expect(s.loud, isFalse);
      expect(s.ringing, isFalse);
    });

    test('escalation with nothing arrived does not ring', () {
      final s = AlarmRule.onEscalated(AlarmState.silent);
      expect(s.ringing, isFalse);
      expect(s.loud, isFalse);
    });

    test('show only applies while ringing', () {
      expect(AlarmRule.onShow(AlarmState.silent).visible, isFalse);
      final s = AlarmRule.onHide(AlarmRule.onArrived(AlarmState.silent, ['a']));
      expect(AlarmRule.onShow(s).visible, isTrue);
    });
  });

  group('alarmSoundAction', () {
    final ringing = AlarmRule.onArrived(AlarmState.silent, ['a']);

    test('starts when ringing begins, stops when it ends', () {
      expect(alarmSoundAction(null, ringing, playing: false, retry: false), AlarmSoundAction.start);
      expect(alarmSoundAction(AlarmState.silent, ringing, playing: false, retry: false), AlarmSoundAction.start);
      expect(alarmSoundAction(ringing, AlarmState.silent, playing: true, retry: false), AlarmSoundAction.stop);
      expect(alarmSoundAction(null, AlarmState.silent, playing: false, retry: true), AlarmSoundAction.none);
    });

    test('an escalation restarts the sound even if it thinks it is playing', () {
      final esc = AlarmRule.onEscalated(ringing);
      expect(esc.escalation, ringing.escalation + 1);
      expect(alarmSoundAction(ringing, esc, playing: true, retry: false), AlarmSoundAction.start);
      // A second escalation (already loud) restarts again.
      final esc2 = AlarmRule.onEscalated(esc);
      expect(alarmSoundAction(esc, esc2, playing: true, retry: false), AlarmSoundAction.start);
    });

    test('a failed start is retried on the next refresh, when allowed', () {
      final again = AlarmRule.onArrived(ringing, ['a']); // a poll re-reads the queue
      expect(alarmSoundAction(ringing, again, playing: false, retry: true), AlarmSoundAction.start);
      expect(alarmSoundAction(ringing, again, playing: false, retry: false), AlarmSoundAction.none);
      expect(alarmSoundAction(ringing, again, playing: true, retry: true), AlarmSoundAction.none);
    });

    test('loud toggled while playing only changes the volume', () {
      final loud = ringing.copyWith(loud: true);
      expect(alarmSoundAction(ringing, loud, playing: true, retry: false), AlarmSoundAction.setLoud);
    });

    test('escalating a silent alarm does nothing', () {
      expect(AlarmRule.onEscalated(AlarmState.silent).escalation, 0);
    });

    test('the escalation count survives queue re-reads', () {
      final esc = AlarmRule.onEscalated(ringing);
      expect(AlarmRule.onArrived(esc, ['a', 'b']).escalation, esc.escalation);
    });
  });
}
