/// The new-order alarm rule, kept pure so it can be unit-tested:
///
/// * it rings while **any** order is `arrived`, and stops only when none are;
/// * a new arrival (an id not seen before) makes the full-screen alert
///   visible;
/// * hiding the alert (a tap) never silences it;
/// * an `order.escalated` frame makes it loud and visible again;
/// * when the queue empties everything resets.
class AlarmState {
  final bool ringing;
  final bool loud;
  final bool visible;

  /// Arrived ids at the last update — to tell new arrivals apart.
  final Set<String> known;

  /// Bumped on every escalation while ringing — the alarm host restarts the
  /// sound then (the player may have stopped), not just turns it up.
  final int escalation;

  const AlarmState({
    this.ringing = false,
    this.loud = false,
    this.visible = false,
    this.known = const {},
    this.escalation = 0,
  });

  static const silent = AlarmState();

  AlarmState copyWith({bool? ringing, bool? loud, bool? visible, Set<String>? known, int? escalation}) => AlarmState(
    ringing: ringing ?? this.ringing,
    loud: loud ?? this.loud,
    visible: visible ?? this.visible,
    known: known ?? this.known,
    escalation: escalation ?? this.escalation,
  );

  @override
  String toString() => 'AlarmState(ringing=$ringing loud=$loud visible=$visible n=${known.length})';
}

class AlarmRule {
  const AlarmRule._();

  /// The arrived queue changed (or was re-read).
  static AlarmState onArrived(AlarmState s, Iterable<String> arrivedIds) {
    final ids = arrivedIds.toSet();
    if (ids.isEmpty) return AlarmState.silent;
    final hasNew = ids.difference(s.known).isNotEmpty;
    return AlarmState(ringing: true, loud: s.loud, visible: s.visible || hasNew, known: ids, escalation: s.escalation);
  }

  /// An order has waited too long: louder, and back on screen.
  static AlarmState onEscalated(AlarmState s) {
    if (!s.ringing) return s;
    return s.copyWith(loud: true, visible: true, escalation: s.escalation + 1);
  }

  /// Staff tapped "hide": the alert leaves the screen but keeps ringing.
  static AlarmState onHide(AlarmState s) => s.copyWith(visible: false);

  /// Staff tapped the ringing banner: bring the alert back.
  static AlarmState onShow(AlarmState s) => s.ringing ? s.copyWith(visible: true) : s;
}

enum AlarmSoundAction { none, start, stop, setLoud }

/// What the alarm host does with the sound for an alarm-state change — kept
/// pure for tests. [playing] / [retry] come from AlertPlayer.
///
/// * starts ringing → start;
/// * stops ringing → stop;
/// * an escalation → start again (restarts a player that stopped, louder);
/// * still ringing but the player isn't (a failed start) → retry, throttled
///   by [retry] — every floor refresh re-evaluates this;
/// * loud toggled while playing → volume only.
AlarmSoundAction alarmSoundAction(AlarmState? prev, AlarmState next, {required bool playing, required bool retry}) {
  final was = prev?.ringing ?? false;
  if (!next.ringing) return was ? AlarmSoundAction.stop : AlarmSoundAction.none;
  if (!was) return AlarmSoundAction.start;
  if (prev != null && next.escalation != prev.escalation) return AlarmSoundAction.start;
  if (!playing && retry) return AlarmSoundAction.start;
  if (prev != null && next.loud != prev.loud) return AlarmSoundAction.setLoud;
  return AlarmSoundAction.none;
}
