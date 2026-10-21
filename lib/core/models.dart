// Wire models for the agent's floor API (contract/agent.md §2.1, §2.4) and the
// canonical order snapshot inside it (contract/main.md §10.1). All parsing is
// defensive — see json.dart.

import 'json.dart';

// ---------------------------------------------------------------------------
// Order state
// ---------------------------------------------------------------------------

enum OrderState {
  arrived('arrived', 'ARRIVED'),
  accepted('accepted', 'IN KITCHEN'),
  ready('ready', 'READY'),
  onDelivery('on_delivery', 'OUT'),
  delivered('delivered', 'DELIVERED'),
  cancelled('cancelled', 'CANCELLED'),
  unknown('', 'UNKNOWN');

  final String wire;
  final String label;
  const OrderState(this.wire, this.label);

  static OrderState parse(Object? v) {
    final s = jStr(v);
    for (final st in values) {
      if (st != unknown && st.wire == s) return st;
    }
    // A missing/unknown state must not ring the alarm (as "arrived" would);
    // `unknown` keeps the order out of every working queue.
    return unknown;
  }
}

enum FulfillmentType {
  pickup('pickup', 'PICKUP'),
  delivery('delivery', 'DELIVERY'),
  dineIn('dine_in', 'DINE-IN'),
  unknown('', '');

  final String wire;
  final String label;
  const FulfillmentType(this.wire, this.label);

  static FulfillmentType parse(Object? v) {
    final s = jStr(v);
    for (final t in values) {
      if (t != unknown && t.wire == s) return t;
    }
    return unknown;
  }
}

// ---------------------------------------------------------------------------
// StoredOrder = { order: Snapshot, status: Status }
// ---------------------------------------------------------------------------

class StoredOrder {
  final OrderSnapshot order;
  final OrderStatus status;

  const StoredOrder({required this.order, required this.status});

  /// Also accepts the SSE `order.arrived` / `order.escalated` payloads, which
  /// are `{order, status, ...extras}` — the extras are ignored.
  factory StoredOrder.fromJson(Map<String, dynamic> json) => StoredOrder(
    order: OrderSnapshot.fromJson(jMap(json['order'])),
    status: OrderStatus.fromJson(jMap(json['status'])),
  );

  String get id => order.id;
  OrderState get state => status.state;
  bool get isDelivery => order.fulfillment.type == FulfillmentType.delivery;

  /// Done on the floor: delivered, or ready for a non-delivery order
  /// (mirrors the agent's StoredOrder.IsFinished).
  bool get isFinished =>
      state == OrderState.delivered || state == OrderState.cancelled || (state == OrderState.ready && !isDelivery);

  /// Big number for screens: kitchen number once accepted, else the vendor id.
  String get displayNumber {
    final k = status.kitchenNumber ?? order.kitchenOrderNumber;
    if (k != null) return '$k';
    return order.sourceEventId.isEmpty ? '—' : '#${order.sourceEventId}';
  }
}

class OrderStatus {
  final OrderState state;
  final DateTime? arrivalDate;
  final DateTime? printedDate;
  final int batchId;
  final int? kitchenNumber;
  final int? prepMinutes;
  final DateTime? estimatedReadyAt;
  final DateTime? acceptedAt;
  final DateTime? readyAt;
  final DateTime? outAt;
  final DateTime? deliveredAt;
  final DateTime? cancelledAt;
  final String? driverId;
  final String? driverName;

  const OrderStatus({
    required this.state,
    this.arrivalDate,
    this.printedDate,
    this.batchId = 0,
    this.kitchenNumber,
    this.prepMinutes,
    this.estimatedReadyAt,
    this.acceptedAt,
    this.readyAt,
    this.outAt,
    this.deliveredAt,
    this.cancelledAt,
    this.driverId,
    this.driverName,
  });

