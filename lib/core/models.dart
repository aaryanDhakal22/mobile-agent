// Wire models for the agent's floor API (contract/agent.md §2.1, §2.4) and the
// canonical order snapshot inside it (contract/main.md §10.1). All parsing is
// defensive — see json.dart.

import 'callout_models.dart';
import 'delivery_models.dart';
import 'json.dart';
import 'polyline.dart';
import 'time.dart';

export 'callout_models.dart';

// ---------------------------------------------------------------------------
// Order state
// ---------------------------------------------------------------------------

enum OrderState {
  arrived('arrived', 'ARRIVED'),

  /// A future order after its first confirm (1.5.0): greyed in the Kitchen
  /// "Later" strip until it rings again at `ring_at`. Nothing printed yet.
  scheduled('scheduled', 'LATER'),
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
// StoredOrder = { order: Snapshot, status: Status, geo?: OrderGeo }
// ---------------------------------------------------------------------------

class StoredOrder {
  final OrderSnapshot order;
  final OrderStatus status;

  /// Where the delivery address is and the drive from the store (2.0.9+);
  /// null until main has looked it up (or on an older Pi).
  final OrderGeo? geo;

  const StoredOrder({required this.order, required this.status, this.geo});

  /// Also accepts the SSE `order.arrived` / `order.escalated` payloads, which
  /// are `{order, status, ...extras}` — the extras are ignored.
  factory StoredOrder.fromJson(Map<String, dynamic> json) => StoredOrder(
    order: OrderSnapshot.fromJson(jMap(json['order'])),
    status: OrderStatus.fromJson(jMap(json['status'])),
    geo: json['geo'] is Map ? OrderGeo.fromJson(jMap(json['geo'])) : null,
  );

  StoredOrder copyWith({OrderStatus? status}) => StoredOrder(order: order, status: status ?? this.status, geo: geo);

  String get id => order.id;
  OrderState get state => status.state;
  bool get isDelivery => order.fulfillment.type == FulfillmentType.delivery;

  /// A delivery that can sit in a driver's pool: accepted (cooking) or ready
  /// — and not one that came back (1.7.1), which waits in "Came back" until
  /// staff send it to Unassigned.
  bool get isPoolable =>
      isDelivery && !status.cameBack && (state == OrderState.accepted || state == OrderState.ready);

  /// A delivery the driver brought back that staff chose to TRY AGAIN with
  /// (1.7.1, Pi 2.2.1): it waits in the Deliveries screen's "Came back"
  /// section — out of Unassigned, the pools, NEXT and AUTO — until someone
  /// holds it to send it to Unassigned.
  bool get isCameBack =>
      isDelivery && status.cameBack && state != OrderState.delivered && state != OrderState.cancelled;

  /// When the customer placed it (the clock the delivery target runs on);
  /// falls back to when it reached us for orders without a placed time.
  DateTime? get placedTime => order.placedAt ?? order.receivedAt ?? status.arrivalDate;

  /// Done on the floor: delivered, or ready for a non-delivery order
  /// (mirrors the agent's StoredOrder.IsFinished).
  bool get isFinished =>
      state == OrderState.delivered || state == OrderState.cancelled || (state == OrderState.ready && !isDelivery);

  /// Big number for screens: the plain POS check # for a SoftTouch order,
  /// the kitchen number once accepted, else the vendor id.
  String get displayNumber {
    final pos = status.displayNumber;
    if (pos != null) return '$pos';
    final k = status.kitchenNumber ?? order.kitchenOrderNumber;
    if (k != null) return '$k';
    return order.sourceEventId.isEmpty ? '—' : '#${order.sourceEventId}';
  }

  /// Pulled from the store's old POS (SoftTouch) by the hub (2.1.0).
  bool get isPos => status.extSource.isNotEmpty;

  /// Cash still to collect: a POS order's `cash_due_cents` (what the hub
  /// read off the check), else the online order's cash payments.
  int get cashDueCents {
    if (isPos) return status.cashDueCents ?? (status.paid ? 0 : order.money.totalCents);
    return order.cashDueCents;
  }

  /// Nothing to collect: settled (POS / an inserted cash pickup) or prepaid.
  bool get isPaid => status.paid || cashDueCents == 0;

  /// Earns the paid-not-ready wave on the Kitchen board (while cooking): a
  /// paid pickup (`paid`, or an online order with no cash due) or a shown
  /// POS counter (dine-in) order, which is paid up front.
  bool get paidNotReady {
    if (state != OrderState.accepted || status.boardHidden) return false;
    final type = order.fulfillment.type;
    if (type == FulfillmentType.pickup) return status.paid || (!isPos && order.cashDueCents == 0);
    return isPos && type == FulfillmentType.dineIn;
  }

  /// Since when the customer has been waiting on a paid, not-ready ticket
  /// (1.7.1): the later of settled ([OrderStatus.paidAt], when the Pi has
  /// it) and accepted — else since accepted / arrived.
  DateTime? get waitingSince {
    final paidAt = status.paidAt, accepted = status.acceptedAt ?? status.sentAt ?? status.arrivalDate;
    if (paidAt == null) return accepted;
    if (accepted == null) return paidAt;
    return paidAt.isAfter(accepted) ? paidAt : accepted;
  }

  /// A future order waiting for its lead time to be picked (first ring).
  bool get needsLead => state == OrderState.arrived && status.future && !status.rerung;

  /// When the customer wants it (future orders): the vendor's promised time.
  DateTime? get dueAt => order.fulfillment.promisedAt;

  /// A terminal change nobody OK'd yet (Pi 2.3.0): the blue CHANGED alert
  /// rings for it.
  bool get changePending => status.posChange?.pending ?? false;

  /// The ticket shows CHANGED (blue glow, tag): a pending change, or one OK'd
  /// less than [kChangedTagFor] ago while it still cooks.
  bool changedTag(DateTime now) {
    final c = status.posChange;
    if (c == null || state != OrderState.accepted) return false;
    final acked = c.ackedAt;
    return acked == null || now.difference(acked) < kChangedTagFor;
  }

