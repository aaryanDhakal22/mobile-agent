import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/floor_state.dart';
import '../../core/models.dart';
import '../../core/sse.dart';
import '../../core/time.dart';

/// What a line in the developer log is about.
enum DevLogKind { connection, floor, error, app }

@immutable
class DevLogEntry {
  final DateTime at;
  final DevLogKind kind;
  final String text;
  const DevLogEntry(this.at, this.kind, this.text);
}

/// The tablet's own recent events, in memory only (developer mode → Logs):
/// connects and drops of the live link to the Pi, floor changes (order ids and
/// kitchen numbers only — never names or addresses), failed refreshes and
/// what the app itself did (mode switches, dev unlock). The newest
/// [capacity] lines are kept; a restart starts empty.
///
/// TODO(1.7.0): add the Pi's own log (`GET /api/dev/events?since=`) beside it.
class DevLog extends Notifier<List<DevLogEntry>> {
  static const capacity = 400;

  /// Most order changes logged for one floor update; the rest are counted.
  static const maxOrderLines = 12;

  final DateTime Function() _now;
  DevLog({DateTime Function()? now}) : _now = now ?? timeNow;

  String? _lastRefresh;

  @override
  List<DevLogEntry> build() => const [];

  void add(DevLogKind kind, String text) {
    final next = [...state, DevLogEntry(_now(), kind, text)];
    if (next.length > capacity) next.removeRange(0, next.length - capacity);
    state = next;
  }

  void clear() => state = const [];

  /// Logs what changed between two floor states.
  void observeFloor(FloorState? prev, FloorState next) {
    if (prev == null) return;
    if (prev.connection != next.connection) {
      add(DevLogKind.connection, switch (next.connection) {
        SseStatus.connected => 'Live link to the Pi connected',
        SseStatus.connecting => 'Connecting to the Pi…',
        SseStatus.disconnected => 'Live link dropped — retrying',
      });
    }
    if (prev.error != next.error) {
      if (next.error != null) {
        add(DevLogKind.error, 'Refresh failed: ${next.error}');
      } else if (prev.error != null) {
        add(DevLogKind.floor, 'Refresh works again');
      }
    }
    if (next.lastSyncAt != null && prev.lastSyncAt != next.lastSyncAt) {
      // The 20 s poll refreshes all day: log it only when the picture changed.
      final summary =
          'Full refresh: ${next.orders.length} order${next.orders.length == 1 ? '' : 's'}, '
          '${next.drivers.length} driver${next.drivers.length == 1 ? '' : 's'}';
      if (summary != _lastRefresh) add(DevLogKind.floor, summary);
      _lastRefresh = summary;
    }
    if (next.escalations > prev.escalations) add(DevLogKind.floor, 'An order is still waiting (escalated)');
    if (next.dispatches > prev.dispatches && next.dispatch != null) {
      final d = next.dispatch!;
      add(DevLogKind.floor, 'Driver sent out with ${[for (final o in d.orders) _num(o)].join(' ')}');
    }
    if (next.toasts > prev.toasts && next.toast != null) add(DevLogKind.floor, 'Hub: ${next.toast!.text}');
    if (next.chimes > prev.chimes) add(DevLogKind.floor, 'POS delivery chime');
    if (!identical(prev.orders, next.orders)) _orderChanges(prev.orders, next.orders);
  }

  void _orderChanges(Map<String, StoredOrder> before, Map<String, StoredOrder> after) {
    final lines = <String>[];
    for (final o in after.values) {
      final was = before[o.id];
      if (was == null) {
        lines.add('${_num(o)} ${o.state.wire}');
      } else if (was.state != o.state) {
        lines.add('${_num(o)} ${was.state.wire} → ${o.state.wire}');
      } else if (was.status.poolDriverId != o.status.poolDriverId) {
        lines.add('${_num(o)} ${o.status.poolDriverId == null ? 'unassigned' : 'pooled'}');
      }
    }
    for (final id in before.keys) {
      if (!after.containsKey(id)) lines.add('${_num(before[id]!)} left the board');
    }
    for (final l in lines.take(maxOrderLines)) {
      add(DevLogKind.floor, l);
    }
    if (lines.length > maxOrderLines) add(DevLogKind.floor, '+${lines.length - maxOrderLines} more order changes');
  }
}

/// `#1104` (a vendor id already carries its `#`).
String _num(StoredOrder o) {
  final n = o.displayNumber;
  return n.startsWith('#') ? n : '#$n';
}

final devLogProvider = NotifierProvider<DevLog, List<DevLogEntry>>(DevLog.new);