  factory OrderStatus.fromJson(Map<String, dynamic> json) => OrderStatus(
    state: OrderState.parse(json['state']),
    arrivalDate: jDate(json['arrival_date']),
    printedDate: jDate(json['printed_date']),
    batchId: jInt(json['batch_id']),
    kitchenNumber: jIntOrNull(json['kitchen_number']),
    prepMinutes: jIntOrNull(json['prep_minutes']),
    estimatedReadyAt: jDate(json['estimated_ready_at']),
    acceptedAt: jDate(json['accepted_at']),
    readyAt: jDate(json['ready_at']),
    outAt: jDate(json['out_at']),
    deliveredAt: jDate(json['delivered_at']),
    cancelledAt: jDate(json['cancelled_at']),
    driverId: jStrOrNull(json['driver_id']),
    driverName: jStrOrNull(json['driver_name']),
  );
}

class OrderSnapshot {
  final String id;
  final String source;
  final String sourceEventId;
  final String currency;
  final Money money;
  final Customer customer;
  final Fulfillment fulfillment;
  final List<LineItem> items;
  final List<Payment> payments;
  final String notes;
  final DateTime? placedAt;
  final DateTime? receivedAt;
  final Map<String, dynamic> sourceMetadata;

  // Floor fields main mirrors back (absent on a fresh order).
  final int? kitchenOrderNumber;

  const OrderSnapshot({
    required this.id,
    this.source = '',
    this.sourceEventId = '',
    this.currency = 'USD',
    this.money = const Money(),
    this.customer = const Customer(),
    this.fulfillment = const Fulfillment(),
    this.items = const [],
    this.payments = const [],
    this.notes = '',
    this.placedAt,
    this.receivedAt,
    this.sourceMetadata = const {},
    this.kitchenOrderNumber,
  });

  factory OrderSnapshot.fromJson(Map<String, dynamic> json) => OrderSnapshot(
    id: jStr(json['id']),
    source: jStr(json['source']),
    sourceEventId: jStr(json['source_event_id']),
    currency: jStr(json['currency'], 'USD'),
    money: Money.fromJson(jMap(json['money'])),
    customer: Customer.fromJson(jMap(json['customer'])),
    fulfillment: Fulfillment.fromJson(jMap(json['fulfillment'])),
    items: jList(json['items'], LineItem.fromJson),
    payments: jList(json['payments'], Payment.fromJson),
    notes: jStr(json['notes']),
    placedAt: jDate(json['placed_at']),
    receivedAt: jDate(json['received_at']),
    sourceMetadata: jMap(json['source_metadata']),
    kitchenOrderNumber: jIntOrNull(json['kitchen_order_number']),
  );

  String get customerName => customer.displayName.trim().isEmpty ? 'Guest' : customer.displayName.trim();

  /// Total item count (sum of top-level quantities).
  int get itemCount => items.fold(0, (n, i) => n + (i.quantity <= 0 ? 1 : i.quantity));

  bool get isPrepaid => payments.isNotEmpty;

  String get storeName => jStr(sourceMetadata['store_name']);
}

class Money {
  final int subtotalCents;
  final int taxCents;
  final int tipCents;
  final List<Fee> fees;
  final List<Discount> discounts;
  final int totalCents;

  const Money({
    this.subtotalCents = 0,
    this.taxCents = 0,
    this.tipCents = 0,
    this.fees = const [],
    this.discounts = const [],
    this.totalCents = 0,
  });

  factory Money.fromJson(Map<String, dynamic> json) => Money(
    subtotalCents: jInt(json['subtotal_cents']),
    taxCents: jInt(json['tax_cents']),
    tipCents: jInt(json['tip_cents']),
    fees: jList(json['fees'], Fee.fromJson),
    discounts: jList(json['discounts'], Discount.fromJson),
    totalCents: jInt(json['total_cents']),
  );
}