  /// Done with (picked up): finished by the POS closing it or by the store's
  /// finish time (Pi 2.3.0).
  bool get isPickedUp => status.finishedAt != null;
}

/// How bad an integration problem / order flag is.
enum Severity {
  info('info'),
  warn('warn'),
  serious('serious');

  final String wire;
  const Severity(this.wire);

  /// Unknown values read as `warn`: shown, but not as a blocking banner.
  static Severity parse(Object? v) => switch (jStr(v)) {
    'info' => info,
    'serious' => serious,
    _ => warn,
  };
}

/// `status.flag` — e.g. "Settle manually: unmapped item X" on an online
/// order the hub could not insert into the POS.
class OrderFlag {
  final String text;
  final Severity severity;
  const OrderFlag({required this.text, this.severity = Severity.warn});

  static OrderFlag? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = jMap(raw);
    final text = jStr(m['text']).trim();
    if (text.isEmpty) return null;
    return OrderFlag(text: text, severity: Severity.parse(m['severity']));
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

  /// The driver whose pool this delivery sits in (2.0.9+): built up on the
  /// Deliveries screen before Send Out. Null = unassigned.
  final String? poolDriverId;
  final DateTime? pooledAt;

  /// Stop number in the pool's driving order (1..n); null when not pooled
  /// (or from an agent that doesn't number them).
  final int? poolSeq;

  // --- 2.1.0: POS (SoftTouch) orders, the hub, future orders ---------------

  /// `"softtouch"` on an order pulled from the POS; '' otherwise.
  final String extSource;

  /// The SoftTouch CHECKNUMBER.
  final String extRef;

  /// The POS check # (shown in place of the kitchen number).
  final int? displayNumber;

  /// Settled at the POS terminal (or an inserted online cash pickup settled).
  final bool paid;

  /// When it was settled, if the Pi says (`paid_at`) — the "customer
  /// waiting" clock on the Kitchen ticket (1.7.1).
  final DateTime? paidAt;

  /// What the driver collects (POS); the agent's figure for online orders.
  final int? cashDueCents;
  final int? tipCents;

  /// A POS counter check with no kitchen item: kept, never on Kitchen.
  final bool boardHidden;

  /// POS: when the cashier pressed Send.
  final DateTime? sentAt;

  /// Never synced to main (every POS order).
  final bool localOnly;
  final OrderFlag? flag;

  /// An online order the hub inserted into the POS: its check #.
  final int? posCheckNumber;

  /// "POS says #12 (not clocked in)".
  final String? posDriverNote;

  /// An online order for later (`fulfillment.promised_at` beyond its time).
  final bool future;

  /// The lead time picked at the first confirm.
  final int? scheduledLeadMinutes;

  /// promised_at − lead: when it rings again.
  final DateTime? ringAt;

  /// A scheduled order back in `arrived`: confirmed with no time dialog.
  final bool rerung;

  /// Accepted by the Pi's auto-accept (2.2.0), not by staff.
  final bool autoAccepted;

  /// 1.7.1 (Pi 2.2.1): the driver came back with it and staff picked TRY
  /// AGAIN — it waits in "Came back" until released to Unassigned.
  final bool cameBack;

  /// The latest NOT DELIVERED on it (retry or cancel), if any.
  final NotDelivered? notDelivered;

  /// Pi 2.3.0: finished (picked up) — `pos` = the POS closed the check,
  /// `auto` = an online pickup sat ready for the store's finish time.
  final DateTime? finishedAt;
  final String finishedBy;

  /// The POS closed (settled) the check.
  final bool posClosed;

  /// The last terminal change to this check (rings until OK).
  final PosChange? posChange;

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
    this.poolDriverId,
    this.pooledAt,
    this.poolSeq,
    this.extSource = '',
    this.extRef = '',
    this.displayNumber,
    this.paid = false,
    this.paidAt,
    this.cashDueCents,
    this.tipCents,
    this.boardHidden = false,
    this.sentAt,
    this.localOnly = false,
    this.flag,
    this.posCheckNumber,
    this.posDriverNote,
    this.future = false,
    this.scheduledLeadMinutes,
    this.ringAt,
    this.rerung = false,
    this.autoAccepted = false,
    this.cameBack = false,
    this.notDelivered,
    this.finishedAt,
    this.finishedBy = '',
    this.posClosed = false,
    this.posChange,
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
    poolDriverId: jStrOrNull(json['pool_driver_id']),
    pooledAt: jDate(json['pooled_at']),
    poolSeq: jIntOrNull(json['pool_seq']),
    extSource: jStr(json['ext_source']),
    extRef: jStr(json['ext_ref']),
    displayNumber: jIntOrNull(json['display_number']),
    paid: jBool(json['paid']),
    paidAt: jDate(json['paid_at']),
    cashDueCents: jIntOrNull(json['cash_due_cents']),
    tipCents: jIntOrNull(json['tip_cents']),
    boardHidden: jBool(json['board_hidden']),
    sentAt: jDate(json['sent_at']),
    localOnly: jBool(json['local_only']),
    flag: OrderFlag.fromJson(json['flag']),
    posCheckNumber: jIntOrNull(json['pos_check_number']),
    posDriverNote: jStrOrNull(jStr(json['pos_driver_note']).trim()),
    future: jBool(json['future']),
    scheduledLeadMinutes: jIntOrNull(json['scheduled_lead_minutes']),
    ringAt: jDate(json['ring_at']),
    rerung: jBool(json['rerung']),
    autoAccepted: jBool(json['auto_accepted']),
    cameBack: jBool(json['came_back']),
    notDelivered: NotDelivered.fromJson(json['not_delivered']),
    finishedAt: jDate(json['finished_at']),
    finishedBy: jStr(json['finished_by']),
    posClosed: jBool(json['pos_closed']),
    posChange: PosChange.fromJson(json['pos_change']),
  );

