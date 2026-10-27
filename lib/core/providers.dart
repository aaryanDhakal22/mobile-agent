import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'alarm.dart';
import 'alert_player.dart';
import 'api_client.dart';
import 'delivery_models.dart';
import 'floor_state.dart';
import 'friendly_error.dart';
import 'local_log.dart';
import 'models.dart';
import 'printer_models.dart';
import 'sse.dart';
import 'storage.dart';
import 'time.dart';

// =============================================================================
// Storage + pairing
// =============================================================================

/// Overridden in main() with the loaded instance.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (_) => throw UnimplementedError('sharedPrefsProvider must be overridden'),
);

final storageProvider = Provider<AppStorage>((ref) => AppStorage(ref.watch(sharedPrefsProvider)));

/// The stored pairing, or null → show the pairing screen.
class PairingNotifier extends Notifier<Pairing?> {
  /// Why we were last sent back to pairing (shown on the pairing screen).
  String? lastUnpairReason;

  @override
  Pairing? build() => ref.watch(storageProvider).readPairing();

  /// `POST /api/pair` then persist the key.
  Future<void> pair({required String address, required String code, required String name}) async {
    final base = normalizeAgentAddress(address);
    final r = await AgentClient.pair(address: base, code: code, name: name);
    final p = Pairing(
      address: base,
      deviceKey: r.key,
      deviceName: r.name.isEmpty ? name.trim() : r.name,
      deviceId: r.deviceId,
    );
    await ref.read(storageProvider).writePairing(p);
    lastUnpairReason = null;
    state = p;
  }

  /// A new Pi: link it with the store manager login (the agent pairs this
  /// tablet in the same call) and persist the key.
  Future<LinkResult> link({
    required String address,
    required String username,
    required String password,
    required String name,
  }) async {
    final base = normalizeAgentAddress(address);
    final r = await AgentClient.link(address: base, username: username, password: password, tabletName: name);
    final p = Pairing(
      address: base,
      deviceKey: r.key,
      deviceName: r.name.isEmpty ? name.trim() : r.name,
      deviceId: r.deviceId,
    );
    await ref.read(storageProvider).writePairing(p);
    lastUnpairReason = null;
    state = p;
    return r;
  }

  /// This tablet was renamed on the agent: remember the new name.
  Future<void> rename(String name) async {
    final p = state;
    if (p == null || name.trim().isEmpty) return;
    await ref.read(storageProvider).setDeviceName(name.trim());
    state = Pairing(address: p.address, deviceKey: p.deviceKey, deviceName: name.trim(), deviceId: p.deviceId);
  }

  /// Point the existing key at a new agent address (the Pi changed IP).
  Future<void> setAddress(String address) async {
    final p = state;
    final base = normalizeAgentAddress(address);
    if (p == null || base.isEmpty) return;
    final next = p.copyWith(address: base);
    await ref.read(storageProvider).writePairing(next);
    state = next;
  }

  Future<void> unpair({String? reason}) async {
    if (state == null) return;
    lastUnpairReason = reason;
    await ref.read(storageProvider).clearKey();
    state = null;
  }
}

final pairingProvider = NotifierProvider<PairingNotifier, Pairing?>(PairingNotifier.new);

/// Just what the connection to the agent depends on: the address and the
/// device key. Renaming the tablet (or saving the same address) leaves it
/// unchanged, so the client, the SSE connection and the floor aren't rebuilt.
typedef AgentLink = ({String address, String deviceKey});

final _agentLinkProvider = Provider<AgentLink?>(
  (ref) => ref.watch(pairingProvider.select((p) => p == null ? null : (address: p.address, deviceKey: p.deviceKey))),
);

/// Called by any 401 `device_required`: wipe the key, back to pairing.
void _deviceRevoked(Ref ref) {
  // Deferred: this can fire from inside another provider's work.
  scheduleMicrotask(() {
    try {
      ref
          .read(pairingProvider.notifier)
          .unpair(reason: 'This tablet was unpaired by the agent. Pair it again with a new code.');
    } catch (_) {
      // Already unpaired (this ref was disposed by an earlier 401).
    }
  });
}

