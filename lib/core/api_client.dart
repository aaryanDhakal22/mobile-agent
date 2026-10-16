import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'json.dart';
import 'models.dart';
import 'printer_models.dart';

/// Header carrying the paired tablet's key on every floor request.
const String kDeviceKeyHeader = 'X-Agent-Device-Key';

/// Turns what staff type ("192.168.1.219:8080", "http://pi.lan:8080/") into a
/// base URL with a scheme and no trailing slash. Returns '' for blank input.
String normalizeAgentAddress(String input) {
  var s = input.trim();
  if (s.isEmpty) return '';
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// A non-2xx answer from the agent. Error bodies are `{"error", "code"?}`;
/// `body` keeps the whole decoded map (e.g. `leftovers` on a 409).
class AgentException implements Exception {
  final int? statusCode;
  final String? code;
  final String message;
  final Map<String, dynamic> body;

  const AgentException(this.message, {this.statusCode, this.code, this.body = const {}});

  /// The tablet's key was revoked (or never valid): re-pair.
  bool get isDeviceRevoked => statusCode == 401 && code == 'device_required';
  bool get isPrinterFailure => statusCode == 502;
  bool get isConflict => statusCode == 409;
  bool get isNotFound => statusCode == 404;
  bool get isNetwork => statusCode == null;

  @override
  String toString() => statusCode == null ? message : 'HTTP $statusCode: $message';
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

  AgentClient({
    required String baseUrl,
    required this.deviceKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
    this.printTimeout = const Duration(seconds: 60),
    this.onDeviceRevoked,
  }) : baseUrl = normalizeAgentAddress(baseUrl),
       _client = client ?? http.Client();

  Uri uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('$baseUrl$path');
    return query == null ? u : u.replace(queryParameters: query);
  }

  Map<String, String> get _headers => {kDeviceKeyHeader: deviceKey, 'Accept': 'application/json'};

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
            headers: const {'Content-Type': 'application/json'},
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
      throw AgentException(_networkMessage(e));
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

  Future<StoredOrder> ready(String id) async =>
      StoredOrder.fromJson(jMap(await _send('POST', '/api/orders/${Uri.encodeComponent(id)}/ready')));

  /// Revoke this tablet's own key on the agent (Settings → Unpair).
  Future<void> unpairSelf() async {
    await _send('POST', '/api/device/unpair');
  }

  Future<void> reprint(String id) async {
    await _send('POST', '/api/orders/${Uri.encodeComponent(id)}/reprint', timeout: printTimeout);
  }

  Future<List<StoredOrder>> assignDelivery({required String driverId, required List<String> orderIds}) async {
    final body = await _send('POST', '/api/deliveries/assign', body: {'driver_id': driverId, 'order_ids': orderIds});
    return jList(body, StoredOrder.fromJson);
  }

  Future<List<StoredOrder>> driverReturned(String driverId) async {
    final body = await _send('POST', '/api/drivers/${Uri.encodeComponent(driverId)}/returned');
    return jList(body, StoredOrder.fromJson);
  }

  // --- drivers ---------------------------------------------------------------

  Future<List<Driver>> listDrivers() async => jList(await _get('/api/drivers'), Driver.fromJson);

  Future<Driver> createDriver(String name) async =>
      Driver.fromJson(jMap(await _send('POST', '/api/drivers', body: {'name': name.trim()})));

  Future<void> renameDriver(String id, String name) async {
    await _send('PATCH', '/api/drivers/${Uri.encodeComponent(id)}', body: {'name': name.trim()});
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
      throw AgentException(_networkMessage(e));
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
    if (e is TimeoutException) return "Agent didn't answer in time";
    return "Can't reach the agent ($e)";
  }

  void dispose() => _client.close();
}