  /// The same status in [driverId]'s pool (null = unassigned) — the
  /// optimistic copy shown until the Pi answers.
  OrderStatus withPool(String? driverId, {DateTime? at}) => OrderStatus(
    state: state,
    arrivalDate: arrivalDate,
    printedDate: printedDate,
    batchId: batchId,
    kitchenNumber: kitchenNumber,
    prepMinutes: prepMinutes,
    estimatedReadyAt: estimatedReadyAt,
    acceptedAt: acceptedAt,
    readyAt: readyAt,
    outAt: outAt,
    deliveredAt: deliveredAt,
    cancelledAt: cancelledAt,
    driverId: this.driverId,
    driverName: driverName,
    poolDriverId: driverId,
    pooledAt: driverId == null ? null : (at ?? timeNow().toUtc()),
    // Unnumbered until the Pi answers: sorts after the numbered stops.
    poolSeq: driverId == poolDriverId ? poolSeq : null,
    extSource: extSource,
    extRef: extRef,
    displayNumber: displayNumber,
    paid: paid,
    paidAt: paidAt,
    cashDueCents: cashDueCents,
    tipCents: tipCents,
    boardHidden: boardHidden,
    sentAt: sentAt,
    localOnly: localOnly,
    flag: flag,
    posCheckNumber: posCheckNumber,
    posDriverNote: posDriverNote,
    future: future,
    scheduledLeadMinutes: scheduledLeadMinutes,
    ringAt: ringAt,
    rerung: rerung,
    autoAccepted: autoAccepted,
    cameBack: cameBack,
    notDelivered: notDelivered,
    finishedAt: finishedAt,
    finishedBy: finishedBy,
    posClosed: posClosed,
    posChange: posChange,
  );
}

/// What NOT DELIVERED does with a delivery the driver brought back.
enum NotDeliveredAction {
  /// Back on Deliveries, in "Came back".
  retry('retry'),

  /// Off the floor; History shows it cancelled.
  cancel('cancel');

  final String wire;
  const NotDeliveredAction(this.wire);

  static NotDeliveredAction? parse(Object? v) {
    final s = jStr(v);
    for (final a in values) {
      if (a.wire == s) return a;
    }
    return null;
  }
}

/// `status.not_delivered` (Pi 2.2.1): the driver came back with the order —
/// what staff chose, when, and whose run it was.
class NotDelivered {
  final NotDeliveredAction? action;
  final DateTime? at;
  final String? driverId;
  const NotDelivered({this.action, this.at, this.driverId});

  static NotDelivered? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = jMap(raw);
    return NotDelivered(
      action: NotDeliveredAction.parse(m['action']),
      at: jDate(m['at']),
      driverId: jStrOrNull(m['driver_id']),
    );
  }
}

// ---------------------------------------------------------------------------
// Delivery location (2.0.9): main geocodes the address and routes from the
// store, then pushes it to the Pi.
// ---------------------------------------------------------------------------

enum GeoState {
  located('located'),
  notFound('not_found'),

  /// Main gave up (never located) — staff can still drop a pin.
  unavailable('unavailable'),

  /// Main is still looking (the order arrived recently).
  pending('pending'),

  /// The address is ambiguous (2.1.0): staff pick one of the candidates or
  /// drop a pin.
  check('check');

  final String wire;
  const GeoState(this.wire);

  static GeoState parse(Object? v) => switch (jStr(v)) {
    'located' => located,
    'not_found' => notFound,
    'unavailable' => unavailable,
    'check' => check,
    _ => pending,
  };
}

/// One possible match for an ambiguous address (`geo.candidates`).
class GeoCandidate {
  /// The formatted address.
  final String label;
  final String line1;
  final String city;
  final String state;
  final String postalCode;
  final double? lat;
  final double? lng;

  const GeoCandidate({
    this.label = '',
    this.line1 = '',
    this.city = '',
    this.state = '',
    this.postalCode = '',
    this.lat,
    this.lng,
  });

  factory GeoCandidate.fromJson(Map<String, dynamic> json) => GeoCandidate(
    label: jStr(json['label']),
    line1: jStr(json['line1']),
    city: jStr(json['city']),
    state: jStr(json['state']),
    postalCode: jStr(json['postal_code']),
    lat: _jDouble(json['lat']),
    lng: _jDouble(json['lng']),
  );

  /// What staff read: the label, else the parts.
  String get title {
    if (label.trim().isNotEmpty) return label.trim();
    return Address(line1: line1, city: city, state: state, postalCode: postalCode).oneLine;
  }
}

class OrderGeo {
  final GeoState state;
  final double? lat;
  final double? lng;

  /// exact | approx | pinned ('' when not found).
  final String quality;

  /// Store → address driving distance (meters) and time (seconds); 0 when
  /// main had no route.
  final int distanceM;
  final int durationS;

  /// Store → address route, Google encoded polyline (precision 5); '' = none.
  final String polyline;

  /// Farther from the store than its delivery radius.
  final bool outsideArea;
  final DateTime? updatedAt;

  /// Up to 3 possible matches while [state] is `check`.
  final List<GeoCandidate> candidates;

  /// The address staff confirmed (set after a choose).
  final Address? confirmedAddress;

  /// Main located a different address than the one typed (a search or a
  /// choose fixed it; 1.7.2). Absent = false.
  final bool corrected;

  const OrderGeo({
    required this.state,
    this.lat,
    this.lng,
    this.quality = '',
    this.distanceM = 0,
    this.durationS = 0,
    this.polyline = '',
    this.outsideArea = false,
    this.updatedAt,
    this.candidates = const [],
    this.confirmedAddress,
    this.corrected = false,
  });