/// HTTP client for the paired agent (null while unpaired).
final agentClientProvider = Provider<AgentClient?>((ref) {
  final p = ref.watch(_agentLinkProvider);
  if (p == null) return null;
  final client = AgentClient(baseUrl: p.address, deviceKey: p.deviceKey, onDeviceRevoked: () => _deviceRevoked(ref));
  ref.onDispose(client.dispose);
  return client;
});

AgentClient _requireClient(Ref ref) {
  final c = ref.read(agentClientProvider);
  if (c == null) throw const AgentException('This tablet is not paired');
  return c;
}

// =============================================================================
// Live floor state: SSE + refetch + a full refresh every 3 min (20 s while
// the live link is down)
// =============================================================================

/// Full floor refresh while the live link (SSE) is down.
const Duration kPollInterval = Duration(seconds: 20);

/// Full floor refresh while the live link is up (1.9.0): the frames keep the
/// floor current, so this is only a safety net — every 20 s re-parsed every
/// order of the batch for nothing.
const Duration kLivePollInterval = Duration(minutes: 3);

/// HTTP client per SSE connection attempt — overridden in tests.
final sseClientFactoryProvider = Provider<http.Client Function()>((_) => http.Client.new);

/// SSE reconnect backoff — overridden in tests.
final sseBackoffProvider = Provider<Duration Function(int attempt)>((_) => sseBackoff);

class FloorController extends Notifier<FloorState> {
  AgentEventStream? _sse;
  Timer? _poll;
  Duration? _pollEvery;
  bool _disposed = false;

  /// Bumped on every (re)build; callbacks from an older build's SSE stream or
  /// refresh are dropped.
  int _gen = 0;
  bool _refreshing = false;
  bool _refreshAgain = false;
  List<SseEvent>? _bufferedDuringRefresh;

  @override
  FloorState build() {
    final pairing = ref.watch(_agentLinkProvider);
    ref.watch(agentClientProvider);
    _disposed = false;
    final gen = ++_gen;
    ref.onDispose(() {
      _disposed = true;
      _sse?.stop();
      _sse = null;
      _poll?.cancel();
      _poll = null;
      _pollEvery = null;
    });
    if (pairing == null) return const FloorState(connection: SseStatus.disconnected);

    _sse = AgentEventStream(
      baseUrl: pairing.address,
      deviceKey: pairing.deviceKey,
      onEvent: (ev) {
        if (gen == _gen) _onEvent(ev);
      },
      onStatus: (st) {
        if (gen != _gen) return;
        _set(state.copyWith(connection: st));
        _armPoll(st);
      },
      onConnected: () {
        if (gen == _gen) unawaited(refresh());
      },
      onDeviceRevoked: () {
        if (gen == _gen) _deviceRevoked(ref);
      },
      clientFactory: ref.read(sseClientFactoryProvider),
      backoff: ref.read(sseBackoffProvider),
    )..start();
    _armPoll(SseStatus.connecting);
    // The SSE connect triggers the first refresh; this covers an agent whose
    // SSE is down but whose REST still answers.
    scheduleMicrotask(() => unawaited(refresh()));
    return const FloorState();
  }

  /// The safety-net refresh: every [kLivePollInterval] while the live link is
  /// up, every [kPollInterval] while it is down (re-armed on each change).
  void _armPoll(SseStatus st) {
    if (_disposed) return;
    final every = st == SseStatus.connected ? kLivePollInterval : kPollInterval;
    if (_poll != null && _pollEvery == every) return;
    _poll?.cancel();
    _pollEvery = every;
    _poll = Timer.periodic(every, (_) => unawaited(refresh()));
  }

  /// How often the safety-net refresh runs now (tests).
  @visibleForTesting
  Duration? get pollEvery => _pollEvery;

  void _set(FloorState s) {
    if (_disposed) return;
    state = s;
  }

