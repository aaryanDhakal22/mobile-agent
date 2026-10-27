import 'json.dart';
import 'models.dart';
import 'sse.dart';

/// Everything the floor screens render, held in one immutable value so the
/// SSE reducer ([applySseEvent]) is a pure function (and unit-testable).
class FloorState {
  final Floor? floor;

  /// Working set keyed by order id: the current batch + every arrived order.
  final Map<String, StoredOrder> orders;

  /// Driver roster in queue order (first = next up).
  final List<Driver> drivers;

  final SseStatus connection;

  /// True once the first full refresh landed.
  final bool loaded;

  /// Last refresh error (null after a good refresh).
  final String? error;
  final DateTime? lastSyncAt;

  /// Bumped on every `order.escalated` frame — the alarm listens for it.
  final int escalations;

  /// order id → seconds waiting, from the latest escalation frame.
  final Map<String, int> waitingSeconds;

  /// The latest driver send-out (SSE `drivers.dispatched`, or this tablet's
  /// own send-out) — the name flash shows it.
  final DriverDispatch? dispatch;

  /// Bumped once per distinct dispatch — the name flash listens for it.
  final int dispatches;

  /// Bumped once per new POS delivery that asked for the soft chime (SSE
  /// `order.added` with `chime:true`), and per auto-accepted order (2.2.0) —
  /// the ring bridge plays it.
  final int chimes;

  /// The latest SSE `integration.toast`, and a counter bumped per toast —
  /// the top-right toast host listens for it.
  final IntegrationToast? toast;
  final int toasts;

  /// The latest order the Pi's auto-accept took (2.2.0), and a counter bumped
  /// per one — the 3 s "auto-accepted" banner listens for it.
  final String? autoAccepted;
  final int autoAccepts;

  const FloorState({
    this.floor,
    this.orders = const {},
    this.drivers = const [],
    this.connection = SseStatus.connecting,
    this.loaded = false,
    this.error,
    this.lastSyncAt,
    this.escalations = 0,
    this.waitingSeconds = const {},
    this.dispatch,
    this.dispatches = 0,
    this.chimes = 0,
    this.toast,
    this.toasts = 0,
    this.autoAccepted,
    this.autoAccepts = 0,
  });

  FloorState copyWith({
    Floor? floor,
    Map<String, StoredOrder>? orders,
    List<Driver>? drivers,
    SseStatus? connection,
    bool? loaded,
    Object? error = _keep,
    DateTime? lastSyncAt,
    int? escalations,
    Map<String, int>? waitingSeconds,
    DriverDispatch? dispatch,
    int? dispatches,
    int? chimes,
    IntegrationToast? toast,
    int? toasts,
    String? autoAccepted,
    int? autoAccepts,
  }) {
    return FloorState(
      floor: floor ?? this.floor,
      orders: orders ?? this.orders,
      drivers: drivers ?? this.drivers,
      connection: connection ?? this.connection,
      loaded: loaded ?? this.loaded,
      error: identical(error, _keep) ? this.error : error as String?,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      escalations: escalations ?? this.escalations,
      waitingSeconds: waitingSeconds ?? this.waitingSeconds,
      dispatch: dispatch ?? this.dispatch,
      dispatches: dispatches ?? this.dispatches,
      chimes: chimes ?? this.chimes,
      toast: toast ?? this.toast,
      toasts: toasts ?? this.toasts,
      autoAccepted: autoAccepted ?? this.autoAccepted,
      autoAccepts: autoAccepts ?? this.autoAccepts,
    );
  }

  static const _keep = Object();

  // --- reducers --------------------------------------------------------------

  /// Inserts or replaces one order. An order that is no longer arrived drops
  /// its escalation counter.
  FloorState withOrder(StoredOrder o) => withOrders([o]);