  factory OrderGeo.fromJson(Map<String, dynamic> json) => OrderGeo(
    state: GeoState.parse(json['state']),
    lat: _jDouble(json['lat']),
    lng: _jDouble(json['lng']),
    quality: jStr(json['quality']),
    distanceM: jInt(json['distance_m']),
    durationS: jInt(json['duration_s']),
    polyline: jStr(json['polyline']),
    outsideArea: jBool(json['outside_area']),
    updatedAt: jDate(json['updated_at']),
    candidates: jList(json['candidates'], GeoCandidate.fromJson).take(3).toList(growable: false),
    confirmedAddress: json['confirmed_address'] is Map ? Address.fromJson(jMap(json['confirmed_address'])) : null,
    corrected: jBool(json['corrected']),
  );

  /// Located with a usable point.
  bool get hasPoint => state == GeoState.located && lat != null && lng != null && !(lat == 0 && lng == 0);
  bool get isApprox => state == GeoState.located && quality == 'approx';

  /// The address is ambiguous: staff check it (a candidate or a pin).
  bool get needsCheck => state == GeoState.check;

  /// No usable point and main isn't looking any more (or the address needs a
  /// check): the map offers to drop a pin.
  bool get needsPin => state == GeoState.notFound || state == GeoState.unavailable || state == GeoState.check;
  bool get isPinned => quality == 'pinned';
  bool get hasDrive => distanceM > 0 || durationS > 0;
  GeoPoint? get point => hasPoint ? (lat: lat!, lng: lng!) : null;

  /// The decoded store → address route (empty without one).
  List<GeoPoint> get route => polyline.isEmpty ? const [] : decodePolyline(polyline);
}

double? _jDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
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

  /// POS orders (Pi 2.3.0): lines voided at the terminal after the check was
  /// on the tablet — struck through, red, REMOVED.
  final List<LineItem> removedItems;

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
    this.removedItems = const [],
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
    removedItems: jList(json['removed_items'], LineItem.fromJson),
  );

  String get customerName => customer.displayName.trim().isEmpty ? 'Guest' : customer.displayName.trim();

  /// Total item count (sum of top-level quantities).
  int get itemCount => items.fold(0, (n, i) => n + (i.quantity <= 0 ? 1 : i.quantity));

  /// Cash to collect from the customer: the sum of the `cash` payments (main
  /// sends cash owing as an explicit cash payment; a part-paid order has card
  /// + cash). An older order with no payments at all is cash for the whole
  /// total. `other` (third party / invoice) is prepaid, not cash. The agent
  /// uses the same rule, so the tablet and the printed receipt agree.
  int get cashDueCents {
    if (payments.isEmpty) return money.totalCents;
    return payments.where((p) => p.isCash).fold(0, (n, p) => n + p.amountCents);
  }

  bool get isPrepaid => cashDueCents == 0;

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

  /// POS orders (Pi 2.3.0): the POS line id, whether it goes to a kitchen
  /// station, and ADDED — rung at the terminal after the check was on the
  /// tablet.
  final String posRef;
  final bool kitchen;
  final bool added;

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
    this.posRef = '',
    this.kitchen = false,
    this.added = false,
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
    posRef: jStr(json['pos_ref']),
    kitchen: jBool(json['kitchen']),
    added: jBool(json['added']),
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

  /// Cash to collect (owing), not money already paid.
  bool get isCash => method.trim().toLowerCase() == 'cash';
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

  /// Their SoftTouch Employee Number (2.1.0) — the hub writes it on the POS checks
  /// of a run. Null when not set.
  final String? posNumber;

  /// While out (Pi 2.2.1): his run's order ids in stop order ([kDriverRunOrderField]).
  /// Empty from an older Pi — the screens keep the run's own order then.
  final List<String> runOrderIds;

  const Driver({
    required this.id,
    required this.name,
    this.position = 0,
    this.status = DriverStatus.available,
    this.clockedInAt,
    this.lastReturnedAt,
    this.deliveries = 0,
    this.posNumber,
    this.runOrderIds = const [],
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
    posNumber: jStrOrNull(jStr(json['pos_number']).trim()),
    runOrderIds: [
      if (json[kDriverRunOrderField] is List)
        for (final x in json[kDriverRunOrderField] as List)
          if (jStr(x).isNotEmpty) jStr(x),
    ],
  );
}

/// The driver field with an out driver's run in stop order (Pi 2.2.1).
const String kDriverRunOrderField = 'run_order_ids';

/// [stops] in [d]'s stop order (`run_order_ids`); stops the Pi didn't list
/// keep their order after the listed ones.
List<StoredOrder> inStopOrder(List<StoredOrder> stops, Driver? d) {
  final order = d?.runOrderIds ?? const <String>[];
  if (order.isEmpty || stops.length < 2) return stops;
  int rank(int i) {
    final r = order.indexOf(stops[i].id);
    return r < 0 ? order.length + i : r;
  }

  final idx = List<int>.generate(stops.length, (i) => i)..sort((a, b) => rank(a).compareTo(rank(b)));
  return [for (final i in idx) stops[i]];
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

/// The store's own spot on the map (2.0.9; null until main knows it).
class StoreGeo {
  final double lat;
  final double lng;

  /// Farther than this is "outside the delivery area" (default 5 mi).
  final int deliveryRadiusM;
  const StoreGeo({required this.lat, required this.lng, this.deliveryRadiusM = 8047});

  GeoPoint get point => (lat: lat, lng: lng);

  static StoreGeo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = jMap(raw);
    final lat = _jDouble(m['lat']), lng = _jDouble(m['lng']);
    if (lat == null || lng == null || (lat == 0 && lng == 0)) return null;
    return StoreGeo(lat: lat, lng: lng, deliveryRadiusM: jInt(m['delivery_radius_m'], 8047));
  }

  @override
  bool operator ==(Object other) =>
      other is StoreGeo && other.lat == lat && other.lng == lng && other.deliveryRadiusM == deliveryRadiusM;

  @override
  int get hashCode => Object.hash(lat, lng, deliveryRadiusM);
}