  void _onEvent(SseEvent ev) {
    if (_disposed) return;
    _bufferedDuringRefresh?.add(ev);
    final up = applySseEvent(state, ev);
    _set(up.state);
    if (up.refetch) unawaited(refresh());
    // 2.2.1: a one-off signal, not floor state (a refresh replays frames).
    if (ev.event == 'deliveries.auto_assigned') {
      final a = AutoAssignment.fromJson(ev.json);
      if (a != null) _autoAssigned(a);
    }
    // Pi 2.3: a clock-out's report printed (or didn't) in the background —
    // the app-wide toast, once (kept out of the reducer so a refresh's
    // replay doesn't show it twice).
    if (ev.event == 'driver.report_printed') {
      final p = DriverReportPrinted.fromJson(ev.json);
      if (p != null) _set(state.copyWith(toast: p.toToast(), toasts: state.toasts + 1));
    }
    // Pi 2.3.7: a SEND OUT's route didn't reach the driver's phone — a red
    // pill, once (nothing when it went).
    if (ev.event == 'driver.route') {
      final t = DriverRouteSent.fromJson(ev.json)?.toToast();
      if (t != null) _set(state.copyWith(toast: t, toasts: state.toasts + 1));
    }
  }

  /// An SSE frame, as the stream delivers it (tests).
  @visibleForTesting
  void handleEvent(SseEvent ev) => _onEvent(ev);

  /// The Pi pooled deliveries for the NEXT driver: the driver button pops
  /// open on the NEXT card ([fobPopProvider]).
  void _autoAssigned(AutoAssignment a) {
    ref.read(fobPopProvider.notifier).state = a;
  }

  /// The soft chime once (the ring bridge plays it).
  void chime() => _set(state.copyWith(chimes: state.chimes + 1));

  /// Refetches floor, current batch, arrived queue and drivers. Frames that
  /// arrive mid-fetch are replayed on top so a slow fetch can't roll them back.
  Future<void> refresh() async {
    final client = ref.read(agentClientProvider);
    if (client == null || _disposed) return;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    final gen = _gen;
    _bufferedDuringRefresh = [];
    try {
      final results = await Future.wait([
        client.getFloor(),
        client.listAllOrders(batch: 'current'),
        client.listArrived(),
        client.listDrivers(),
      ]);
      if (_disposed || gen != _gen) return;
      var next = state.withSnapshot(
        floor: results[0] as Floor,
        current: results[1] as List<StoredOrder>,
        arrived: results[2] as List<StoredOrder>,
        drivers: results[3] as List<Driver>,
        at: timeNow(),
      );
      for (final ev in _bufferedDuringRefresh ?? const <SseEvent>[]) {
        next = applySseEvent(next, ev).state;
      }
      _set(next);
    } catch (e) {
      if (gen == _gen && !_disposed) {
        // Plain words for anything that shows it; the technical text goes
        // to the local log once per new problem (this retries every 20 s while the link is down).
        final f = FriendlyError.from(e);
        if (state.error != f.short) ref.read(localLogProvider).warn('floor', 'refresh failed: ${f.details}');
        _set(state.copyWith(error: f.short));
      }
    } finally {
      _bufferedDuringRefresh = null;
      _refreshing = false;
      if (_refreshAgain && !_disposed) {
        _refreshAgain = false;
        unawaited(refresh());
      }
    }
  }

  /// App came back to the foreground: reconnect + refetch now.
  void resume() {
    _sse?.reconnectNow();
    unawaited(refresh());
  }

  void _upsert(Iterable<StoredOrder> list) => _set(state.withOrders(list));

  // --- actions (errors propagate to the UI) ----------------------------------

  Future<StoredOrder> accept(String id, int? prepMinutes) async {
    try {
      final o = await _requireClient(ref).accept(id, prepMinutes: prepMinutes);
      _upsert([o]);
      return o;
    } on AgentException catch (e) {
      // 409 taken elsewhere / 502 reverted / 404 gone: resync the truth.
      if (!e.isNetwork) unawaited(refresh());
      rethrow;
    }
  }