  FloorState withOrders(Iterable<StoredOrder> list) {
    if (list.isEmpty) return this;
    final next = Map<String, StoredOrder>.of(orders);
    Map<String, int>? waits;
    for (final o in list) {
      if (o.id.isEmpty) continue;
      next[o.id] = o;
      if (o.state != OrderState.arrived && waitingSeconds.containsKey(o.id)) {
        waits ??= Map<String, int>.of(waitingSeconds);
        waits.remove(o.id);
      }
    }
    return copyWith(orders: next, waitingSeconds: waits);
  }

  /// A driver was sent out: upsert the run's orders and the driver, and flash
  /// the name — once per distinct dispatch (the same one seen again, e.g. the
  /// SSE echo of this tablet's own send-out, only refreshes the data).
  /// [updateRoster] is false for a locally built dispatch, whose driver is
  /// the pre-send-out copy.
  FloorState withDispatch(DriverDispatch d, {bool updateRoster = true}) {
    var next = withOrders(d.orders);
    final idx = (!updateRoster || d.driver.id.isEmpty) ? -1 : drivers.indexWhere((x) => x.id == d.driver.id);
    if (idx >= 0) {
      next = next.copyWith(drivers: [...drivers]..[idx] = d.driver);
    }
    if (dispatch?.key == d.key) return next;
    return next.copyWith(dispatch: d, dispatches: dispatches + 1);
  }

  /// Replaces the working set with a fresh fetch.
  FloorState withSnapshot({
    required Floor floor,
    required List<StoredOrder> current,
    required List<StoredOrder> arrived,
    required List<Driver> drivers,
    required DateTime at,
  }) {
    // 1.9.0: an order whose JSON didn't change keeps its old instance, so
    // the screens (selects, cards) see it as unchanged.
    StoredOrder keep(StoredOrder o) {
      final old = orders[o.id];
      return old != null && old.sig != null && old.sig == o.sig ? old : o;
    }

    final next = <String, StoredOrder>{};
    for (final o in current) {
      if (o.id.isNotEmpty) next[o.id] = keep(o);
    }
    for (final o in arrived) {
      if (o.id.isNotEmpty) next[o.id] = keep(o);
    }
    final waits = Map<String, int>.of(waitingSeconds)..removeWhere((id, _) => next[id]?.state != OrderState.arrived);
    return copyWith(
      floor: floor,
      orders: next,
      drivers: drivers,
      loaded: true,
      error: null,
      lastSyncAt: at,
      waitingSeconds: waits,
    );
  }

  // --- views -----------------------------------------------------------------

  /// We hold [id] in a state after `arrived` (accepted … delivered /
  /// cancelled). A late or repeated `order.arrived` / `order.escalated` for it
  /// is stale and must not flip it back (and ring) — except a scheduled
  /// future order coming back to ring again ([incoming] has `rerung`).
  bool isPastArrived(String id, {StoredOrder? incoming}) {
    final st = orders[id]?.state;
    if (st == OrderState.scheduled && incoming != null && incoming.status.rerung) return false;
    return st != null && st != OrderState.arrived && st != OrderState.unknown;
  }

  /// The floor settings (feature switches, ticket switches, default times).
  FloorSettings get settings => floor?.settings ?? const FloorSettings();

  int? get currentBatchId => floor?.batch.id;

  /// The orders the floor screens show: every order, or — with the POS
  /// pull-in switch off — every order except the POS ones (the Pi keeps
  /// them; they come back when the switch is on again).
  Iterable<StoredOrder> get _shown =>
      settings.features.posPull ? orders.values : orders.values.where((o) => !o.isPos);

  /// Terminal changes nobody OK'd yet (the blue CHANGED alert), oldest
  /// change first.
  List<StoredOrder> get pendingChanges => _sorted(
    _shown.where((o) => o.changePending),
    (o) => o.status.posChange?.at,
  );

  /// Awaiting acceptance, oldest first.
  List<StoredOrder> get arrived => _sorted(
    _shown.where((o) => o.state == OrderState.arrived),
    (o) => o.status.arrivalDate ?? o.order.receivedAt,
  );

  /// Cooking and shown on the Kitchen board: accepted, minus POS counter
  /// checks with nothing for the kitchen (`board_hidden`).
  static bool _onBoard(StoredOrder o) => o.state == OrderState.accepted && !o.status.boardHidden;

