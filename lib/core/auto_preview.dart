import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'delivery_models.dart';
import 'floor_state.dart';
import 'providers.dart';

/// An AUTO suggestion on screen: the deliveries it would add to each
/// driver's pool, drawn yellow in the driver boxes. Lives only in this
/// tablet's memory — nothing is saved until CONFIRM (or Send Out).
class AutoPreview {
  final AutoPlan plan;

  /// driver id → the suggested order ids still showing (in driving order).
  final Map<String, List<String>> suggestions;

  /// Staff changed the suggestion (removed or moved a yellow stop), so the
  /// plan as stored on the Pi no longer matches.
  final bool edited;

  const AutoPreview({required this.plan, required this.suggestions, this.edited = false});

  factory AutoPreview.fromPlan(AutoPlan plan) {
    final s = <String, List<String>>{};
    for (final r in plan.runs) {
      if (r.driverId.isEmpty || r.suggestedIds.isEmpty) continue;
      // Keep the run's driving order for the suggested stops.
      final ordered = [
        for (final id in r.orderIds)
          if (r.suggestedIds.contains(id)) id,
      ];
      for (final id in r.suggestedIds) {
        if (!ordered.contains(id)) ordered.add(id);
      }
      s[r.driverId] = ordered;
    }
    return AutoPreview(plan: plan, suggestions: s);
  }

  String get planId => plan.planId;
  bool get isEmpty => suggestions.values.every((l) => l.isEmpty);
  Set<String> get suggestedIds => {for (final l in suggestions.values) ...l};
  int get count => suggestions.values.fold(0, (n, l) => n + l.length);
  List<String> suggestedFor(String driverId) => suggestions[driverId] ?? const [];

  String? driverFor(String orderId) {
    for (final e in suggestions.entries) {
      if (e.value.contains(orderId)) return e.key;
    }
    return null;
  }

  AutoPreview without(Iterable<String> ids) {
    final drop = ids.toSet();
    if (!suggestedIds.any(drop.contains)) return this;
    return AutoPreview(
      plan: plan,
      suggestions: {
        for (final e in suggestions.entries)
          if (e.value.any((id) => !drop.contains(id))) e.key: e.value.where((id) => !drop.contains(id)).toList(),
      },
      edited: true,
    );
  }

  AutoPreview withoutDriver(String driverId) =>
      AutoPreview(plan: plan, suggestions: {...suggestions}..remove(driverId), edited: edited);

  AutoPreview withRun(String driverId, List<String> ids) =>
      AutoPreview(plan: plan, suggestions: {...suggestions, driverId: ids}, edited: edited);

  /// Still true to the floor: every suggested delivery is still unassigned
  /// and every driver still available.
  bool validFor(FloorState fs) {
    final unassigned = {for (final o in fs.unassignedDeliveries) o.id};
    final available = {for (final d in fs.availableDrivers) d.id};
    for (final e in suggestions.entries) {
      if (!available.contains(e.key)) return false;
      for (final id in e.value) {
        if (!unassigned.contains(id)) return false;
      }
    }
    return true;
  }
}

/// The AUTO preview (null = none). Drops itself — and bumps
/// [autoPreviewDroppedProvider] so the Deliveries pane can say so — when the
/// floor changes under it (a suggested order sent, moved or cancelled
/// elsewhere, a driver gone).
class AutoPreviewController extends Notifier<AutoPreview?> {
  @override
  AutoPreview? build() {
    ref.listen<FloorState>(floorProvider, (_, next) => _check(next));
    return null;
  }

  void _check(FloorState fs) {
    final p = state;
    if (p == null || p.validFor(fs)) return;
    state = null;
    ref.read(autoPreviewDroppedProvider.notifier).state++;
  }

  /// Shows [plan]; false when it suggests nothing.
  bool show(AutoPlan plan) {
    final p = AutoPreview.fromPlan(plan);
    state = p.isEmpty ? null : p;
    if (state != null) _check(ref.read(floorProvider));
    return state != null;
  }

  void clear() => state = null;

  /// Takes [ids] out of the suggestion — staff moved or removed them (do this
  /// *before* pooling them, so the change isn't mistaken for someone else's).
  void forget(Iterable<String> ids) {
    final p = state;
    if (p == null) return;
    final next = p.without(ids);
    state = next.isEmpty ? null : next;
  }

  /// Removes [driverId]'s yellow stops while they are being sent out, and
  /// returns them (the send-out's echo must not drop the whole preview).
  List<String> takeRun(String driverId) {
    final p = state;
    if (p == null) return const [];
    final ids = p.suggestedFor(driverId);
    if (ids.isEmpty) return const [];
    final next = p.withoutDriver(driverId);
    state = next.isEmpty ? null : next;
    return ids;
  }

  /// The send-out failed: put [driverId]'s yellow stops back (if the same
  /// plan is still showing, or none is).
  void restoreRun(AutoPreview from, String driverId, List<String> ids) {
    if (ids.isEmpty) return;
    final p = state;
    if (p != null && p.planId != from.planId) return;
    final next = (p ?? from.withoutDriverAll()).withRun(driverId, ids);
    state = next.validFor(ref.read(floorProvider)) ? next : p;
  }
}

extension on AutoPreview {
  AutoPreview withoutDriverAll() => AutoPreview(plan: plan, suggestions: const {}, edited: edited);
}

final autoPreviewProvider = NotifierProvider<AutoPreviewController, AutoPreview?>(AutoPreviewController.new);

/// Bumped each time the preview is dropped because the floor changed.
final autoPreviewDroppedProvider = StateProvider<int>((_) => 0);