  /// First confirm of a future order (or a new lead for a scheduled one):
  /// nothing prints; it waits in the Later strip until it rings again.
  Future<void> schedule(String id, int leadMinutes) async {
    try {
      final o = await _requireClient(ref).schedule(id, leadMinutes);
      if (o != null && o.id.isNotEmpty) {
        _upsert([o]);
      } else {
        unawaited(refresh());
      }
    } on AgentException catch (e) {
      if (!e.isNetwork) unawaited(refresh());
      rethrow;
    }
  }

  /// Staff picked candidate [index] of an ambiguous address; the located
  /// address arrives later as an order update.
  Future<void> chooseGeo(String orderId, int index) => _requireClient(ref).chooseGeo(orderId, index);

  /// SEARCH ADDRESS (1.7.2): main searches [query] near the store; the
  /// answer arrives later as an order update (candidates or not found).
  Future<void> searchGeo(String orderId, String query) => _requireClient(ref).searchGeo(orderId, query);

  // --- 2.1.0 settings (saved on the Pi, shown at once) -----------------------

  void _setSettings(FloorSettings Function(FloorSettings) change) {
    final f = state.floor;
    if (f != null) _set(state.copyWith(floor: f.copyWith(settings: change(f.settings))));
  }

  Future<FeatureToggles> saveFeatures(FeatureToggles next) async {
    final saved = await _requireClient(ref).putFeatures(next);
    _setSettings((s) => s.copyWith(features: saved));
    return saved;
  }

  Future<TicketToggles> saveTickets(TicketToggles next) async {
    final saved = await _requireClient(ref).putTickets(next);
    _setSettings((s) => s.copyWith(tickets: saved));
    return saved;
  }

  Future<DefaultTimes> saveTimes(DefaultTimes next) async {
    final saved = await _requireClient(ref).putTimes(next);
    _setSettings((s) => s.copyWith(times: saved));
    return saved;
  }

  Future<FinishingSettings> saveFinishing(FinishingSettings next) async {
    final saved = await _requireClient(ref).putFinishing(next);
    _setSettings((s) => s.copyWith(finishing: saved));
    return saved;
  }

  Future<CalloutSettings> saveCallout(CalloutSettings next) async {
    final saved = await _requireClient(ref).putCallout(next);
    _setSettings((s) => s.copyWith(callout: saved));
    return saved;
  }

  /// OK on the blue CHANGED alert: marked acked on the Pi (every tablet
  /// stops ringing). Already OK'd elsewhere (409) → refetch.
  Future<void> ackChange(String id, String changeId) async {
    try {
      _upsert([await _requireClient(ref).ackChange(id, changeId)]);
    } on AgentException catch (e) {
      if (e.isConflict || e.isNotFound) {
        unawaited(refresh());
        return;
      }
      rethrow;
    }
  }

  Future<void> ready(String id) async {
    try {
      _upsert([await _requireClient(ref).ready(id)]);
    } on AgentException catch (e) {
      if (e.isConflict || e.isNotFound) unawaited(refresh());
      rethrow;
    }
  }

  /// The customer receipt again.
  Future<void> reprint(String id) => _requireClient(ref).reprint(id);

  /// Every kitchen ticket of an accepted order again (no receipt).
  Future<KitchenResend> resendKitchen(String id) async {
    try {
      final r = await _requireClient(ref).resendKitchen(id);
      if (r.order != null) _upsert([r.order!]);
      return r;
    } on AgentException catch (e) {
      // not_accepted / unknown order: the screen is out of date.
      if (e.code == 'not_accepted' || (e.isNotFound && e.code != kKitchenUnsupported)) unawaited(refresh());
      rethrow;
    }
  }

  Future<void> assign(String driverId, List<String> orderIds) async {
    try {
      final out = await _requireClient(ref).assignDelivery(driverId: driverId, orderIds: orderIds);
      _upsert(out);
      // Flash the name now; the agent's `drivers.dispatched` echo of the same
      // send-out is recognised and doesn't flash again (and still flashes if
      // this tablet's SSE happens to be down).
      final driver = state.drivers.where((d) => d.id == driverId).firstOrNull;
      if (driver != null && out.isNotEmpty) {
        _set(state.withDispatch(DriverDispatch(driver: driver, orders: out), updateRoster: false));
      }
      unawaited(_reloadDrivers());
    } on AgentException catch (e) {
      if (!e.isNetwork) unawaited(refresh());
      rethrow;
    }
  }