class Fee {
  final String type;
  final String label;
  final int amountCents;
  const Fee({this.type = '', this.label = '', this.amountCents = 0});
  factory Fee.fromJson(Map<String, dynamic> json) =>
      Fee(type: jStr(json['type']), label: jStr(json['label']), amountCents: jInt(json['amount_cents']));
}

class Discount {
  final String type;
  final String code;
  final String label;
  final int amountCents;
  const Discount({this.type = '', this.code = '', this.label = '', this.amountCents = 0});
  factory Discount.fromJson(Map<String, dynamic> json) => Discount(
    type: jStr(json['type']),
    code: jStr(json['code']),
    label: jStr(json['label']),
    amountCents: jInt(json['amount_cents']),
  );
}

class Customer {
  final String displayName;
  final String email;
  final String phone;
  const Customer({this.displayName = '', this.email = '', this.phone = ''});
  factory Customer.fromJson(Map<String, dynamic> json) =>
      Customer(displayName: jStr(json['display_name']), email: jStr(json['email']), phone: jStr(json['phone']));
}

class Fulfillment {
  final FulfillmentType type;
  final Address? address;
  final DateTime? promisedAt;
  final String tableId;

  const Fulfillment({this.type = FulfillmentType.unknown, this.address, this.promisedAt, this.tableId = ''});

  factory Fulfillment.fromJson(Map<String, dynamic> json) {
    final addr = json['address'];
    return Fulfillment(
      type: FulfillmentType.parse(json['type']),
      address: addr is Map ? Address.fromJson(jMap(addr)) : null,
      promisedAt: jDate(json['promised_at']),
      tableId: jStr(json['table_id']),
    );
  }
}

class Address {
  final String line1;
  final String line2;
  final String city;
  final String state;
  final String postalCode;
  final String country;
  final String notes;

  const Address({
    this.line1 = '',
    this.line2 = '',
    this.city = '',
    this.state = '',
    this.postalCode = '',
    this.country = '',
    this.notes = '',
  });

  factory Address.fromJson(Map<String, dynamic> json) => Address(
    line1: jStr(json['line1']),
    line2: jStr(json['line2']),
    city: jStr(json['city']),
    state: jStr(json['state']),
    postalCode: jStr(json['postal_code']),
    country: jStr(json['country']),
    notes: jStr(json['notes']),
  );

  /// "line1, line2" on the first line, "City, ST 12345" on the second.
  List<String> get lines {
    final first = [line1, line2].where((s) => s.trim().isNotEmpty).join(', ');
    final cityState = [city, state].where((s) => s.trim().isNotEmpty).join(', ');
    final second = [cityState, postalCode].where((s) => s.trim().isNotEmpty).join(' ');
    return [first, second].where((s) => s.isNotEmpty).toList(growable: false);
  }

  String get oneLine => lines.join(', ');
  bool get isEmpty => lines.isEmpty;
}

class LineItem {
  final String id;
  final int position;
  final String sku;
  final String name;
  final String size;
  final int quantity;
  final int unitPriceCents;
  final int lineTotalCents;
  final String notes;
  final List<LineItem> children;
  final String routing;
  final String printerId;

  const LineItem({
    this.id = '',
    this.position = 0,
    this.sku = '',
    required this.name,
    this.size = '',
    this.quantity = 1,
    this.unitPriceCents = 0,
    this.lineTotalCents = 0,
    this.notes = '',
    this.children = const [],
    this.routing = '',
    this.printerId = '',
  });

  factory LineItem.fromJson(Map<String, dynamic> json) => LineItem(
    id: jStr(json['id']),
    position: jInt(json['position']),
    sku: jStr(json['sku']),
    name: jStr(json['name']),
    size: jStr(json['size']),
    quantity: jInt(json['quantity'], 1),
    unitPriceCents: jInt(json['unit_price_cents']),
    lineTotalCents: jInt(json['line_total_cents']),
    notes: jStr(json['notes']),
    children: jList(json['children'], LineItem.fromJson),
    routing: jStr(json['routing']),
    printerId: jStr(json['printer_id']),
  );

