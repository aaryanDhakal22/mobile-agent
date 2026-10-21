import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'alarm.dart';
import 'alert_player.dart';
import 'providers.dart';
import 'ring_platform.dart';
import 'sse.dart';

/// Overridden in tests with a fake.
final ringPlatformProvider = Provider<RingPlatform>((_) => RingPlatform());

/// Wires the alarm to the speaker and to Android, at the ProviderContainer
/// level rather than inside a widget, so orders keep ringing while no screen
/// is attached (the app is in the background, swiped away, or the tablet's
/// screen is off — RingService keeps the process alive):
///
/// * the alarm state drives the chime (AlertPlayer) and the full-screen
///   new-order notification;
/// * being paired runs the "Listening for new orders" foreground service,
///   whose text follows the connection to the Pi.
///
/// Returns a function that undoes it (tests).
VoidCallback startRingBridge(ProviderContainer c) {
  final ring = c.read(ringPlatformProvider);
  final subs = <ProviderSubscription<Object?>>[];

  subs.add(
    c.listen<AlarmState>(alarmProvider, (prev, next) {
      final action = alarmSoundAction(prev, next, playing: AlertPlayer.isPlaying, retry: AlertPlayer.shouldRetry());
      switch (action) {
        case AlarmSoundAction.start:
          unawaited(AlertPlayer.start(c.read(alertSoundProvider), loud: next.loud));
        case AlarmSoundAction.stop:
          unawaited(AlertPlayer.stop());
        case AlarmSoundAction.setLoud:
          unawaited(AlertPlayer.setLoud(next.loud));
        case AlarmSoundAction.none:
          break;
      }
      if (!next.ringing) {
        // At start (prev == null) too: a ring notification left over from
        // before a restart / update must not outlive its order.
        if (prev == null || prev.ringing) unawaited(ring.cancelRing());
      } else if (ringNotificationDue(prev, next)) {
        final n = next.known.length;
        unawaited(
          ring.showRing(
            title: n == 1 ? 'New order' : '$n orders waiting',
            text: next.loud ? 'Waiting too long — accept it now' : 'Tap to accept',
          ),
        );
      }
    }, fireImmediately: true),
  );

  // Only pairing / unpairing matters here (not a rename or a new address).
  // Unpaired at start also stops the service: RestartReceiver starts it after
  // a reboot / self-update before Dart knows whether the tablet is paired.
  subs.add(
    c.listen<bool>(pairingProvider.select((p) => p != null), (prev, paired) {
      if (paired) {
        unawaited(ring.startService(serviceText(c.read(floorProvider).connection)));
      } else {
        unawaited(ring.stopService());
      }
    }, fireImmediately: true),
  );

  subs.add(
    c.listen<SseStatus>(floorProvider.select((s) => s.connection), (prev, next) {
      if (c.read(pairingProvider) != null && prev != next) unawaited(ring.updateService(serviceText(next)));
    }),
  );

  // Android may refuse to start the service while the app is in the
  // background; it is started again whenever the app comes back.
  final lifecycle = AppLifecycleListener(
    onResume: () {
      if (c.read(pairingProvider) != null) {
        unawaited(ring.startService(serviceText(c.read(floorProvider).connection)));
      }
    },
  );

  return () {
    for (final s in subs) {
      s.close();
    }
    lifecycle.dispose();
  };
}

/// The full-screen notification is (re)posted when ringing starts, when a new
/// order joins the queue and on every escalation.
bool ringNotificationDue(AlarmState? prev, AlarmState next) {
  if (!next.ringing) return false;
  if (prev == null || !prev.ringing) return true;
  if (next.escalation != prev.escalation) return true;
  return next.known.difference(prev.known).isNotEmpty;
}

String serviceText(SseStatus s) => switch (s) {
  SseStatus.connected => 'Listening for new orders',
  SseStatus.connecting => 'Connecting to the Pi…',
  SseStatus.disconnected => "Can't reach the Pi — open Quibase",
};