/// The offline map file the Pi serves (`/api/map.pmtiles`); null until one
/// is downloaded.
class MapInfo {
  final String version;

  /// Usually the Pi-relative "/api/map.pmtiles".
  final String url;

  /// [minLng, minLat, maxLng, maxLat] (empty if unknown).
  final List<double> bbox;
  const MapInfo({required this.version, required this.url, this.bbox = const []});

  static MapInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = jMap(raw);
    final url = jStr(m['url']).trim();
    if (url.isEmpty) return null;
    final b = m['bbox'];
    final bbox = b is List ? b.map(_jDouble).whereType<double>().toList(growable: false) : const <double>[];
    return MapInfo(version: jStr(m['version']), url: url, bbox: bbox.length == 4 ? bbox : const []);
  }

  @override
  bool operator ==(Object other) => other is MapInfo && other.version == version && other.url == url;

  @override
  int get hashCode => Object.hash(version, url);
}

// ---------------------------------------------------------------------------
// 2.1.0 settings on the Pi: feature toggles, kitchen-ticket toggles, default
// times — `GET/PUT /api/settings/{features,tickets,times}` and
// `/api/floor.settings`.
// ---------------------------------------------------------------------------

/// The six feature switches (Settings → Features). Defaults per the
/// contract; missing keys keep their default.
class FeatureToggles {
  /// The hub pulls POS orders onto the tablet.
  final bool posPull;

  /// Online cash pickups are inserted into the POS on accept.
  final bool orderInsert;
  final bool driverWriteback;
  final bool addressHeal;
  final bool futureOrders;

  /// The slow gradient sweep on paid tickets that aren't ready yet.
  final bool paidWave;

  const FeatureToggles({
    this.posPull = true,
    this.orderInsert = false,
    this.driverWriteback = true,
    this.addressHeal = true,
    this.futureOrders = true,
    this.paidWave = true,
  });

  factory FeatureToggles.fromJson(Map<String, dynamic> j) => FeatureToggles(
    posPull: jBool(j['pos_pull'], true),
    orderInsert: jBool(j['order_insert']),
    driverWriteback: jBool(j['driver_writeback'], true),
    addressHeal: jBool(j['address_heal'], true),
    futureOrders: jBool(j['future_orders'], true),
    paidWave: jBool(j['paid_wave'], true),
  );

  Map<String, bool> toJson() => {
    'pos_pull': posPull,
    'order_insert': orderInsert,
    'driver_writeback': driverWriteback,
    'address_heal': addressHeal,
    'future_orders': futureOrders,
    'paid_wave': paidWave,
  };

  /// A copy with the wire key [key] set to [on] (unknown keys are ignored).
  FeatureToggles withKey(String key, bool on) => FeatureToggles.fromJson({...toJson(), key: on});

  @override
  bool operator ==(Object other) => other is FeatureToggles && _mapEq(other.toJson(), toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);
}

/// The six kitchen station ticket switches (Settings → Kitchen tickets).
class TicketToggles {
  final bool posDelivery;
  final bool posTakeout;
  final bool posCounter;
  final bool onlineCashPickup;
  final bool onlineCashDelivery;
  final bool onlineCard;

  const TicketToggles({
    this.posDelivery = false,
    this.posTakeout = false,
    this.posCounter = false,
    this.onlineCashPickup = true,
    this.onlineCashDelivery = true,
    this.onlineCard = true,
  });

  factory TicketToggles.fromJson(Map<String, dynamic> j) => TicketToggles(
    posDelivery: jBool(j['pos_delivery']),
    posTakeout: jBool(j['pos_takeout']),
    posCounter: jBool(j['pos_counter']),
    onlineCashPickup: jBool(j['online_cash_pickup'], true),
    onlineCashDelivery: jBool(j['online_cash_delivery'], true),
    onlineCard: jBool(j['online_card'], true),
  );

  Map<String, bool> toJson() => {
    'pos_delivery': posDelivery,
    'pos_takeout': posTakeout,
    'pos_counter': posCounter,
    'online_cash_pickup': onlineCashPickup,
    'online_cash_delivery': onlineCashDelivery,
    'online_card': onlineCard,
  };

  TicketToggles withKey(String key, bool on) => TicketToggles.fromJson({...toJson(), key: on});

  @override
  bool operator ==(Object other) => other is TicketToggles && _mapEq(other.toJson(), toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);
}

bool _mapEq(Map<String, bool> a, Map<String, bool> b) => a.length == b.length && a.keys.every((k) => a[k] == b[k]);

/// The store's default times (X = pickup / dine-in, Y = delivery) that the
/// accept time picker starts from.
class DefaultTimes {
  static const int minMinutes = 1;
  static const int maxMinutes = 240;

  final int defaultPickupMinutes;
  final int defaultDeliveryMinutes;

  const DefaultTimes({this.defaultPickupMinutes = 15, this.defaultDeliveryMinutes = 35});

  factory DefaultTimes.fromJson(Map<String, dynamic> j) {
    int read(String k, int fallback) {
      final v = jIntOrNull(j[k]);
      return (v == null || v < minMinutes || v > maxMinutes) ? fallback : v;
    }

    return DefaultTimes(
      defaultPickupMinutes: read('default_pickup_minutes', 15),
      defaultDeliveryMinutes: read('default_delivery_minutes', 35),
    );
  }

  Map<String, int> toJson() => {
    'default_pickup_minutes': defaultPickupMinutes,
    'default_delivery_minutes': defaultDeliveryMinutes,
  };

  /// X for pickup / dine-in, Y for delivery.
  int forType(FulfillmentType t) => t == FulfillmentType.delivery ? defaultDeliveryMinutes : defaultPickupMinutes;

  @override
  bool operator ==(Object other) =>
      other is DefaultTimes &&
      other.defaultPickupMinutes == defaultPickupMinutes &&
      other.defaultDeliveryMinutes == defaultDeliveryMinutes;

  @override
  int get hashCode => Object.hash(defaultPickupMinutes, defaultDeliveryMinutes);
}