  /// The size worth showing: the vendor sends "Serving" for single-size items
  /// (hidden) and "Serving (2 Piece)" for a fixed portion (shown as "2 Piece").
  String get displaySize {
    final s = size.trim();
    if (s.toLowerCase() == 'serving') return '';
    final m = RegExp(r'^serving\s*\((.+)\)$', caseSensitive: false).firstMatch(s);
    return m != null ? m.group(1)!.trim() : s;
  }
}

class Payment {
  final String method;
  final int amountCents;
  final String last4;
  const Payment({this.method = '', this.amountCents = 0, this.last4 = ''});
  factory Payment.fromJson(Map<String, dynamic> json) =>
      Payment(method: jStr(json['method']), amountCents: jInt(json['amount_cents']), last4: jStr(json['last4']));
}

// ---------------------------------------------------------------------------
// Floor: drivers, batches, the floor summary
// ---------------------------------------------------------------------------

/// `off` = clocked out (not in the queue), `available` = clocked in and in the
/// queue, `out` = on a delivery run.
enum DriverStatus {
  off('off', 'OFF'),
  available('available', 'AVAILABLE'),
  out('out', 'OUT');

  final String wire;
  final String label;
  const DriverStatus(this.wire, this.label);

  /// Older agents (no clock-in) only send `available` / `out`; anything
  /// missing or unknown reads as `available`, as it did before.
  static DriverStatus parse(Object? v) => switch (jStr(v)) {
    'out' => out,
    'off' => off,
    _ => available,
  };
}

class Driver {
  final String id;
  final String name;
  final int position;
  final DriverStatus status;

  /// When the current shift started (null while clocked out, or from an
  /// agent that predates clock-in). Keeps the queue order honest and feeds
  /// the shift report — not used for wages.
  final DateTime? clockedInAt;
  final DateTime? lastReturnedAt;
  final int deliveries;

  const Driver({
    required this.id,
    required this.name,
    this.position = 0,
    this.status = DriverStatus.available,
    this.clockedInAt,
    this.lastReturnedAt,
    this.deliveries = 0,
  });

  /// Clocked in and in the queue — can be sent out.
  bool get isAvailable => status == DriverStatus.available;
  bool get isOut => status == DriverStatus.out;
  bool get isOff => status == DriverStatus.off;

  /// Clocked in (in the queue or on a run).
  bool get isOnShift => !isOff;

  factory Driver.fromJson(Map<String, dynamic> json) => Driver(
    id: jStr(json['id']),
    name: jStr(json['name']),
    position: jInt(json['position']),
    status: DriverStatus.parse(json['status']),
    clockedInAt: jDate(json['clocked_in_at']),
    lastReturnedAt: jDate(json['last_returned_at']),
    deliveries: jInt(json['deliveries']),
  );
}

/// One clock-in → clock-out record (`GET /api/drivers/shifts`). For reports,
/// not wages.
class Shift {
  final String id;
  final String driverId;
  final String driverName;
  final int batchId;
  final DateTime? clockIn;

  /// Null while the shift is still open.
  final DateTime? clockOut;

  /// Closed by the daily reset rather than by staff.
  final bool autoOut;

  const Shift({
    required this.id,
    this.driverId = '',
    this.driverName = '',
    this.batchId = 0,
    this.clockIn,
    this.clockOut,
    this.autoOut = false,
  });

  bool get isOpen => clockOut == null;

  /// Length of the shift (to [now] while still open); null without a start.
  Duration? length(DateTime now) {
    final start = clockIn;
    if (start == null) return null;
    return (clockOut ?? now).difference(start);
  }