  // --- driver pools (2.0.9) ---------------------------------------------------

  /// Puts [orderIds] in [driverId]'s pool (null = back to unassigned).
  /// Optimistic like [reorderDrivers]: the columns change at once, the Pi's
  /// answer replaces them, a refusal puts them back (and resyncs on a
  /// conflict — someone else moved or sent them).
  Future<void> poolOrders(List<String> orderIds, String? driverId) async {
    if (orderIds.isEmpty) return;
    final before = <StoredOrder>[
      for (final id in orderIds)
        if (state.orders[id] != null) state.orders[id]!,
    ];
    final now = timeNow().toUtc();
    _upsert([for (final o in before) o.copyWith(status: o.status.withPool(driverId, at: now))]);
    try {
      _upsert(await _requireClient(ref).poolOrders(orderIds, driverId: driverId));
    } on AgentException catch (e) {
      // Put back only what still shows our optimistic copy (an SSE frame
      // may have brought the truth already).
      _restore(before, (o) => o.status.poolDriverId == driverId);
      if (!e.isNetwork) unawaited(refresh());
      rethrow;
    } catch (_) {
      _restore(before, (o) => o.status.poolDriverId == driverId);
      rethrow;
    }
  }

  void _restore(List<StoredOrder> before, bool Function(StoredOrder current) stillOptimistic) {
    final back = [
      for (final o in before)
        if (state.orders[o.id] != null && stillOptimistic(state.orders[o.id]!)) o,
    ];
    if (back.isNotEmpty) _upsert(back);
  }

  /// Sends [driverId]'s pool (plus [includeOrderIds], AUTO's yellow stops)
  /// out now. Throws [NotReadyException] when something is cooking and
  /// [markReady] is false. Flashes the name like [assign].
  Future<List<StoredOrder>> sendOut(
    String driverId, {
    bool markReady = false,
    List<String>? includeOrderIds,
    List<String>? excludeOrderIds,
    String? planId,
  }) async {
    try {
      final out = await _requireClient(ref).sendOut(
        driverId,
        markReady: markReady,
        includeOrderIds: includeOrderIds,
        excludeOrderIds: excludeOrderIds,
        planId: planId,
      );
      _upsert(out);
      final driver = state.drivers.where((d) => d.id == driverId).firstOrNull;
      if (driver != null && out.isNotEmpty) {
        _set(state.withDispatch(DriverDispatch(driver: driver, orders: out), updateRoster: false));
      }
      unawaited(_reloadDrivers());
      return out;
    } on NotReadyException {
      rethrow;
    } on AgentException catch (e) {
      if (!e.isNetwork) unawaited(refresh());
      rethrow;
    }
  }

  /// The "hold the far one" check before a send-out (2.2.1); null from an
  /// older Pi. Changes nothing.
  Future<List<HeldStop>?> sendCheck(String driverId, List<String> orderIds) =>
      _requireClient(ref).sendCheck(driverId, orderIds);

  /// AUTO: a suggested set of runs. Changes nothing.
  Future<AutoPlan> autoPlan() => _requireClient(ref).autoPlan();

  /// Applies an AUTO suggestion (every stop still valid), then resyncs.
  /// [orderIds] limits it to those suggestions (an edited preview).
  Future<PlanConfirmResult> confirmPlan(String planId, {List<String>? orderIds}) async {
    try {
      return await _requireClient(ref).confirmPlan(planId, orderIds: orderIds);
    } finally {
      unawaited(refresh());
    }
  }

  Future<PoolTrip> poolTrip(String driverId, List<String> orderIds) =>
      _requireClient(ref).poolTrip(driverId, orderIds);

  /// Staff placed the address on the map; the route comes back later.
  Future<void> pinOrder(String orderId, double lat, double lng) => _requireClient(ref).pinOrder(orderId, lat, lng);