/// `/api/floor.settings` and SSE `settings.updated`.
class FloorSettings {
  final FeatureToggles features;
  final TicketToggles tickets;
  final DefaultTimes times;

  /// Pi 2.3.0 (defaults on an older Pi).
  final FinishingSettings finishing;
  final CalloutSettings callout;

  const FloorSettings({
    this.features = const FeatureToggles(),
    this.tickets = const TicketToggles(),
    this.times = const DefaultTimes(),
    this.finishing = const FinishingSettings(),
    this.callout = const CalloutSettings(),
  });

  factory FloorSettings.fromJson(Map<String, dynamic> j) => FloorSettings(
    features: FeatureToggles.fromJson(jMap(j['features'])),
    tickets: TicketToggles.fromJson(jMap(j['tickets'])),
    times: DefaultTimes.fromJson(jMap(j['times'])),
    finishing: FinishingSettings.fromJson(jMap(j['finishing'])),
    callout: CalloutSettings.fromJson(jMap(j['callout'])),
  );

  FloorSettings copyWith({
    FeatureToggles? features,
    TicketToggles? tickets,
    DefaultTimes? times,
    FinishingSettings? finishing,
    CalloutSettings? callout,
  }) => FloorSettings(
    features: features ?? this.features,
    tickets: tickets ?? this.tickets,
    times: times ?? this.times,
    finishing: finishing ?? this.finishing,
    callout: callout ?? this.callout,
  );
}

/// One problem the store hub reported (`integration.problems[]`).
class IntegrationProblem {
  final String code;
  final String text;
  final Severity severity;
  const IntegrationProblem({this.code = '', required this.text, this.severity = Severity.warn});

  factory IntegrationProblem.fromJson(Map<String, dynamic> j) =>
      IntegrationProblem(code: jStr(j['code']), text: jStr(j['text']).trim(), severity: Severity.parse(j['severity']));

  /// Identifies the problem for "show once" (code, else the text).
  String get key => code.isNotEmpty ? '$code|${severity.wire}' : '${text.toLowerCase()}|${severity.wire}';

  bool get isSerious => severity == Severity.serious;
}

/// The store hub's link to the Pi (`/api/floor.integration`, SSE
/// `integration.status`). Null on the floor when no hub was ever paired.
class IntegrationStatus {
  final bool connected;
  final bool ok;

  /// off | shadow | live — the hub's insert mode.
  final String insertMode;

  /// Online cash pickups are really being inserted into the POS now.
  final bool insertLive;
  final List<IntegrationProblem> problems;
  final DateTime? lastSeenAt;

  /// The hub's order callout report (Pi 2.3.0 + hub 0.2.0), else null.
  final CalloutHubReport? callout;

  const IntegrationStatus({
    this.connected = false,
    this.ok = false,
    this.insertMode = 'off',
    this.insertLive = false,
    this.problems = const [],
    this.lastSeenAt,
    this.callout,
  });

  static IntegrationStatus? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = jMap(raw);
    return IntegrationStatus(
      connected: jBool(j['connected']),
      ok: jBool(j['ok']),
      insertMode: jStr(j['insert_mode'], 'off'),
      insertLive: jBool(j['insert_live']),
      problems: jList(j['problems'], IntegrationProblem.fromJson).where((p) => p.text.isNotEmpty).toList(),
      lastSeenAt: jDate(j['last_seen_at']),
      callout: CalloutHubReport.fromJson(j['callout']),
    );
  }

  List<IntegrationProblem> get serious => problems.where((p) => p.isSerious).toList(growable: false);
  List<IntegrationProblem> get minor => problems.where((p) => !p.isSerious).toList(growable: false);
}

/// SSE `integration.toast` → `{text, severity, code?}`: a one-off message
/// from the Pi about the POS link (e.g. "POS says #12 — not clocked in").
class IntegrationToast {
  final String code;
  final String text;
  final Severity severity;
  const IntegrationToast({this.code = '', required this.text, this.severity = Severity.warn});

  static IntegrationToast? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = jMap(raw);
    final text = jStr(j['text'] ?? j['message']).trim();
    if (text.isEmpty) return null;
    return IntegrationToast(code: jStr(j['code']), text: text, severity: Severity.parse(j['severity']));
  }
}

