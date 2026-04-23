import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Fixed roster. Updating requires a code change.
const List<String> kDriverRoster = [
  'Abdul',
  'Amadou',
  'Antonio',
  'Carlos',
  'Deep',
  'Juma',
];

/// Hour (device-local) at which the daily reset fires. Assumed to match the
/// restaurant's timezone (EST/EDT on the Swan 1 tablet). If the tablet ever
/// leaves Eastern time, this needs to migrate to `package:timezone`.
const int _resetHour = 10;

class DriverState {
  /// Drivers currently on shift, in clock-in order. Keys are the driver name;
  /// values are the exact instant they were toggled on (used by the Drivers
  /// tab to display the HH:MM clock-in time next to the name). Dart's default
  /// Map preserves insertion order, so iterating `onShift.keys` gives the
  /// order the expanded FAB should render.
  final Map<String, DateTime> onShift;

  /// FIFO queue. Each driver appears at most once — duplicate enqueues are
  /// silently rejected.
  final List<String> queue;

  /// The most recent dequeue, kept around for one-step undo. Cleared once
  /// undo consumes it or once another dequeue overwrites it.
  final String? lastDequeued;

  const DriverState({
    this.onShift = const {},
    this.queue = const [],
    this.lastDequeued,
  });

  DriverState copyWith({
    Map<String, DateTime>? onShift,
    List<String>? queue,
    Object? lastDequeued = _sentinel,
  }) {
    return DriverState(
      onShift: onShift ?? this.onShift,
      queue: queue ?? this.queue,
      lastDequeued: identical(lastDequeued, _sentinel)
          ? this.lastDequeued
          : lastDequeued as String?,
    );
  }

  static const _sentinel = Object();
}

class DriverNotifier extends StateNotifier<DriverState>
    with WidgetsBindingObserver {
  final StreamController<String> _announcements =
      StreamController<String>.broadcast();

  Timer? _resetTimer;
  DateTime _lastResetAt;

  DriverNotifier()
      : _lastResetAt = _mostRecentResetBoundary(DateTime.now()),
        super(const DriverState()) {
    WidgetsBinding.instance.addObserver(this);
    _scheduleNextReset();
  }

  Stream<String> get announcements => _announcements.stream;

  void toggle(String name) {
    if (state.onShift.containsKey(name)) {
      // Off-shift cascades: remove from the roster, drop any queued entries,
      // and clear the undo slot if it points at this driver.
      final nextRoster = {...state.onShift}..remove(name);
      final nextQueue = state.queue.where((n) => n != name).toList();
      final nextLast = state.lastDequeued == name ? null : state.lastDequeued;
      state = state.copyWith(
        onShift: nextRoster,
        queue: nextQueue,
        lastDequeued: nextLast,
      );
    } else {
      state = state.copyWith(
        onShift: {...state.onShift, name: DateTime.now()},
      );
    }
  }

  bool isOnShift(String name) => state.onShift.containsKey(name);

  /// Appends [name] to the queue if they aren't already there. Returns true
  /// on success, false if the enqueue was rejected as a duplicate.
  bool enqueue(String name) {
    if (state.queue.contains(name)) return false;
    state = state.copyWith(queue: [...state.queue, name]);
    return true;
  }

  /// Pops the head of the queue. Returns the dequeued name, or null if the
  /// queue was empty. Broadcasts the name on the announcements stream so the
  /// UI can blink it.
  String? dequeue() {
    if (state.queue.isEmpty) return null;
    final head = state.queue.first;
    state = state.copyWith(
      queue: state.queue.sublist(1),
      lastDequeued: head,
    );
    _announcements.add(head);
    return head;
  }

  /// Puts the last-dequeued driver back at the head. Returns true if
  /// anything actually happened.
  bool undo() {
    final target = state.lastDequeued;
    if (target == null) return false;
    state = state.copyWith(
      queue: [target, ...state.queue],
      lastDequeued: null,
    );
    return true;
  }

  void _reset() {
    state = const DriverState();
    _lastResetAt = _mostRecentResetBoundary(DateTime.now());
  }

  void _scheduleNextReset() {
    _resetTimer?.cancel();
    final now = DateTime.now();
    final next = _nextResetBoundary(now);
    _resetTimer = Timer(next.difference(now), () {
      _reset();
      _scheduleNextReset();
    });
  }

  /// If the app was backgrounded past a reset boundary, the in-process Timer
  /// may not have fired. On resume, catch up.
  void _catchUpResetIfNeeded() {
    final boundary = _mostRecentResetBoundary(DateTime.now());
    if (_lastResetAt.isBefore(boundary)) {
      _reset();
    }
    _scheduleNextReset();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _catchUpResetIfNeeded();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resetTimer?.cancel();
    _announcements.close();
    super.dispose();
  }
}

DateTime _mostRecentResetBoundary(DateTime now) {
  final today = DateTime(now.year, now.month, now.day, _resetHour);
  if (!now.isBefore(today)) return today;
  return today.subtract(const Duration(days: 1));
}

DateTime _nextResetBoundary(DateTime now) {
  final today = DateTime(now.year, now.month, now.day, _resetHour);
  if (now.isBefore(today)) return today;
  return today.add(const Duration(days: 1));
}

final driverProvider =
    StateNotifierProvider<DriverNotifier, DriverState>((ref) {
  final notifier = DriverNotifier();
  ref.onDispose(notifier.dispose);
  return notifier;
});

/// Fires the head-name of every dequeue. UI listens to this (not to
/// `lastDequeued`) so re-announcing the same name twice in a row still
/// triggers the blink animation.
final driverAnnouncementStreamProvider = StreamProvider<String>((ref) {
  final notifier = ref.watch(driverProvider.notifier);
  return notifier.announcements;
});