  /// In the kitchen, in kitchen-number order.
  List<StoredOrder> get kitchen {
    final list = _shown.where(_onBoard).toList();
    list.sort((a, b) {
      final ka = a.status.kitchenNumber, kb = b.status.kitchenNumber;
      if (ka != null && kb != null && ka != kb) return ka.compareTo(kb);
      return _cmpDate(a.status.acceptedAt, b.status.acceptedAt);
    });
    return list;
  }

  /// In the kitchen, most urgent first: the earliest promised ready time
  /// (late ones first), then kitchen number. Orders without an estimate go last.
  List<StoredOrder> get kitchenByUrgency {
    final list = _shown.where(_onBoard).toList();
    list.sort((a, b) {
      final ea = a.status.estimatedReadyAt, eb = b.status.estimatedReadyAt;
      if (ea != null && eb != null && ea != eb) return ea.compareTo(eb);
      if ((ea == null) != (eb == null)) return ea == null ? 1 : -1;
      final ka = a.status.kitchenNumber, kb = b.status.kitchenNumber;
      if (ka != null && kb != null && ka != kb) return ka.compareTo(kb);
      return _cmpDate(a.status.acceptedAt, b.status.acceptedAt);
    });
    return list;
  }

  /// Future orders waiting for their time (the greyed "Later" strip at the
  /// end of Kitchen), soonest ring first.
  List<StoredOrder> get later => _sorted(
    _shown.where((o) => o.state == OrderState.scheduled),
    (o) => o.status.ringAt ?? o.dueAt,
  );

  /// Ready delivery orders waiting for a driver, oldest-ready first.
  List<StoredOrder> get readyDeliveries =>
      _sorted(_shown.where((o) => o.state == OrderState.ready && o.isDelivery), (o) => o.status.readyAt);

  /// Deliveries waiting for a driver's pool (2.0.9): accepted (cooking) or
  /// ready, in nobody's pool, oldest placed first. An order still pooled to a
  /// driver who is no longer available (clocked out, out, removed — the Pi
  /// clears those, this covers the moment before it does) counts as
  /// unassigned too, so it never vanishes from both columns.
  List<StoredOrder> get unassignedDeliveries {
    final available = {for (final d in drivers) if (d.isAvailable) d.id};
    final list = _shown.where((o) {
      if (!o.isPoolable) return false;
      final pool = o.status.poolDriverId;
      return pool == null || !available.contains(pool);
    }).toList();
    // Oldest placed first; the same placed time → lower kitchen # first.
    list.sort((a, b) {
      final c = _cmpDate(a.placedTime, b.placedTime);
      return c != 0 ? c : _cmpKitchen(a, b);
    });
    return list;
  }

  /// Deliveries the driver brought back that wait to go out again (1.7.1):
  /// the Deliveries screen's "Came back" section, longest back first. They
  /// are in no other delivery list (not poolable, not out).
  List<StoredOrder> get cameBackDeliveries => _sorted(
    _shown.where((o) => o.isCameBack),
    (o) => o.status.notDelivered?.at ?? o.status.outAt ?? o.placedTime,
  );

  /// The deliveries in [driverId]'s pool in driving order (`pool_seq`, from
  /// the Pi), then kitchen number; unnumbered ones last.
  List<StoredOrder> poolFor(String driverId) {
    final list = _shown.where((o) => o.isPoolable && o.status.poolDriverId == driverId).toList();
    list.sort((a, b) {
      final sa = a.status.poolSeq, sb = b.status.poolSeq;
      if (sa != null && sb != null && sa != sb) return sa.compareTo(sb);
      if ((sa == null) != (sb == null)) return sa == null ? 1 : -1;
      return _cmpKitchen(a, b);
    });
    return list;
  }

  static int _cmpKitchen(StoredOrder a, StoredOrder b) {
    final ka = a.status.kitchenNumber ?? a.order.kitchenOrderNumber;
    final kb = b.status.kitchenNumber ?? b.order.kitchenOrderNumber;
    if (ka != null && kb != null && ka != kb) return ka.compareTo(kb);
    if ((ka == null) != (kb == null)) return ka == null ? 1 : -1;
    return a.id.compareTo(b.id);
  }

