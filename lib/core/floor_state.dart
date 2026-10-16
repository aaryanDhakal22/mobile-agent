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
    final next = <String, StoredOrder>{};
    for (final o in current) {
      if (o.id.isNotEmpty) next[o.id] = o;
    }
    for (final o in arrived) {
      if (o.id.isNotEmpty) next[o.id] = o;
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
  /// is stale and must not flip it back (and ring).
  bool isPastArrived(String id) {
    final st = orders[id]?.state;
    return st != null && st != OrderState.arrived && st != OrderState.unknown;
  }

  int? get currentBatchId => floor?.batch.id;

  /// Awaiting acceptance, oldest first.
  List<StoredOrder> get arrived => _sorted(
    orders.values.where((o) => o.state == OrderState.arrived),
    (o) => o.status.arrivalDate ?? o.order.receivedAt,
  );

  /// In the kitchen, in kitchen-number order.
  List<StoredOrder> get kitchen {
    final list = orders.values.where((o) => o.state == OrderState.accepted).toList();
    list.sort((a, b) {
      final ka = a.status.kitchenNumber, kb = b.status.kitchenNumber;
      if (ka != null && kb != null && ka != kb) return ka.compareTo(kb);
      return _cmpDate(a.status.acceptedAt, b.status.acceptedAt);
    });
    return list;
  }

  /// Ready delivery orders waiting for a driver, oldest-ready first.
  List<StoredOrder> get readyDeliveries =>
      _sorted(orders.values.where((o) => o.state == OrderState.ready && o.isDelivery), (o) => o.status.readyAt);

  /// Orders out with [driverId], oldest run first.
  List<StoredOrder> outWith(String driverId) => _sorted(
    orders.values.where((o) => o.state == OrderState.onDelivery && o.status.driverId == driverId),
    (o) => o.status.outAt,
  );

  /// Every order currently on delivery (incl. ones whose driver was removed).
  List<StoredOrder> get onDelivery =>
      _sorted(orders.values.where((o) => o.state == OrderState.onDelivery), (o) => o.status.outAt);

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
      if (ev.event == 'order.arrived' && s.isPastArrived(o.id)) return FloorUpdate(s);
      return FloorUpdate(s.withOrder(o));
    case 'order.escalated':
      if (payload is! Map) return FloorUpdate(s);
      final m = jMap(payload);
      final o = StoredOrder.fromJson(m);
      if (o.id.isEmpty) return FloorUpdate(s);
      // A stale escalation for an order already taken must neither flip it
      // back nor make the alarm loud.
      if (s.isPastArrived(o.id)) return FloorUpdate(s);
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
