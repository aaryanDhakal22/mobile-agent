import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'app_version.dart';
import 'delivery_models.dart';
import 'diag_models.dart';
import 'json.dart';
import 'models.dart';
import 'printer_models.dart';
import 'receipt_models.dart';

/// Header carrying the paired tablet's key on every floor request.
const String kDeviceKeyHeader = 'X-Agent-Device-Key';

/// [kQuibaseVersionHeader] for [version] (none when it isn't known yet) —
/// merged into every request to the agent, the open pairing / setup calls
/// included (those pass [QuibaseVersion.current]).
Map<String, String> quibaseVersionHeaders(String? version) =>
    version == null || version.isEmpty ? const {} : {kQuibaseVersionHeader: version};

/// The agent's HTTP port when an address doesn't name one.
const int kAgentPort = 8080;

/// Turns what staff type ("192.168.1.219", "192.168.1.219:8080",
/// "http://pi.lan:8080/") into a base URL with a scheme, a port (8080 when a
/// plain-http address has none) and no trailing slash. Returns '' for blank
/// input.
String normalizeAgentAddress(String input) {
  var s = input.trim();
  if (s.isEmpty) return '';
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  final u = Uri.tryParse(s);
  if (u != null && u.scheme == 'http' && u.host.isNotEmpty && !u.hasPort && u.path.isEmpty) {
    s = '$s:$kAgentPort';
  }
  return s;
}

/// [AgentException.code] for a receipt-settings route an older Pi doesn't
/// have (it answers 404 / 405): "This Pi needs an update for receipt
/// settings".
const String kReceiptUnsupported = 'receipt_unsupported';

/// [AgentException.code] for `POST /api/orders/{id}/kitchen` on an older Pi
/// that doesn't have the route (2.0.8+): "This Pi needs an update to resend
/// to the kitchen".
const String kKitchenUnsupported = 'kitchen_unsupported';

/// What `POST /api/orders/{id}/kitchen` printed: the station (printer) names
/// that printed, the ones that failed, and the ones a failover covered.
class KitchenResend {
  final StoredOrder? order;
  final List<String> printed;
  final List<String> failed;
  final List<String> rerouted;
  const KitchenResend({this.order, this.printed = const [], this.failed = const [], this.rerouted = const []});

  static List<String> _names(Object? v) => v is List
      ? [
          for (final x in v)
            if (x is String && x.trim().isNotEmpty)
              x.trim()
            else if (x is Map && jStr(x['name'] ?? x['printer'] ?? x['station']).isNotEmpty)
              jStr(x['name'] ?? x['printer'] ?? x['station']),
        ]
      : const [];

  factory KitchenResend.fromJson(Map<String, dynamic> json) => KitchenResend(
    order: json['order'] is Map ? StoredOrder.fromJson(jMap(json['order'])) : null,
    printed: _names(json['printed']),
    failed: _names(json['failed']),
    rerouted: _names(json['rerouted']),
  );
}

/// [AgentException.code] for a 2.1.0 route an older Pi doesn't have
/// (features / kitchen tickets / default times, schedule, geo choose): "This
/// Pi needs an update".
const String kSettingsUnsupported = 'settings_unsupported';

/// [AgentException.code] when adding a printer: the store already has a
/// printer with that name (409).
const String kPrinterNameTaken = 'name_taken';

/// [AgentException.code] when the Pi can't reach main to add a printer (503).
const String kMainOffline = 'main_offline';

/// A non-2xx answer from the agent. Error bodies are `{"error", "code"?}`;
/// `body` keeps the whole decoded map (e.g. `leftovers` on a 409).
class AgentException implements Exception {
  final int? statusCode;
  final String? code;
  final String message;
  final Map<String, dynamic> body;

  /// For a network failure: what went wrong underneath (timeout, refused…),
  /// kept for the "details" view and the diagnostics log.
  final Object? cause;

  const AgentException(this.message, {this.statusCode, this.code, this.body = const {}, this.cause});

  /// No answer in time (as opposed to refused / unreachable).
  bool get isTimeout => statusCode == null && cause is TimeoutException;

  /// The tablet's key was revoked (or never valid): re-pair.
  bool get isDeviceRevoked => statusCode == 401 && code == 'device_required';
  bool get isPrinterFailure => statusCode == 502;
  bool get isConflict => statusCode == 409;
  bool get isNotFound => statusCode == 404;