  /// Orders out with [driverId], oldest run first.
  List<StoredOrder> outWith(String driverId) => _sorted(
    _shown.where((o) => _isOut(o) && o.status.driverId == driverId),
    (o) => o.status.outAt,
  );

  /// Every order currently on delivery (incl. ones whose driver was removed).
  List<StoredOrder> get onDelivery => _sorted(_shown.where(_isOut), (o) => o.status.outAt);

  /// Out with a driver — a came-back order never is, whatever its state says.
  static bool _isOut(StoredOrder o) => o.state == OrderState.onDelivery && !o.status.cameBack;

  /// The current batch, newest first.
  List<StoredOrder> get currentBatchOrders {
    final id = currentBatchId;
    // An arrived order from an agent that doesn't stamp batch_id on the SSE
    // frame (0) still belongs to the open batch.
    final list = orders.values
        .where((o) => id == null || o.status.batchId == id || (o.status.batchId == 0 && o.state == OrderState.arrived))
        .toList();
    list.sort((a, b) => _cmpDate(b.status.arrivalDate, a.status.arrivalDate));
    return list;
  }

  List<Driver> get driversOut => drivers.where((d) => d.isOut).toList(growable: false);

  /// Drivers who can be sent out — clocked in and not on a run — in queue
  /// order (first = next up). Clocked-out (`off`) drivers never appear.
  List<Driver> get availableDrivers => drivers.where((d) => d.isAvailable).toList(growable: false);

  /// Clocked in (in the queue or out on a run).
  bool get anyDriverOnShift => drivers.any((d) => d.isOnShift);

  /// First available driver in queue order.
  Driver? get nextDriver {
    for (final d in drivers) {
      if (d.isAvailable) return d;
    }
    return null;
  }

  static List<StoredOrder> _sorted(Iterable<StoredOrder> src, DateTime? Function(StoredOrder) key) {
    final list = src.toList();
    list.sort((a, b) => _cmpDate(key(a), key(b)));
    return list;
  }

  static int _cmpDate(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }
}

/// Result of applying one SSE frame.
class FloorUpdate {
  final FloorState state;

  /// The frame implies more changed than it carries — refetch everything.
  final bool refetch;
  const FloorUpdate(this.state, {this.refetch = false});
}