  factory Shift.fromJson(Map<String, dynamic> json) => Shift(
    id: jStr(json['id']),
    driverId: jStr(json['driver_id']),
    driverName: jStr(json['driver_name']),
    batchId: jInt(json['batch_id']),
    clockIn: jDate(json['clock_in']),
    clockOut: jDate(json['clock_out']),
    autoOut: jBool(json['auto_out']),
  );
}

/// SSE `drivers.dispatched` → `{driver, orders}`: a driver was sent out — the
/// tablet flashes their name full-screen.
class DriverDispatch {
  final Driver driver;
  final List<StoredOrder> orders;
  const DriverDispatch({required this.driver, this.orders = const []});

  factory DriverDispatch.fromJson(Map<String, dynamic> json) => DriverDispatch(
    driver: Driver.fromJson(jMap(json['driver'])),
    orders: jList(json['orders'], StoredOrder.fromJson),
  );

  /// Identifies one send-out (driver + its orders), so the same dispatch seen
  /// twice (the local send + its SSE echo, or a frame replayed after a
  /// refetch) flashes once.
  String get key {
    final ids = orders.map((o) => o.id).toList()..sort();
    return '${driver.id}|${ids.join(',')}';
  }

  /// Kitchen numbers (or vendor ids) of the run, for the flash.
  List<String> get numbers => orders.map((o) => o.displayNumber).toList(growable: false);
}

class Batch {
  final int id;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final int orderCount;

  const Batch({required this.id, this.openedAt, this.closedAt, this.orderCount = 0});

  bool get isOpen => closedAt == null;

  factory Batch.fromJson(Map<String, dynamic> json) => Batch(
    id: jInt(json['id']),
    openedAt: jDate(json['opened_at']),
    closedAt: jDate(json['closed_at']),
    orderCount: jInt(json['order_count']),
  );
}

/// Ticket lateness default (minutes green) when the agent doesn't say.
const int kDefaultGreenTillMinutes = 20;

/// Fallback quick picks if the agent sends none.
const List<int> kDefaultPrepChoices = [10, 15, 20, 30, 45, 60];

class Floor {
  final Batch batch;
  final int kitchenNext;
  final int lastPrepMinutes;
  final List<int> prepChoices;
  final int unsyncedEvents;

  /// Daily auto clock-out, location-local "HH:MM" (set in the agent web UI).
  /// Null from an agent that predates clock-in.
  final String? driverResetTime;

  /// Kitchen tickets stay green this long after the order arrived, then shade
  /// to fully red at twice it (agent web UI setting, default 20).
  final int greenTillMinutes;

  /// Taken off drivers' tips on the driver report (percent).
  final double tipTaxPercent;

  const Floor({
    required this.batch,
    this.kitchenNext = 0,
    this.lastPrepMinutes = 20,
    this.prepChoices = kDefaultPrepChoices,
    this.unsyncedEvents = 0,
    this.driverResetTime,
    this.greenTillMinutes = kDefaultGreenTillMinutes,
    this.tipTaxPercent = 6,
  });

  factory Floor.fromJson(Map<String, dynamic> json) {
    final raw = json['prep_choices'];
    final choices = raw is List
        ? raw.map(jIntOrNull).whereType<int>().where((m) => m > 0).toList(growable: false)
        : const <int>[];
    return Floor(
      batch: Batch.fromJson(jMap(json['batch'])),
      kitchenNext: jInt(json['kitchen_next']),
      lastPrepMinutes: jInt(json['last_prep_minutes']),
      prepChoices: choices.isEmpty ? kDefaultPrepChoices : choices,
      unsyncedEvents: jInt(json['unsynced_events']),
      driverResetTime: jStrOrNull(jStr(json['driver_reset_time']).trim()),
      greenTillMinutes: (jIntOrNull(json['green_till_minutes']) ?? 0) > 0
          ? jInt(json['green_till_minutes'])
          : kDefaultGreenTillMinutes,
      tipTaxPercent: (json['tip_tax_percent'] is num) ? (json['tip_tax_percent'] as num).toDouble() : 6,
    );
  }