  /// Saves the AUTO settings and shows them at once.
  Future<DeliverySettings> setDeliverySettings(DeliverySettings s) async {
    final saved = await _requireClient(ref).setDeliverySettings(s);
    final f = state.floor;
    if (f != null) {
      _set(
        state.copyWith(
          floor: f.copyWith(
            soonReadyMinutes: saved.soonReadyMinutes,
            deliveryTargetMinutes: saved.deliveryTargetMinutes,
            nearbyRule: saved.nearbyRule,
            nearbyDetourMinutes: saved.nearbyDetourMinutes,
            nearbyDistanceMi: saved.nearbyDistanceMi,
            // An answer without it keeps what was sent.
            autoAssign: saved.autoAssign ?? s.autoAssign,
            store: saved.deliveryRadiusM == null || f.store == null
                ? null
                : StoreGeo(lat: f.store!.lat, lng: f.store!.lng, deliveryRadiusM: saved.deliveryRadiusM!),
          ),
        ),
      );
    }
    return saved;
  }

  /// NOT DELIVERED (1.7.1, Pi 2.2.1): the driver came back with [id]. A 409
  /// (not out / delivered any more) resyncs; an older Pi
  /// ([kNotDeliveredUnsupported]) hides the action until the Pi changes.
  Future<StoredOrder> notDelivered(String id, NotDeliveredAction action) async {
    try {
      final o = await _requireClient(ref).notDelivered(id, action);
      if (o.id.isNotEmpty) _upsert([o]);
      return o;
    } on AgentException catch (e) {
      if (e.code == kNotDeliveredUnsupported) ref.read(notDeliveredUnsupportedProvider.notifier).state = true;
      if (e.isConflict || e.code == 'not_found') unawaited(refresh());
      rethrow;
    }
  }

  /// A came-back delivery goes back to Unassigned. 409 `not_came_back` =
  /// someone already did: resync.
  Future<StoredOrder> releaseCameBack(String id) async {
    try {
      final o = await _requireClient(ref).releaseCameBack(id);
      if (o.id.isNotEmpty) _upsert([o]);
      return o;
    } on AgentException catch (e) {
      if (e.code == kNotDeliveredUnsupported) ref.read(notDeliveredUnsupportedProvider.notifier).state = true;
      if (e.isConflict || e.code == 'not_found') unawaited(refresh());
      rethrow;
    }
  }

  /// 409 `invalid_state` = the driver isn't out (already returned
  /// elsewhere): resync before the error reaches the UI.
  Future<void> driverReturned(String driverId) async {
    try {
      final r = await _requireClient(ref).driverReturned(driverId);
      _upsert(r.orders);
      ref.read(lastReturnProvider.notifier).state = LastReturn(driverId, timeNow());
      unawaited(_reloadDrivers());
      final a = r.autoAssigned;
      if (a != null) {
        // The pool itself arrives as order updates; fetch it now anyway.
        unawaited(refresh());
        _autoAssigned(a);
      }
    } on AgentException catch (e) {
      if (e.isConflict || e.isNotFound) unawaited(refresh());
      rethrow;
    }
  }

  /// Undo the latest "returned" (the driver is out again). Clears the undo
  /// slot either way.
  Future<Driver> undoReturn(String driverId) async {
    ref.read(lastReturnProvider.notifier).state = null;
    try {
      final d = await _requireClient(ref).undoReturn(driverId);
      return d;
    } finally {
      unawaited(_reloadDrivers());
    }
  }

  /// After an accept whose answer never came back (timeout / dropped
  /// connection) the agent may still have claimed the order: read it back.
  /// Returns the order as the agent has it, or null if that failed too.
  Future<StoredOrder?> recheck(String id) async {
    try {
      final o = await _requireClient(ref).getOrder(id);
      if (o.id.isNotEmpty) _upsert([o]);
      return o;
    } catch (_) {
      return null;
    }
  }

  Future<void> createDriver(String name, {String? posNumber, String? pushoverDevice}) async {
    await _requireClient(ref).createDriver(name, posNumber: posNumber, pushoverDevice: pushoverDevice);
    await _reloadDrivers();
  }

