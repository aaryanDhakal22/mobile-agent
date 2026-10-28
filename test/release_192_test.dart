// Quibase 1.9.2 (with agent 2.3.8): the "#232 ready · UNDO" pill after
// READY — a READY tapped by mistake goes back to cooking (ticket 232,
// 2026-10-27). The one-timer ticket is covered in release_171_test.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/common/island.dart';
import 'package:mobile_agent/features/kitchen/ready_undo.dart';

import 'fixtures.dart';

class _Floor extends FloorController {
  final List<String> undone = [];
  Object? fail;

  @override
  FloorState build() => const FloorState(connection: SseStatus.connected);

  @override
  Future<void> undoReady(String id) async {
    if (fail != null) throw fail!;
    undone.add(id);
  }
}

StoredOrder _order(int pos) {
  final m = jsonDecode(arrivedPickupJson) as Map<String, dynamic>;
  (m['status'] as Map)['display_number'] = pos;
  return StoredOrder.fromJson(m);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('READY shows "#232 ready" with UNDO for 10 s; UNDO puts it back', () {
    fakeAsync((async) {
      final island = IslandController();
      final floor = _Floor();
      final so = _order(232);
      showReadyUndo(island, floor, so);
      final pill = island.live.single;
      expect(pill.title, '#232 ready');
      expect(pill.kind, IslandKind.success);
      expect(pill.duration, kReadyUndoFor);
      expect(pill.actions.single.label, 'UNDO');
      pill.actions.single.onPressed();
      async.flushMicrotasks();
      expect(floor.undone, [so.id]);
      expect(island.live.first.title, '#232 back to cooking');
      island.dispose();
    });
  });

  test('UNDO too late or on an older Pi says so in plain words', () {
    expect(
      undoReadyError(AgentException('too late', statusCode: 409, code: 'undo_expired'), '#232'),
      'Too late to undo — #232 moved on',
    );
    expect(undoReadyError(AgentException('404 page not found', statusCode: 404), '#232'), 'Update the Pi to undo READY');
    expect(undoReadyError(Exception('x'), '#232'), "Couldn't undo — #232 stays ready");

    fakeAsync((async) {
      final island = IslandController();
      final floor = _Floor()..fail = AgentException('too late', statusCode: 409, code: 'undo_expired');
      showReadyUndo(island, floor, _order(232));
      island.live.single.actions.single.onPressed();
      async.flushMicrotasks();
      expect(island.live.first.title, 'Too late to undo — #232 moved on');
      expect(island.live.first.kind, IslandKind.error);
      island.dispose();
    });
  });
}