/// Applies an agent SSE frame (contract/agent.md §2.4) to [s]. Unknown event
/// types and undecodable payloads leave the state unchanged.
FloorUpdate applySseEvent(FloorState s, SseEvent ev) {
  final payload = ev.json;
  switch (ev.event) {
    case 'order.arrived':
    case 'order.updated':
      if (payload is! Map) return FloorUpdate(s);
      final o = StoredOrder.fromJson(jMap(payload));
      if (o.id.isEmpty) return FloorUpdate(s);
      if (ev.event == 'order.arrived' && s.isPastArrived(o.id, incoming: o)) return FloorUpdate(s);
      final next = s.withOrder(o);
      // 2.2.0: auto-accepted by the Pi — new to this tablet (or it last saw
      // it waiting): the soft chime and the 3 s banner, never the ring.
      final before = s.orders[o.id];
      final fresh = before == null || before.state == OrderState.arrived;
      if (o.status.autoAccepted && o.state == OrderState.accepted && fresh) {
        return FloorUpdate(
          next.copyWith(chimes: s.chimes + 1, autoAccepted: o.id, autoAccepts: s.autoAccepts + 1),
        );
      }
      return FloorUpdate(next);
    case 'order.added': // 2.1.0: a POS order from the hub — never rings
      if (payload is! Map) return FloorUpdate(s);
      final m = jMap(payload);
      // `{order: StoredOrder, chime}` per the contract; a flat StoredOrder
      // with a `chime` extra (the order.arrived style) reads the same.
      final inner = jMap(m['order']);
      final o = StoredOrder.fromJson(inner['order'] is Map ? inner : m);
      if (o.id.isEmpty) return FloorUpdate(s);
      // The soft chime plays once per new order (not for a replayed frame) —
      // and once more for a hidden check that now qualifies for Kitchen
      // (Pi 2.3.0: it shows as new).
      final before = s.orders[o.id];
      final fresh = before == null || (before.status.boardHidden && !o.status.boardHidden);
      final chime = jBool(m['chime']) && fresh && !o.status.boardHidden;
      final next = s.withOrder(o);
      return FloorUpdate(chime ? next.copyWith(chimes: s.chimes + 1) : next);
    case 'order.changed': // Pi 2.3.0: a terminal change — `{order, change}`
      if (payload is! Map) return FloorUpdate(s);
      final o = StoredOrder.fromJson(jMap(jMap(payload)['order']));
      if (o.id.isEmpty) return FloorUpdate(s);
      return FloorUpdate(s.withOrder(o));
    case 'settings.updated':
      if (payload is! Map) return FloorUpdate(s, refetch: true);
      final floor = s.floor;
      if (floor == null) return FloorUpdate(s, refetch: true);
      return FloorUpdate(s.copyWith(floor: floor.copyWith(settings: FloorSettings.fromJson(jMap(payload)))));
    case 'integration.status':
      final st = IntegrationStatus.fromJson(payload);
      final floor = s.floor;
      if (st == null || floor == null) return FloorUpdate(s, refetch: st != null);
      return FloorUpdate(s.copyWith(floor: floor.copyWith(integration: st)));
    case 'integration.toast':
      final t = IntegrationToast.fromJson(payload);
      if (t == null) return FloorUpdate(s);
      return FloorUpdate(s.copyWith(toast: t, toasts: s.toasts + 1));
    case 'order.escalated':
      if (payload is! Map) return FloorUpdate(s);
      final m = jMap(payload);
      final o = StoredOrder.fromJson(m);
      if (o.id.isEmpty) return FloorUpdate(s);
      // A stale escalation for an order already taken must neither flip it
      // back nor make the alarm loud.
      if (s.isPastArrived(o.id, incoming: o)) return FloorUpdate(s);
      final next = s.withOrder(o);
      final waits = Map<String, int>.of(next.waitingSeconds);
      if (o.state == OrderState.arrived) waits[o.id] = jInt(m['waiting_seconds']);
      return FloorUpdate(next.copyWith(escalations: s.escalations + 1, waitingSeconds: waits));
    case 'drivers.updated':
      if (payload is! List) return FloorUpdate(s);
      return FloorUpdate(s.copyWith(drivers: jList(payload, Driver.fromJson)));
    case 'drivers.dispatched':
      if (payload is! Map) return FloorUpdate(s);
      final d = DriverDispatch.fromJson(jMap(payload));
      if (d.driver.id.isEmpty && d.driver.name.isEmpty) return FloorUpdate(s);
      return FloorUpdate(s.withDispatch(d));
    case 'floor.updated': // settings changed in the agent web UI
      return FloorUpdate(s, refetch: true);
    case 'batch.closed':
      if (payload is! Map) return FloorUpdate(s, refetch: true);
      final e = BatchClosedEvent.fromJson(jMap(payload));
      final floor = s.floor;
      final next = (floor != null && e.opened.id > 0) ? s.copyWith(floor: floor.copyWith(batch: e.opened)) : s;
      return FloorUpdate(next, refetch: true);
    default:
      return FloorUpdate(s);
  }
}

/// A list of orders compared instance by instance (1.9.0): with
/// [FloorState.withSnapshot] keeping unchanged orders, a `select` on it only
/// fires when an order on the list really changed, came or went.
class SameOrders {
  final List<StoredOrder> orders;
  const SameOrders(this.orders);

  @override
  bool operator ==(Object other) {
    if (other is! SameOrders || other.orders.length != orders.length) return false;
    for (var i = 0; i < orders.length; i++) {
      if (!identical(orders[i], other.orders[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(orders.map(identityHashCode));
}