  Floor copyWith({Batch? batch}) => Floor(
    batch: batch ?? this.batch,
    kitchenNext: kitchenNext,
    lastPrepMinutes: lastPrepMinutes,
    prepChoices: prepChoices,
    unsyncedEvents: unsyncedEvents,
    driverResetTime: driverResetTime,
    greenTillMinutes: greenTillMinutes,
    tipTaxPercent: tipTaxPercent,
  );

  /// The prep time to preselect at accept: last used, if it is one of the
  /// picks; otherwise the closest pick.
  int get defaultPrep {
    if (prepChoices.contains(lastPrepMinutes)) return lastPrepMinutes;
    if (lastPrepMinutes <= 0) return prepChoices.first;
    var best = prepChoices.first;
    for (final c in prepChoices) {
      if ((c - lastPrepMinutes).abs() < (best - lastPrepMinutes).abs()) best = c;
    }
    return best;
  }
}

/// `POST /api/batch/close` → 200 `{closed, auto_finished}`.
class CloseBatchResult {
  final Batch closed;
  final List<StoredOrder> autoFinished;
  const CloseBatchResult({required this.closed, this.autoFinished = const []});

  factory CloseBatchResult.fromJson(Map<String, dynamic> json) => CloseBatchResult(
    closed: Batch.fromJson(jMap(json['closed'])),
    autoFinished: jList(json['auto_finished'], StoredOrder.fromJson),
  );
}

/// SSE `batch.closed` → `{closed, opened}`.
class BatchClosedEvent {
  final Batch closed;
  final Batch opened;
  const BatchClosedEvent({required this.closed, required this.opened});

  factory BatchClosedEvent.fromJson(Map<String, dynamic> json) =>
      BatchClosedEvent(closed: Batch.fromJson(jMap(json['closed'])), opened: Batch.fromJson(jMap(json['opened'])));
}

/// `POST /api/pair` → 201 `{device_id, name, key}`.
class PairResult {
  final String deviceId;
  final String name;
  final String key;
  const PairResult({required this.deviceId, required this.name, required this.key});

  factory PairResult.fromJson(Map<String, dynamic> json) =>
      PairResult(deviceId: jStr(json['device_id']), name: jStr(json['name']), key: jStr(json['key']));
}

/// `GET /api/session` on an agent, as far as pairing cares.
class AgentProbe {
  /// unconfigured | needs_password | locked | ready
  final String state;
  final bool linkAvailable;

  /// Agent 2.0.1+ (empty on older Pis).
  final String storeName;
  final String version;
  final String hostname;

  /// unconfigured | connecting | connected | rejected — the Pi's stream to main.
  final String sseState;

  const AgentProbe({
    required this.state,
    required this.linkAvailable,
    this.storeName = '',
    this.version = '',
    this.hostname = '',
    this.sseState = '',
  });

  /// A new (or wiped) Pi waiting to be linked with the manager login.
  bool get isNew => state == 'unconfigured' && linkAvailable;

  factory AgentProbe.fromJson(Map<String, dynamic> json) => AgentProbe(
    state: jStr(json['state']),
    linkAvailable: json['link_available'] == true,
    storeName: jStr(json['store_name']),
    version: jStr(json['version']),
    hostname: jStr(json['hostname']),
    sseState: jStr(json['sse_state']),
  );
}

/// What `POST /api/setup/link` restored on the new Pi.
class LinkResult {
  final String tenant;
  final String deviceId;
  final String name;
  final String key;
  final int restoredOrders;
  final int waiting;
  final int drivers;
  final int? kitchenNext;
  const LinkResult({
    required this.tenant,
    required this.deviceId,
    required this.name,
    required this.key,
    this.restoredOrders = 0,
    this.waiting = 0,
    this.drivers = 0,
    this.kitchenNext,
  });