/// Delivery settings defaults (agent settings table).
const int kDefaultSoonReadyMinutes = 5;
const int kDefaultDeliveryTargetMinutes = 45;

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

  /// AUTO also plans cooking deliveries due ready within this many minutes.
  final int soonReadyMinutes;

  /// Placed → door target for a delivery (minutes).
  final int deliveryTargetMinutes;

  /// The "nearby" rule (2.2.0; null from an older Pi, which has none).
  final NearbyRule? nearbyRule;
  final int nearbyDetourMinutes;
  final double nearbyDistanceMi;

  /// Simple auto-assign (2.2.1): a driver back or a delivery ready → the
  /// Pi pools up to 3 for the NEXT driver. Null from an older Pi.
  final bool? autoAssign;

  final StoreGeo? store;
  final MapInfo? map;

  /// Feature / kitchen-ticket switches and default times (2.1.0; defaults
  /// from an older Pi).
  final FloorSettings settings;

  /// The store hub's link (null when the Pi has none).
  final IntegrationStatus? integration;

  const Floor({
    required this.batch,
    this.kitchenNext = 0,
    this.lastPrepMinutes = 20,
    this.prepChoices = kDefaultPrepChoices,
    this.unsyncedEvents = 0,
    this.driverResetTime,
    this.greenTillMinutes = kDefaultGreenTillMinutes,
    this.tipTaxPercent = 6,
    this.soonReadyMinutes = kDefaultSoonReadyMinutes,
    this.deliveryTargetMinutes = kDefaultDeliveryTargetMinutes,
    this.nearbyRule,
    this.nearbyDetourMinutes = DeliverySettings.defaultDetour,
    this.nearbyDistanceMi = DeliverySettings.defaultDistanceMi,
    this.autoAssign,
    this.store,
    this.map,
    this.settings = const FloorSettings(),
    this.integration,
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
      soonReadyMinutes: jIntOrNull(json['soon_ready_minutes']) ?? kDefaultSoonReadyMinutes,
      deliveryTargetMinutes: (jIntOrNull(json['delivery_target_minutes']) ?? 0) > 0
          ? jInt(json['delivery_target_minutes'])
          : kDefaultDeliveryTargetMinutes,
      nearbyRule: NearbyRule.parse(json['nearby_rule']),
      nearbyDetourMinutes: jIntOrNull(json['nearby_detour_minutes']) ?? DeliverySettings.defaultDetour,
      nearbyDistanceMi: json['nearby_distance_mi'] is num
          ? (json['nearby_distance_mi'] as num).toDouble()
          : DeliverySettings.defaultDistanceMi,
      autoAssign: json['auto_assign'] is bool ? json['auto_assign'] as bool : null,
      store: StoreGeo.fromJson(json['store']),
      map: MapInfo.fromJson(json['map']),
      settings: FloorSettings.fromJson(jMap(json['settings'])),
      integration: IntegrationStatus.fromJson(json['integration']),
    );
  }

  Floor copyWith({
    Batch? batch,
    int? soonReadyMinutes,
    int? deliveryTargetMinutes,
    NearbyRule? nearbyRule,
    int? nearbyDetourMinutes,
    double? nearbyDistanceMi,
    bool? autoAssign,
    StoreGeo? store,
    FloorSettings? settings,
    IntegrationStatus? integration,
  }) => Floor(
    batch: batch ?? this.batch,
    kitchenNext: kitchenNext,
    lastPrepMinutes: lastPrepMinutes,
    prepChoices: prepChoices,
    unsyncedEvents: unsyncedEvents,
    driverResetTime: driverResetTime,
    greenTillMinutes: greenTillMinutes,
    tipTaxPercent: tipTaxPercent,
    soonReadyMinutes: soonReadyMinutes ?? this.soonReadyMinutes,
    deliveryTargetMinutes: deliveryTargetMinutes ?? this.deliveryTargetMinutes,
    nearbyRule: nearbyRule ?? this.nearbyRule,
    nearbyDetourMinutes: nearbyDetourMinutes ?? this.nearbyDetourMinutes,
    nearbyDistanceMi: nearbyDistanceMi ?? this.nearbyDistanceMi,
    autoAssign: autoAssign ?? this.autoAssign,
    store: store ?? this.store,
    map: map,
    settings: settings ?? this.settings,
    integration: integration ?? this.integration,
  );

  FeatureToggles get features => settings.features;
  DefaultTimes get times => settings.times;

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
  final String customer; // "Erik D." — never shown on the report preview
  final String address;
  final int tipCents;
  final bool cash;
  final int cashCents;
  final int totalCents;

  /// (Pi 2.3) House number + street only (no apt / city); '' from an older Pi.
  final String street;

  /// (Pi 2.3) The tip on the order (cash or card) and what the slip says in
  /// total (card = total + tip, cash = the total); null from an older Pi.
  final int? orderTipCents;
  final int? slipTotalCents;

  /// (Pi 2.2.3) The POS check behind the line, when the Pi cross-checked
  /// with the POS: its reference and check # (null = none).
  final String extRef;
  final int? displayNumber;

  /// Where the line came from (e.g. "online", "pos"); '' from an older Pi.
  final String source;

  /// Who had it: [DriverReportMatch.both], or only one side.
  final DriverReportMatch match;

  /// A short remark from the Pi, e.g. "POS only", "Quibase had Ali".
  final String note;
  final DateTime? outAt;
  final DateTime? deliveredAt;

  const DriverReportLine({
    required this.orderId,
    this.kitchenNumber,
    this.customer = '',
    this.address = '',
    this.tipCents = 0,
    this.cash = false,
    this.cashCents = 0,
    this.totalCents = 0,
    this.extRef = '',
    this.displayNumber,
    this.source = '',
    this.match = DriverReportMatch.both,
    this.note = '',
    this.outAt,
    this.deliveredAt,
    this.street = '',
    this.orderTipCents,
    this.slipTotalCents,
  });

  /// The number printed on the slip, without "#": the kitchen # for an
  /// online order, the POS check # for a POS one (whichever exists).
  int? get ticketNumber => source == 'pos' ? (displayNumber ?? kitchenNumber) : (kitchenNumber ?? displayNumber);

  /// The street the slip shows ([address] from an older Pi).
  String get streetOrAddress => street.isNotEmpty ? street : address;

  /// "Tip:" and "Total:" on the slip (an older Pi: [tipCents] / [totalCents]).
  int get slipTipCents => orderTipCents ?? tipCents;
  int get slipTotal => slipTotalCents ?? totalCents;

  factory DriverReportLine.fromJson(Map<String, dynamic> json) => DriverReportLine(
    orderId: jStr(json['order_id']),
    kitchenNumber: jIntOrNull(json['kitchen_number']),
    customer: jStr(json['customer']),
    address: jStr(json['address']),
    tipCents: jInt(json['tip_cents']),
    cash: json['cash'] == true,
    cashCents: jInt(json['cash_cents']),
    totalCents: jInt(json['total_cents']),
    extRef: jStr(json['ext_ref']),
    displayNumber: jIntOrNull(json['display_number']),
    source: jStr(json['source']),
    match: DriverReportMatch.parse(json['match']),
    note: jStr(json['note']).trim(),
    outAt: jDate(json['out_at']),
    deliveredAt: jDate(json['delivered_at']),
    street: jStr(json['street']).trim(),
    orderTipCents: jIntOrNull(json['order_tip_cents']),
    slipTotalCents: jIntOrNull(json['slip_total_cents']),
  );
}