  /// Name, Driver # (SoftTouch Employee Number) and / or the phone's
  /// Pushover device name; '' clears either of the last two.
  Future<void> updateDriver(String id, {String? name, String? posNumber, String? pushoverDevice}) async {
    await _requireClient(ref).updateDriver(id, name: name, posNumber: posNumber, pushoverDevice: pushoverDevice);
    await _reloadDrivers();
  }

  /// Send test: a sample route to the driver's phone (Pi 2.3.7).
  Future<RouteTest> testRoute(String driverId) => _requireClient(ref).testRoute(driverId);

  Future<void> renameDriver(String id, String name) async {
    await _requireClient(ref).renameDriver(id, name);
    await _reloadDrivers();
  }

  /// 409 `driver_not_available` = they're out on a run (can't be removed).
  Future<void> removeDriver(String id) async {
    try {
      await _requireClient(ref).removeDriver(id);
    } finally {
      unawaited(_reloadDrivers());
    }
  }

  /// Clock in: joins the back of the queue. On a 409 (already clocked in
  /// elsewhere) the roster is reloaded before the error reaches the UI.
  Future<Driver> clockIn(String id) => _clock(id, (c) => c.clockIn(id), (d) => d);

  /// Clock out (only while available). 409 `driver_not_available` = out on a
  /// run (or already off). A Pi ≥ 2.3 prints the driver's report in the
  /// background ([ClockOutResult.reportPrinting]; SSE `driver.report_printed`).
  Future<ClockOutResult> clockOut(String id) => _clock(id, (c) => c.clockOut(id), (r) => r.driver);

  Future<T> _clock<T>(String id, Future<T> Function(AgentClient) op, Driver Function(T) driverOf) async {
    try {
      final r = await op(_requireClient(ref));
      final d = driverOf(r);
      final i = state.drivers.indexWhere((x) => x.id == id);
      if (i >= 0 && d.id == id) _set(state.copyWith(drivers: [...state.drivers]..[i] = d));
      return r;
    } finally {
      // The queue position changes on clock-in; resync either way.
      unawaited(_reloadDrivers());
    }
  }

  /// Prints one driver's report for the open batch so far (Pi 2.2.3; an
  /// older Pi throws [kDriverReportUnsupported]).
  Future<DriverReportPrint> printDriverReport(String driverId) =>
      _requireClient(ref).printDriverReport(driverId);

  /// Optimistic: the list reorders at once, then the agent confirms.
  Future<void> reorderDrivers(List<Driver> ordered) async {
    final before = state.drivers;
    _set(state.copyWith(drivers: ordered));
    try {
      await _requireClient(ref).reorderDrivers(ordered.map((d) => d.id).toList());
    } catch (_) {
      _set(state.copyWith(drivers: before));
      rethrow;
    } finally {
      unawaited(_reloadDrivers());
    }
  }

  /// Throws [BatchLeftoversException] unless [force].
  Future<CloseBatchResult> closeBatch({required bool force}) async {
    final r = await _requireClient(ref).closeBatch(force: force);
    await refresh();
    return r;
  }

  Future<void> _reloadDrivers() async {
    try {
      final ds = await _requireClient(ref).listDrivers();
      _set(state.copyWith(drivers: ds));
    } catch (_) {
      // The next SSE frame / poll will catch up.
    }
  }
}

final floorProvider = NotifierProvider<FloorController, FloorState>(FloorController.new);

/// The latest driver return made on this tablet — the driver button's
/// hold-to-undo target (the agent allows it for 10 minutes).
class LastReturn {
  final String driverId;
  final DateTime at;
  const LastReturn(this.driverId, this.at);

  static const window = Duration(minutes: 10);
  bool get undoable => timeNow().difference(at) < window;
}

final lastReturnProvider = StateProvider<LastReturn?>((_) => null);

/// A pending "pop the driver button open on NEXT" (2.2.1 auto-assign). The
/// driver button takes it (and clears it) when nothing is in the way — the
/// full-screen ring or a dialog / screen on top.
final fobPopProvider = StateProvider<AutoAssignment?>((_) => null);

