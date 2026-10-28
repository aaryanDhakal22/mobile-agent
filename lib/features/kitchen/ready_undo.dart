import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../common/island.dart';

/// How long the "#232 ready · UNDO" pill stays (1.9.2). The Pi takes an
/// undo up to 2 min after READY, so a slow network still makes it.
const Duration kReadyUndoFor = Duration(seconds: 10);

/// After READY: a green pill "#232 ready" with UNDO for [kReadyUndoFor] — a
/// READY tapped by mistake (ticket 232, 2026-10-27: a paid counter check
/// left Kitchen at once and nobody saw it) goes back to cooking. [island]
/// and [floor] are read before the READY call: the ticket that was tapped
/// leaves the screen with it.
void showReadyUndo(IslandController? island, FloorController floor, StoredOrder so) {
  if (island == null) return;
  final n = so.displayNumber.startsWith('#') ? so.displayNumber : '#${so.displayNumber}';
  void say(String text, {bool error = false}) => island.show(text, kind: error ? IslandKind.error : IslandKind.info);
  island.show(
    '$n ready',
    kind: IslandKind.success,
    duration: kReadyUndoFor,
    actions: [
      IslandAction('UNDO', () async {
        try {
          await floor.undoReady(so.id);
          say('$n back to cooking');
        } catch (e) {
          say(undoReadyError(e, n), error: true);
        }
      }),
    ],
  );
}

/// The UNDO's failure in plain words.
String undoReadyError(Object e, String n) {
  if (e is AgentException) {
    if (e.code == 'undo_expired') return 'Too late to undo — $n moved on';
    if ((e.isNotFound || e.statusCode == 405) && e.code == null) return 'Update the Pi to undo READY';
  }
  return "Couldn't undo — $n stays ready";
}