/// Which side had a driver-report line (Pi 2.2.3 cross-checks with the POS).
enum DriverReportMatch {
  both,
  posOnly,
  quibaseOnly;

  /// Missing or unknown (an older Pi) reads as [both].
  static DriverReportMatch parse(Object? v) => switch (jStr(v)) {
    'pos_only' => posOnly,
    'quibase_only' => quibaseOnly,
    _ => both,
  };
}

/// Whether the Pi cross-checked a driver report with the POS (Pi 2.2.3;
/// absent when the store has no POS hub).
class DriverReportPos {
  final bool checked;
  final DateTime? asOf;
  final String note;
  const DriverReportPos({this.checked = false, this.asOf, this.note = ''});

  factory DriverReportPos.fromJson(Map<String, dynamic> json) =>
      DriverReportPos(checked: jBool(json['checked']), asOf: jDate(json['as_of']), note: jStr(json['note']).trim());
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

  /// [owedCents] rounded to whole dollars (what changes hands); a Pi that
  /// doesn't send `owed_rounded_cents` → [owedCents].
  final int owedRoundedCents;

  /// (Pi 2.2.3) The driver's POS Employee Number, the POS cross-check (null
  /// = no POS hub, or an older Pi) and the Pi's remarks.
  final String? driverPosNumber;
  final DriverReportPos? pos;
  final List<String> notes;

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
    int? owedRoundedCents,
    this.driverPosNumber,
    this.pos,
    this.notes = const [],
  }) : owedRoundedCents = owedRoundedCents ?? owedCents;

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
    owedRoundedCents: jIntOrNull(json['owed_rounded_cents']),
    driverPosNumber: jStrOrNull(jStr(json['driver_pos_number']).trim()),
    pos: json['pos'] is Map ? DriverReportPos.fromJson(jMap(json['pos'])) : null,
    notes: [
      if (json['notes'] is List)
        for (final n in json['notes'] as List)
          if (jStr(n).trim().isNotEmpty) jStr(n).trim(),
    ],
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

/// `POST /api/drivers/{id}/report/print` (Pi 2.2.3) — one driver's report
/// for the open batch so far, printed on the receipt printer.
class DriverReportPrint {
  final String driverId;
  final String driverName;

  /// The printer that printed it, and the one it failed over from (null
  /// unless it was rerouted).
  final String printedOn;
  final String? reroutedFrom;
  final DriverReport? report;

  const DriverReportPrint({
    this.driverId = '',
    this.driverName = '',
    this.printedOn = '',
    this.reroutedFrom,
    this.report,
  });

  factory DriverReportPrint.fromJson(Map<String, dynamic> json) => DriverReportPrint(
    driverId: jStr(json['driver_id']),
    driverName: jStr(json['driver_name']),
    printedOn: jStr(json['printed_on']),
    reroutedFrom: jStrOrNull(jStr(json['rerouted_from']).trim()),
    report: json['report'] is Map ? DriverReport.fromJson(jMap(json['report'])) : null,
  );
}

/// "Printed Juma's report" — plus where, when the Pi failed over from
/// [reroutedFrom] (" on Front (Kitchen was down)").
String driverReportPrintedMessage(String name, {String printedOn = '', String? reroutedFrom}) {
  final base = "Printed $name's report";
  if (reroutedFrom == null || reroutedFrom.isEmpty) return base;
  return printedOn.isEmpty ? '$base ($reroutedFrom was down)' : '$base on $printedOn ($reroutedFrom was down)';
}

/// SSE `driver.report_printed` (Pi 2.3): the report a clock-out printed in
/// the background — printed, or why not (`code` `nothing_printed` /
/// `report_failed`).
class DriverReportPrinted {
  final String driverId;
  final String driverName;
  final String trigger;
  final bool printed;
  final String printedOn;
  final String? reroutedFrom;
  final String error;
  final String? code;

  const DriverReportPrinted({
    this.driverId = '',
    this.driverName = '',
    this.trigger = '',
    required this.printed,
    this.printedOn = '',
    this.reroutedFrom,
    this.error = '',
    this.code,
  });

  static DriverReportPrinted? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = jMap(raw);
    return DriverReportPrinted(
      driverId: jStr(j['driver_id']),
      driverName: jStr(j['driver_name']).trim(),
      trigger: jStr(j['trigger']),
      printed: jBool(j['printed']),
      printedOn: jStr(j['printed_on']),
      reroutedFrom: jStrOrNull(jStr(j['rerouted_from']).trim()),
      error: jStr(j['error']).trim(),
      code: jStrOrNull(j['code']),
    );
  }

  /// The app-wide toast: "Printed Juma's report" (info), or "Juma's report
  /// didn't print — check the receipt printer" with the Pi's reason (red).
  IntegrationToast toToast() {
    final name = driverName.isEmpty ? 'The driver' : driverName;
    if (printed) {
      return IntegrationToast(
        code: 'driver.report_printed',
        text: driverReportPrintedMessage(name, printedOn: printedOn, reroutedFrom: reroutedFrom),
        severity: Severity.info,
      );
    }
    final who = driverName.isEmpty ? "The driver's" : "$driverName's";
    final short = error.length > 60 ? '${error.substring(0, 57)}...' : error;
    final why = short.isEmpty ? '' : ' ($short)';
    return IntegrationToast(
      code: 'driver.report_printed',
      text: "$who report didn't print — check the receipt printer$why",
      severity: Severity.serious,
    );
  }
}

/// `POST /api/drivers/{id}/clock-out`: the driver (as before) and whether a
/// Pi >= 2.3 is printing their report in the background (`report_printing`;
/// the outcome comes as SSE `driver.report_printed`).
class ClockOutResult {
  final Driver driver;
  final bool reportPrinting;
  const ClockOutResult(this.driver, {this.reportPrinting = false});

  factory ClockOutResult.fromJson(Map<String, dynamic> json) =>
      ClockOutResult(Driver.fromJson(json), reportPrinting: jBool(json['report_printing']));
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