/// The paired Pi answered NOT DELIVERED with "no such route" (≤ 2.2.0): the
/// action hides. Forgotten when the Pi (address / key) changes.
final notDeliveredUnsupportedProvider = StateProvider<bool>((ref) {
  ref.watch(_agentLinkProvider);
  return false;
});

// =============================================================================
// Alarm
// =============================================================================

/// Derives the alarm from the floor state (see AlarmRule). The sound and the
/// full-screen notification are driven by the ring bridge (core/ring_bridge.dart).
class AlarmNotifier extends Notifier<AlarmState> {
  @override
  AlarmState build() {
    final initial = ref.read(floorProvider);
    ref.listen<FloorState>(floorProvider, (prev, next) {
      var s = AlarmRule.onArrived(state, next.arrived.map((o) => o.id));
      if (prev != null && next.escalations > prev.escalations) s = AlarmRule.onEscalated(s);
      state = s;
    });
    return AlarmRule.onArrived(AlarmState.silent, initial.arrived.map((o) => o.id));
  }

  void hide() => state = AlarmRule.onHide(state);
  void show() => state = AlarmRule.onShow(state);
}

final alarmProvider = NotifierProvider<AlarmNotifier, AlarmState>(AlarmNotifier.new);

// =============================================================================
// Preferences
// =============================================================================

/// Theme mode, saved on the tablet (dark until someone picks another) —
/// toggled by the `q` logo on the nav rail, chosen in Settings.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => switch (ref.watch(storageProvider).themeMode) {
    'light' => ThemeMode.light,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark,
  };

  void set(ThemeMode mode) {
    super.state = mode;
    unawaited(ref.read(storageProvider).setThemeMode(mode.name));
  }

  /// Dark ↔ light (the nav-rail logo).
  void toggle() => set(state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);

  /// Public and saving, so `themeModeProvider.notifier.state = …` (as with
  /// the old StateProvider) keeps working.
  @override
  set state(ThemeMode value) => set(value);
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class AlertSoundNotifier extends Notifier<AlertSound> {
  @override
  AlertSound build() => AlertSound.byName(ref.watch(storageProvider).alertSound);

  void set(AlertSound s) {
    state = s;
    unawaited(ref.read(storageProvider).setAlertSound(s.name));
  }
}

final alertSoundProvider = NotifierProvider<AlertSoundNotifier, AlertSound>(AlertSoundNotifier.new);

// =============================================================================
// Read-only fetches for secondary screens
// =============================================================================

/// Polls `GET /api/printers` every 5 s while the Printers pane is mounted.
final printerStatusProvider = StreamProvider.autoDispose<List<PrinterStatus>>((ref) async* {
  final client = ref.watch(agentClientProvider);
  if (client == null) return;
  while (true) {
    try {
      yield await client.listPrinters();
    } catch (e, st) {
      yield* Stream<List<PrinterStatus>>.error(e, st);
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

/// `GET /api/batches` — open + kept closed batches, newest first.
final batchesProvider = FutureProvider.autoDispose<List<Batch>>((ref) async {
  final client = ref.watch(agentClientProvider);
  if (client == null) return const [];
  // Re-read when the open batch changes (a close).
  ref.watch(floorProvider.select((s) => s.currentBatchId));
  return client.listBatches();
});

/// `GET /api/drivers/shifts?days=7` — shift records, newest first. Re-read
/// whenever the roster changes (clock in / out, daily reset).
final driverShiftsProvider = FutureProvider.autoDispose<List<Shift>>((ref) async {
  final client = ref.watch(agentClientProvider);
  if (client == null) return const [];
  ref.watch(floorProvider.select((s) => s.drivers.map((d) => '${d.id}:${d.status.wire}:${d.clockedInAt}').join(',')));
  return client.listShifts(days: 7);
});

/// Orders of a past batch (`?batch=<id>`), newest first.
final batchOrdersProvider = FutureProvider.autoDispose.family<List<StoredOrder>, int>((ref, batchId) async {
  final client = ref.watch(agentClientProvider);
  if (client == null) return const [];
  return client.listAllOrders(batch: '$batchId');
});
