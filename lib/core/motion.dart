import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Motion preferences (1.6.0): an on/off switch and an animation-speed slider
/// in Store settings, plus Android's "remove animations". Every decorative
/// animation (rail mode switch, blob highlight, AUTO glow) runs its durations
/// through [Motion.scale] so one setting governs them all.
@immutable
class MotionSettings {
  /// Off = quick fades instead of the full effects.
  final bool enabled;

  /// 0.5 = twice as fast … 2.0 = half speed. 1.0 is the designed timing.
  final double speed;

  const MotionSettings({this.enabled = true, this.speed = 1.0});

  static const double minSpeed = 0.5;
  static const double maxSpeed = 2.0;

  MotionSettings copyWith({bool? enabled, double? speed}) =>
      MotionSettings(enabled: enabled ?? this.enabled, speed: (speed ?? this.speed).clamp(minSpeed, maxSpeed));
}

class MotionNotifier extends Notifier<MotionSettings> {
  static const _kEnabled = 'motion_enabled';
  static const _kSpeed = 'motion_speed';

  @override
  MotionSettings build() {
    final prefs = ref.watch(storageProvider).prefs;
    return MotionSettings(
      enabled: prefs.getBool(_kEnabled) ?? true,
      speed: (prefs.getDouble(_kSpeed) ?? 1.0).clamp(MotionSettings.minSpeed, MotionSettings.maxSpeed),
    );
  }

  void setEnabled(bool on) {
    state = state.copyWith(enabled: on);
    unawaited(ref.read(storageProvider).prefs.setBool(_kEnabled, on));
  }

  void setSpeed(double speed) {
    state = state.copyWith(speed: speed);
    unawaited(ref.read(storageProvider).prefs.setDouble(_kSpeed, state.speed));
  }
}

final motionProvider = NotifierProvider<MotionNotifier, MotionSettings>(MotionNotifier.new);

/// Read motion in a widget: `final m = Motion.of(context, ref);`
@immutable
class Motion {
  /// Full effects (setting on and Android animations not disabled).
  final bool full;
  final double speed;

  const Motion({required this.full, required this.speed});

  static Motion of(BuildContext context, WidgetRef ref) {
    final s = ref.watch(motionProvider);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Motion(full: s.enabled && !reduced, speed: s.speed);
  }

  /// A designed duration at the user's speed. When motion is reduced the
  /// caller should swap to [fade] instead of the full effect.
  Duration scale(Duration d) => Duration(microseconds: (d.inMicroseconds * speed).round());

  /// The short cross-fade used instead of decorative effects.
  Duration get fade => scale(const Duration(milliseconds: 150));
}