  /// The agent doesn't have this route (an older Pi): a GET falls to the web
  /// UI's `/api/*` 404, a PUT / POST to the mux's 405. A real 404
  /// `not_configured` (unknown printer) is not that.
  bool get isMissingRoute => (statusCode == 404 && code != 'not_configured') || statusCode == 405;
  bool get isNetwork => statusCode == null;

  @override
  String toString() => statusCode == null ? message : 'HTTP $statusCode: $message';
}

/// [AgentException.code] for a pool / send-out / AUTO / map route an older
/// Pi doesn't have: "This Pi needs an update for driver pools".
const String kPoolsUnsupported = 'pools_unsupported';

/// [AgentException.code] when AUTO finds no available driver (409).
const String kNoDrivers = 'no_drivers';

/// Send Out was refused: these orders aren't marked ready (409 `not_ready`).
/// Ask "send anyway?" and retry with `markReady`.
class NotReadyException extends AgentException {
  final List<String> orderIds;
  NotReadyException(super.message, {required this.orderIds, super.body}) : super(statusCode: 409, code: 'not_ready');
}

/// Close-batch was refused because unfinished orders remain.
class BatchLeftoversException extends AgentException {
  final List<StoredOrder> leftovers;
  BatchLeftoversException(super.message, {required this.leftovers, super.body})
    : super(statusCode: 409, code: 'batch_has_leftovers');
}

/// HTTP client for the agent's floor API (contract/agent.md §2).
class AgentClient {
  final String baseUrl;
  final String deviceKey;
  final http.Client _client;
  final Duration timeout;

  /// Time allowed for calls that print (accept / reprint): the agent writes
  /// every station ticket and may fail over between printers.
  final Duration printTimeout;

  /// Called when any request comes back 401 `device_required`.
  final void Function()? onDeviceRevoked;

  /// This tablet's Quibase version for [kQuibaseVersionHeader] (null =
  /// not known yet: the header is left off). Defaults to [QuibaseVersion].
  final String? Function() appVersion;

  AgentClient({
    required String baseUrl,
    required this.deviceKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
    this.printTimeout = const Duration(seconds: 60),
    this.onDeviceRevoked,
    String? Function()? appVersion,
  }) : baseUrl = normalizeAgentAddress(baseUrl),
       _client = client ?? http.Client(),
       appVersion = appVersion ?? _installedVersion;

  static String? _installedVersion() => QuibaseVersion.current;