  factory LinkResult.fromJson(Map<String, dynamic> json) {
    final r = json['restored'] is Map ? jMap(json['restored']) : const <String, dynamic>{};
    return LinkResult(
      tenant: jStr(json['tenant']),
      deviceId: jStr(json['device_id']),
      name: jStr(json['device_name']),
      key: jStr(json['device_key']),
      restoredOrders: jInt(r['orders']),
      waiting: jInt(r['waiting']),
      drivers: jInt(r['drivers']),
      kitchenNext: r['kitchen_next'] == null ? null : jInt(r['kitchen_next']),
    );
  }
}

/// One delivery on a driver report.
class DriverReportLine {
  final String orderId;
  final int? kitchenNumber;
  final String customer; // "Erik D."
  final String address;
  final int tipCents;
  final bool cash;
  final int cashCents;
  final int totalCents;

  const DriverReportLine({
    required this.orderId,
    this.kitchenNumber,
    this.customer = '',
    this.address = '',
    this.tipCents = 0,
    this.cash = false,
    this.cashCents = 0,
    this.totalCents = 0,
  });

  factory DriverReportLine.fromJson(Map<String, dynamic> json) => DriverReportLine(
    orderId: jStr(json['order_id']),
    kitchenNumber: jIntOrNull(json['kitchen_number']),
    customer: jStr(json['customer']),
    address: jStr(json['address']),
    tipCents: jInt(json['tip_cents']),
    cash: json['cash'] == true,
    cashCents: jInt(json['cash_cents']),
    totalCents: jInt(json['total_cents']),
  );
}

/// A driver's slip for a batch: what they collected in cash, their tips after
/// tip tax and what they owe the store (negative = the store owes them).
class DriverReport {
  final int batchId;
  final String driverId;
  final String driverName;
  final List<DriverReportLine> lines;
  final int deliveries;
  final int cashCents;
  final int tipCents;
  final int tipAfterTaxCents;
  final int owedCents;

  const DriverReport({
    required this.batchId,
    required this.driverId,
    required this.driverName,
    this.lines = const [],
    this.deliveries = 0,
    this.cashCents = 0,
    this.tipCents = 0,
    this.tipAfterTaxCents = 0,
    this.owedCents = 0,
  });

  factory DriverReport.fromJson(Map<String, dynamic> json) => DriverReport(
    batchId: jInt(json['batch_id']),
    driverId: jStr(json['driver_id']),
    driverName: jStr(json['driver_name']),
    lines: jList(json['lines'], DriverReportLine.fromJson),
    deliveries: jInt(json['deliveries']),
    cashCents: jInt(json['cash_cents']),
    tipCents: jInt(json['tip_cents']),
    tipAfterTaxCents: jInt(json['tip_after_tax_cents']),
    owedCents: jInt(json['owed_cents']),
  );
}

/// `POST /api/batches/{id}/driver-reports/print` → `{printed, failed}`.
class ReportPrintResult {
  final List<String> printed;
  final List<String> failed;
  const ReportPrintResult({this.printed = const [], this.failed = const []});

  factory ReportPrintResult.fromJson(Map<String, dynamic> json) {
    List<String> names(Object? raw) =>
        raw is List ? raw.map((e) => e is Map ? jStr(jMap(e)['driver_name']) : '').toList(growable: false) : const [];
    return ReportPrintResult(printed: names(json['printed']), failed: names(json['failed']));
  }
}

/// A Quibase release the agent has cached for its tablets.
class AppRelease {
  final int versionCode;
  final String versionName;
  final String sha256;
  final int size;

  const AppRelease({required this.versionCode, this.versionName = '', this.sha256 = '', this.size = 0});

  factory AppRelease.fromJson(Map<String, dynamic> json) => AppRelease(
    versionCode: jInt(json['version_code']),
    versionName: jStr(json['version_name']),
    sha256: jStr(json['sha256']).toLowerCase(),
    size: jInt(json['size']),
  );
}