  Uri uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('$baseUrl$path');
    return query == null ? u : u.replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
    kDeviceKeyHeader: deviceKey,
    'Accept': 'application/json',
    ...quibaseVersionHeaders(appVersion()),
  };

  Map<String, String> get _jsonHeaders => {..._headers, 'Content-Type': 'application/json'};

  // --- pairing (no key yet) --------------------------------------------------

  /// `POST /api/pair {code, name}` → the device key (shown once).
  static Future<PairResult> pair({
    required String address,
    required String code,
    required String name,
    http.Client? client,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final c = client ?? http.Client();
    try {
      final resp = await c
          .post(
            Uri.parse('${normalizeAgentAddress(address)}/api/pair'),
            headers: {'Content-Type': 'application/json', ...quibaseVersionHeaders(QuibaseVersion.current)},
            body: jsonEncode({'code': code.trim(), 'name': name.trim()}),
          )
          .timeout(timeout);
      _check(resp);
      final r = PairResult.fromJson(jMap(jsonDecode(resp.body)));
      if (r.key.isEmpty) throw const AgentException('Agent did not return a device key');
      return r;
    } on AgentException {
      rethrow;
    } catch (e) {
      throw AgentException(_networkMessage(e), cause: e);
    } finally {
      if (client == null) c.close();
    }
  }

  /// `GET /api/session` (open) — is the Pi at [address] new (unconfigured)?
  static Future<AgentProbe> probe({
    required String address,
    http.Client? client,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final c = client ?? http.Client();
    try {
      final resp = await c
          .get(
            Uri.parse('${normalizeAgentAddress(address)}/api/session'),
            headers: quibaseVersionHeaders(QuibaseVersion.current),
          )
          .timeout(timeout);
      _check(resp);
      return AgentProbe.fromJson(jMap(jsonDecode(resp.body)));
    } on AgentException {
      rethrow;
    } catch (e) {
      throw AgentException(_networkMessage(e), cause: e);
    } finally {
      if (client == null) c.close();
    }
  }

  /// `GET /api/version` (open) — answers when [address] is a Quicc agent
  /// (any version). Used by discovery's subnet sweep.
  static Future<String?> version({
    required String address,
    required http.Client client,
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    try {
      final resp = await client
          .get(
            Uri.parse('${normalizeAgentAddress(address)}/api/version'),
            headers: quibaseVersionHeaders(QuibaseVersion.current),
          )
          .timeout(timeout);
      if (resp.statusCode != 200) return null;
      final m = jMap(jsonDecode(resp.body));
      return jStr(m['service']) == 'quicc-agent' ? jStr(m['version']) : null;
    } catch (_) {
      return null;
    }
  }

  /// `POST /api/setup/link {username, password, tablet_name}` — links a new
  /// Pi with the store manager login; the agent restores the open batch from
  /// main and pairs this tablet in the same call.
  static Future<LinkResult> link({
    required String address,
    required String username,
    required String password,
    required String tabletName,
    http.Client? client,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final c = client ?? http.Client();
    try {
      final resp = await c
          .post(
            Uri.parse('${normalizeAgentAddress(address)}/api/setup/link'),
            headers: {'Content-Type': 'application/json', ...quibaseVersionHeaders(QuibaseVersion.current)},
            body: jsonEncode({'username': username.trim(), 'password': password, 'tablet_name': tabletName.trim()}),
          )
          .timeout(timeout);
      _check(resp);
      final r = LinkResult.fromJson(jMap(jsonDecode(resp.body)));
      if (r.key.isEmpty) throw const AgentException('The Pi linked but did not pair this tablet — pair it with a code');
      return r;
    } on AgentException {
      rethrow;
    } catch (e) {
      throw AgentException(_networkMessage(e), cause: e);
    } finally {
      if (client == null) c.close();
    }
  }

  // --- floor -----------------------------------------------------------------

  Future<Floor> getFloor() async => Floor.fromJson(jMap(await _get('/api/floor')));

  /// `batch`: 'current' | 'all' | a batch id.
  Future<List<StoredOrder>> listOrders({String batch = 'current', int offset = 0, int limit = 200}) async {
    final body = await _get('/api/orders', {'batch': batch, 'offset': '$offset', 'limit': '$limit'});
    return jList(body, StoredOrder.fromJson);
  }

  /// Every order of [batch], paging `limit=`[pageSize] by offset until a
  /// short page comes back (or [cap] orders) — a busy batch can exceed one
  /// page, and its oldest unfinished orders must not drop off the screens.
  /// Orders landing mid-paging can shift a row into the next page; callers
  /// key by id, so a duplicate is harmless.
  Future<List<StoredOrder>> listAllOrders({String batch = 'current', int pageSize = 200, int cap = 2000}) async {
    final all = <StoredOrder>[];
    var offset = 0;
    while (all.length < cap) {
      final page = await listOrders(batch: batch, offset: offset, limit: pageSize);
      all.addAll(page);
      if (page.length < pageSize) break;
      offset += page.length;
    }
    return all.length > cap ? all.sublist(0, cap) : all;
  }

  Future<List<StoredOrder>> listArrived() async => jList(await _get('/api/orders/arrived'), StoredOrder.fromJson);

  Future<StoredOrder> getOrder(String id) async =>
      StoredOrder.fromJson(jMap(await _get('/api/orders/${Uri.encodeComponent(id)}')));

  /// Claims + prints. 502 = nothing printed (order stays arrived); 409 = taken.
  Future<StoredOrder> accept(String id, {int? prepMinutes}) async {
    final body = await _send(
      'POST',
      '/api/orders/${Uri.encodeComponent(id)}/accept',
      body: prepMinutes == null ? null : {'prep_minutes': prepMinutes},
      timeout: printTimeout,
    );
    return StoredOrder.fromJson(jMap(body));
  }

  /// `POST /api/orders/{id}/schedule {lead_minutes}` — the first confirm of
  /// a future order (nothing prints; it waits in the Later strip), or a new
  /// lead for one already scheduled. 409 when the order isn't a future one.
  Future<StoredOrder?> schedule(String id, int leadMinutes) => _v210Route(() async {
    final body = await _send(
      'POST',
      '/api/orders/${Uri.encodeComponent(id)}/schedule',
      body: {'lead_minutes': leadMinutes},
    );
    return body is Map ? StoredOrder.fromJson(jMap(body)) : null;
  });

  /// `POST /api/orders/{id}/geo/choose {index}` — staff picked candidate
  /// [index] of an ambiguous address; main's answer arrives later as an
  /// order update (202).
  Future<void> chooseGeo(String id, int index) => _v210Route(() async {
    await _send('POST', '/api/orders/${Uri.encodeComponent(id)}/geo/choose', body: {'index': index});
  });

  Future<StoredOrder> ready(String id) async =>
      StoredOrder.fromJson(jMap(await _send('POST', '/api/orders/${Uri.encodeComponent(id)}/ready')));

  /// Revoke this tablet's own key on the agent (Settings → Unpair).
  Future<void> unpairSelf() async {
    await _send('POST', '/api/device/unpair');
  }

  /// `POST /api/orders/{id}/reprint` — the customer receipt only, again.
  Future<void> reprint(String id) async {
    await _send('POST', '/api/orders/${Uri.encodeComponent(id)}/reprint', timeout: printTimeout);
  }

  /// `POST /api/orders/{id}/kitchen` — every kitchen (station) ticket of an
  /// accepted order again, no receipt. 409 `not_accepted` /
  /// `nothing_for_kitchen`, 502 `print_failed`, 404 unknown order. An older
  /// Pi without the route answers 405 (or a plain-text 404) → thrown as
  /// [kKitchenUnsupported].
  Future<KitchenResend> resendKitchen(String id) async {
    try {
      final body = await _send('POST', '/api/orders/${Uri.encodeComponent(id)}/kitchen', timeout: printTimeout);
      return body is Map ? KitchenResend.fromJson(jMap(body)) : const KitchenResend();
    } on AgentException catch (e) {
      // A JSON 404 is the new route saying "no such order"; the mux's 405 or
      // its plain "404 page not found" means the route isn't there.
      final missing = e.statusCode == 405 || (e.statusCode == 404 && e.body.isEmpty);
      if (missing) {
        throw AgentException(e.message, statusCode: e.statusCode, code: kKitchenUnsupported, body: e.body);
      }
      if (e.statusCode == 404 && e.code == null) {
        throw AgentException(e.message, statusCode: 404, code: 'not_found', body: e.body);
      }
      rethrow;
    }
  }

  Future<List<StoredOrder>> assignDelivery({required String driverId, required List<String> orderIds}) async {
    final body = await _send('POST', '/api/deliveries/assign', body: {'driver_id': driverId, 'order_ids': orderIds});
    return jList(body, StoredOrder.fromJson);
  }

  // --- driver pools + AUTO (2.0.9) -------------------------------------------

  /// `POST /api/deliveries/pool {order_ids, driver_id}` — puts the orders in
  /// [driverId]'s pool (null = back to unassigned). All or nothing: 409
  /// `invalid_state` / `driver_not_available`, 404 `driver_not_found` /
  /// `not_found`.
  Future<List<StoredOrder>> poolOrders(List<String> orderIds, {String? driverId}) => _poolsRoute(() async {
    final body = await _send('POST', '/api/deliveries/pool', body: {'order_ids': orderIds, 'driver_id': driverId});
    return jList(body, StoredOrder.fromJson);
  });

  /// `POST /api/drivers/{id}/send-out` — sends the driver's pool (plus
  /// [includeOrderIds], pooled first in the same step) out now. Throws
  /// [NotReadyException] when something is still cooking and [markReady] is
  /// false; 400 `bad_request` = the pool is empty.
  Future<List<StoredOrder>> sendOut(
    String driverId, {
    bool markReady = false,
    List<String>? includeOrderIds,
    String? planId,
  }) => _poolsRoute(() async {
    try {
      final body = await _send(
        'POST',
        '/api/drivers/${Uri.encodeComponent(driverId)}/send-out',
        body: {
          'mark_ready': markReady,
          if (includeOrderIds != null && includeOrderIds.isNotEmpty) 'include_order_ids': includeOrderIds,
          if (planId != null && planId.isNotEmpty) 'plan_id': planId,
        },
        // Marking ready + dispatching can print nothing, but the Pi does a
        // few writes in one transaction: allow a little more than a read.
        timeout: const Duration(seconds: 15),
      );
      return jList(body, StoredOrder.fromJson);
    } on AgentException catch (e) {
      if (e.statusCode == 409 && e.code == 'not_ready') {
        final raw = e.body['order_ids'];
        final ids = raw is List ? raw.map((x) => jStr(x)).where((s) => s.isNotEmpty).toList() : <String>[];
        throw NotReadyException(e.message, orderIds: ids, body: e.body);
      }
      rethrow;
    }
  });

  /// `POST /api/deliveries/auto-plan` — a suggestion; nothing changes on the
  /// floor. 409 [kNoDrivers] when nobody is available.
  Future<AutoPlan> autoPlan() => _poolsRoute(() async {
    try {
      return AutoPlan.fromJson(
        jMap(await _send('POST', '/api/deliveries/auto-plan', body: const {}, timeout: const Duration(seconds: 15))),
      );
    } on AgentException catch (e) {
      if (e.statusCode == 409 && e.code == null) {
        throw AgentException(e.message, statusCode: 409, code: kNoDrivers, body: e.body);
      }
      rethrow;
    }
  });

  /// `POST /api/deliveries/auto-plan/{id}/confirm` — pools every suggestion
  /// that is still valid (or only [orderIds] of them, to their planned
  /// drivers — a preview staff edited); reports the ones skipped.
  Future<PlanConfirmResult> confirmPlan(String planId, {List<String>? orderIds}) => _poolsRoute(
    () async => PlanConfirmResult.fromJson(
      jMap(
        await _send(
          'POST',
          '/api/deliveries/auto-plan/${Uri.encodeComponent(planId)}/confirm',
          body: {'order_ids': ?orderIds},
        ),
      ),
    ),
  );

  /// `GET /api/drivers/{id}/pool/trip?order_ids=` — [orderIds] in the
  /// fastest driving order with the route (main), or the Pi's own order with
  /// `approximate` when main is unreachable.
  Future<PoolTrip> poolTrip(String driverId, List<String> orderIds) => _poolsRoute(
    () async => PoolTrip.fromJson(
      jMap(
        await _send(
          'GET',
          '/api/drivers/${Uri.encodeComponent(driverId)}/pool/trip',
          query: {'order_ids': orderIds.join(',')},
          timeout: const Duration(seconds: 15),
        ),
      ),
    ),
  );

  /// `POST /api/orders/{id}/pin {lat, lng}` — staff placed the address on
  /// the map; main remembers it and the route arrives later as an
  /// `order.updated`. 503 [kMainOffline].
  Future<void> pinOrder(String orderId, double lat, double lng) => _poolsRoute(() async {
    await _send('POST', '/api/orders/${Uri.encodeComponent(orderId)}/pin', body: {'lat': lat, 'lng': lng});
  });

  /// `PUT /api/settings/deliveries` → what the Pi saved. 400 out of range.
  Future<DeliverySettings> setDeliverySettings(DeliverySettings s) => _poolsRoute(
    () async => DeliverySettings.fromJson(jMap(await _send('PUT', '/api/settings/deliveries', body: s.toJson()))),
  );

  /// An older Pi has none of the pool routes (its mux answers 405, or a
  /// plain-text 404): [kPoolsUnsupported]. A JSON 404 (unknown order /
  /// driver) is kept.
  static Future<T> _poolsRoute<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on AgentException catch (e) {
      final missing = e.statusCode == 405 || (e.statusCode == 404 && e.body.isEmpty);
      if (!missing) rethrow;
      throw AgentException(e.message, statusCode: e.statusCode, code: kPoolsUnsupported, body: e.body);
    }
  }

  Future<List<StoredOrder>> driverReturned(String driverId) async {
    final body = await _send('POST', '/api/drivers/${Uri.encodeComponent(driverId)}/returned');
    return jList(body, StoredOrder.fromJson);
  }

  /// `POST /api/drivers/{id}/undo-return` — the latest return (≤10 min) is
  /// undone: the driver is out again. 409 invalid_state otherwise.
  Future<Driver> undoReturn(String driverId) async =>
      Driver.fromJson(jMap(await _send('POST', '/api/drivers/${Uri.encodeComponent(driverId)}/undo-return')));

  // --- driver reports ----------------------------------------------------------

  /// `GET /api/batches/{id}/driver-reports` (id 0 = the open batch).
  Future<List<DriverReport>> driverReports(int batchId) async =>
      jList(await _get('/api/batches/${batchId <= 0 ? 'current' : batchId}/driver-reports'), DriverReport.fromJson);

  /// `POST /api/batches/{id}/driver-reports/print` → how many slips printed
  /// (502 nothing_printed throws).
  Future<ReportPrintResult> printDriverReports(int batchId) async => ReportPrintResult.fromJson(
    jMap(
      await _send(
        'POST',
        '/api/batches/${batchId <= 0 ? 'current' : batchId}/driver-reports/print',
        timeout: printTimeout,
      ),
    ),
  );

  // --- app updates -------------------------------------------------------------

  /// `GET /api/app/latest` — the Quibase release the agent has cached, or
  /// null (204, or an agent without the route).
  Future<AppRelease?> appLatest() async {
    try {
      final body = await _get('/api/app/latest');
      if (body is! Map) return null;
      final r = AppRelease.fromJson(jMap(body));
      return r.versionCode > 0 ? r : null;
    } on AgentException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  /// Streams `GET /api/app/apk` into [file]; returns the sha256 (hex) of what
  /// was written. [onProgress] gets (received, total).
  Future<String> downloadApk(File file, {void Function(int received, int total)? onProgress}) async {
    final req = http.Request('GET', uri('/api/app/apk'))..headers.addAll(_headers);
    final http.StreamedResponse resp;
    try {
      resp = await _client.send(req).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw AgentException(_networkMessage(e), cause: e);
    }
    if (resp.statusCode != 200) {
      throw exceptionFromResponse(resp.statusCode, await resp.stream.bytesToString());
    }
    final total = resp.contentLength ?? 0;
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } catch (e) {
      throw AgentException('Download interrupted: ${_networkMessage(e)}');
    } finally {
      await sink.close();
    }
    return (await sha256.bind(file.openRead()).first).toString();
  }

  // --- drivers ---------------------------------------------------------------

  Future<List<Driver>> listDrivers() async => jList(await _get('/api/drivers'), Driver.fromJson);

  /// [posNumber]: their SoftTouch login # (2.1.0), sent only when given.
  Future<Driver> createDriver(String name, {String? posNumber}) async => Driver.fromJson(
    jMap(
      await _send(
        'POST',
        '/api/drivers',
        body: {'name': name.trim(), if (posNumber != null && posNumber.trim().isNotEmpty) 'pos_number': posNumber.trim()},
      ),
    ),
  );

  Future<void> renameDriver(String id, String name) async {
    await _send('PATCH', '/api/drivers/${Uri.encodeComponent(id)}', body: {'name': name.trim()});
  }

  /// `PATCH /api/drivers/{id}` with only what changed: [name] and / or
  /// [posNumber] ('' clears it).
  Future<void> updateDriver(String id, {String? name, String? posNumber}) async {
    await _send(
      'PATCH',
      '/api/drivers/${Uri.encodeComponent(id)}',
      body: {'name': ?name?.trim(), 'pos_number': ?posNumber?.trim()},
    );
  }

  Future<void> removeDriver(String id) async {
    await _send('DELETE', '/api/drivers/${Uri.encodeComponent(id)}');
  }

  Future<void> reorderDrivers(List<String> ids) async {
    await _send('POST', '/api/drivers/reorder', body: {'ids': ids});
  }

  /// `off` → `available` at the back of the queue (opens a shift).
  /// 409 `invalid_state` = already clocked in.
  Future<Driver> clockIn(String id) async =>
      Driver.fromJson(jMap(await _send('POST', '/api/drivers/${Uri.encodeComponent(id)}/clock-in')));

  /// `available` → `off` (closes the shift). 409 `driver_not_available` = off
  /// already, or out on a run.
  Future<Driver> clockOut(String id) async =>
      Driver.fromJson(jMap(await _send('POST', '/api/drivers/${Uri.encodeComponent(id)}/clock-out')));

  /// Shift records of the last [days] days, newest first.
  Future<List<Shift>> listShifts({int days = 7}) async =>
      jList(await _get('/api/drivers/shifts', {'days': '$days'}), Shift.fromJson);

  // --- batches ---------------------------------------------------------------

  Future<List<Batch>> listBatches() async => jList(await _get('/api/batches'), Batch.fromJson);

  /// Throws [BatchLeftoversException] when `force` is false and unfinished
  /// orders remain.
  Future<CloseBatchResult> closeBatch({required bool force}) async {
    try {
      final body = await _send('POST', '/api/batch/close', body: {'force': force}, timeout: printTimeout);
      return CloseBatchResult.fromJson(jMap(body));
    } on AgentException catch (e) {
      if (e.statusCode == 409 && e.code == 'batch_has_leftovers') {
        throw BatchLeftoversException(
          e.message,
          leftovers: jList(e.body['leftovers'], StoredOrder.fromJson),
          body: e.body,
        );
      }
      rethrow;
    }
  }

  // --- printers --------------------------------------------------------------

  Future<List<PrinterStatus>> listPrinters() async => jList(await _get('/api/printers'), PrinterStatus.fromJson);

  /// `POST /api/printers/test` — prints a short test slip on every printer
  /// (or [printerId]) with no failover; [probeOnly] just re-checks whether
  /// they answer. 409 `test_in_progress` while another test runs.
  Future<List<PrinterTestResult>> testPrinters({String? printerId, bool probeOnly = false}) async {
    final body = await _send(
      'POST',
      '/api/printers/test',
      body: {'printer_id': ?printerId, if (probeOnly) 'probe_only': true},
      timeout: printTimeout,
    );
    return jList(jMap(body)['results'], PrinterTestResult.fromJson);
  }

  /// `GET /api/printers/found` — printers the Pi found on its network;
  /// [refresh] makes it scan again now (slower). An older Pi has no such
  /// route ([AgentException.isMissingRoute]).
  Future<FoundPrinters> foundPrinters({bool refresh = false}) async => FoundPrinters.fromJson(
    jMap(
      await _send(
        'GET',
        '/api/printers/found',
        query: refresh ? const {'refresh': '1'} : null,
        timeout: refresh ? const Duration(seconds: 15) : null,
      ),
    ),
  );

  /// `POST /api/printers/add {name, ip, mac}` — the Pi asks main to add the
  /// printer (main pushes the new roster back). 409 [kPrinterNameTaken],
  /// 503 [kMainOffline], 400 `bad_request`.
  Future<AddedPrinter> addPrinter(String name, String ip, String mac) async {
    try {
      final body = await _send(
        'POST',
        '/api/printers/add',
        body: {'name': name.trim(), 'ip': ip, 'mac': mac},
        timeout: const Duration(seconds: 15),
      );
      return AddedPrinter.fromJson(jMap(body));
    } on AgentException catch (e) {
      // Keep the codes reliable even if the body had none.
      final code = switch (e.statusCode) {
        409 => kPrinterNameTaken,
        503 => kMainOffline,
        _ => null,
      };
      if (code == null || e.code == code) rethrow;
      throw AgentException(e.message, statusCode: e.statusCode, code: code, body: e.body, cause: e.cause);
    }
  }

  // --- receipt settings ------------------------------------------------------

  /// `GET /api/settings/receipt` → the saved settings, the defaults and the
  /// footer that prints now. An older Pi throws [kReceiptUnsupported].
  Future<ReceiptSettings> getReceiptPrefs() =>
      _receiptRoute(() async => ReceiptSettings.fromJson(jMap(await _get('/api/settings/receipt'))));

  /// `PUT /api/settings/receipt` with the full object → what the Pi saved.
  /// 400 `bad_request` carries a plain reason in the message.
  Future<ReceiptSettings> putReceiptPrefs(ReceiptPrefs prefs) => _receiptRoute(
    () async => ReceiptSettings.fromJson(jMap(await _send('PUT', '/api/settings/receipt', body: prefs.toJson()))),
  );

  /// `POST /api/printers/sample {printer_id?}` — a sample customer receipt
  /// and kitchen ticket with the saved settings on that printer (default:
  /// the receipt printer), no failover. 409 `test_in_progress`; 404
  /// `not_configured` for an unknown printer.
  Future<List<PrinterTestResult>> printSample({String? printerId}) => _receiptRoute(() async {
    final body = await _send('POST', '/api/printers/sample', body: {'printer_id': ?printerId}, timeout: printTimeout);
    return jList(jMap(body)['results'], PrinterTestResult.fromJson);
  });

  /// An older Pi has none of the receipt routes: the GET falls to the web
  /// UI's `/api/*` 404, a PUT / POST to the mux's 405. Both become
  /// [kReceiptUnsupported] (a real 404 `not_configured` is kept).
  static Future<T> _receiptRoute<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on AgentException catch (e) {
      if (!e.isMissingRoute) rethrow;
      throw AgentException(e.message, statusCode: e.statusCode, code: kReceiptUnsupported, body: e.body);
    }
  }

  // --- 2.1.0 settings: features, kitchen tickets, default times ---------------

  Future<FeatureToggles> getFeatures() =>
      _v210Route(() async => FeatureToggles.fromJson(jMap(await _get('/api/settings/features'))), settings: true);

  /// `PUT /api/settings/features` → what the Pi saved.
  Future<FeatureToggles> putFeatures(FeatureToggles f) => _v210Route(
    () async => FeatureToggles.fromJson(jMap(await _send('PUT', '/api/settings/features', body: f.toJson()))),
    settings: true,
  );

  Future<TicketToggles> getTickets() =>
      _v210Route(() async => TicketToggles.fromJson(jMap(await _get('/api/settings/tickets'))), settings: true);

  Future<TicketToggles> putTickets(TicketToggles t) => _v210Route(
    () async => TicketToggles.fromJson(jMap(await _send('PUT', '/api/settings/tickets', body: t.toJson()))),
    settings: true,
  );

  Future<DefaultTimes> getTimes() =>
      _v210Route(() async => DefaultTimes.fromJson(jMap(await _get('/api/settings/times'))), settings: true);

  /// 400 when a value is outside 1–240.
  Future<DefaultTimes> putTimes(DefaultTimes t) => _v210Route(
    () async => DefaultTimes.fromJson(jMap(await _send('PUT', '/api/settings/times', body: t.toJson()))),
    settings: true,
  );

  /// An older Pi has none of the 2.1.0 routes (405, or a plain-text 404):
  /// [kSettingsUnsupported]. A JSON 404 (unknown order) is kept — except on
  /// the settings routes ([settings]), where any 404 means "no such route"
  /// (an older Pi's web UI answers unknown `/api/*` GETs with one).
  static Future<T> _v210Route<T>(Future<T> Function() call, {bool settings = false}) async {
    try {
      return await call();
    } on AgentException catch (e) {
      final missing = settings ? e.isMissingRoute : (e.statusCode == 405 || (e.statusCode == 404 && e.body.isEmpty));
      if (!missing) rethrow;
      throw AgentException(e.message, statusCode: e.statusCode, code: kSettingsUnsupported, body: e.body);
    }
  }

  // --- this tablet + diagnostics ----------------------------------------------

  /// `GET /api/diag` — the Pi's own view: connection to main, SD card /
  /// power health, printers, recent orders.
  Future<PiDiag> getDiag({Duration? timeout}) async =>
      PiDiag.fromJson(jMap(await _send('GET', '/api/diag', timeout: timeout)));

  /// `PATCH /api/device/self {name}` — renames this tablet.
  Future<String> renameSelf(String name) async =>
      jStr(jMap(await _send('PATCH', '/api/device/self', body: {'name': name.trim()}))['name']);

  /// `POST /api/pairing/code` — a 6-digit code another tablet can pair with.
  Future<PairingCode> pairingCode() async => PairingCode.fromJson(jMap(await _send('POST', '/api/pairing/code')));

  /// `POST /api/device/report-token` — a report-only key for sending
  /// diagnostics straight to main when the Pi is down.
  Future<ReportToken> reportToken() async =>
      ReportToken.fromJson(jMap(await _send('POST', '/api/device/report-token', timeout: const Duration(seconds: 15))));

  /// `POST /api/diag/report` — forwards a diagnostics report to main.
  Future<void> sendReport(Map<String, Object?> report) async {
    await _send('POST', '/api/diag/report', body: report, timeout: const Duration(seconds: 15));
  }

  // --- plumbing --------------------------------------------------------------

  Future<Object?> _get(String path, [Map<String, String>? query]) => _send('GET', path, query: query);

  Future<Object?> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration? timeout,
  }) async {
    final req = http.Request(method, uri(path, query));
    req.headers.addAll(body == null ? _headers : _jsonHeaders);
    if (body != null) req.body = jsonEncode(body);
    http.Response resp;
    try {
      final streamed = await _client.send(req).timeout(timeout ?? this.timeout);
      resp = await http.Response.fromStream(streamed).timeout(timeout ?? this.timeout);
    } catch (e) {
      throw AgentException(_networkMessage(e), cause: e);
    }
    try {
      _check(resp);
    } on AgentException catch (e) {
      if (e.isDeviceRevoked) onDeviceRevoked?.call();
      rethrow;
    }
    if (resp.body.trim().isEmpty) return null;
    try {
      return jsonDecode(resp.body);
    } catch (_) {
      return null;
    }
  }

  static void _check(http.Response resp) {
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    throw exceptionFromResponse(resp.statusCode, resp.body);
  }

  /// Builds an [AgentException] from a status + raw body (shared with SSE).
  static AgentException exceptionFromResponse(int status, String rawBody) {
    var message = 'HTTP $status';
    String? code;
    var body = const <String, dynamic>{};
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map) {
        body = jMap(decoded);
        final err = jStr(body['error']);
        if (err.isNotEmpty) message = err;
        code = jStrOrNull(body['code']);
      }
    } catch (_) {}
    return AgentException(message, statusCode: status, code: code, body: body);
  }

  static String _networkMessage(Object e) {
    if (e is TimeoutException) return "The Pi didn't answer in time";
    return "Can't reach the Pi";
  }

  void dispose() => _client.close();
}
