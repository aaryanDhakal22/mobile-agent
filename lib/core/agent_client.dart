import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class AgentException implements Exception {
  final int? statusCode;
  final String message;
  const AgentException(this.message, {this.statusCode});

  bool get isPrinterFailure => statusCode == 502;
  bool get isAlreadyAccepted => statusCode == 409;

  @override
  String toString() => 'AgentException($statusCode): $message';
}

class AgentClient {
  final String baseUrl;
  final http.Client _client;
  final Duration timeout;

  AgentClient(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 6)})
      : _client = client ?? http.Client();

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<List<StoredOrder>> listArrived() async {
    final resp = await _client.get(_uri('/api/orders/arrived')).timeout(timeout);
    _throwIfBad(resp);
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(StoredOrder.fromJson)
        .toList(growable: false);
  }

  Future<StoredOrder> accept(int id) async {
    final resp = await _client
        .post(_uri('/api/orders/$id/accept'))
        .timeout(timeout);
    _throwIfBad(resp);
    return StoredOrder.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<StoredOrder> reprint(int id) async {
    final resp = await _client
        .post(_uri('/api/orders/$id/reprint'))
        .timeout(timeout);
    _throwIfBad(resp);
    return StoredOrder.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<bool> getAutoAccept() async {
    final resp = await _client.get(_uri('/api/settings/auto-accept')).timeout(timeout);
    _throwIfBad(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['auto_accept'] as bool? ?? false;
  }

  Future<bool> setAutoAccept(bool enabled) async {
    final resp = await _client
        .put(
          _uri('/api/settings/auto-accept'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'auto_accept': enabled}),
        )
        .timeout(timeout);
    _throwIfBad(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['auto_accept'] as bool? ?? enabled;
  }

  void _throwIfBad(http.Response resp) {
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    String message = 'HTTP ${resp.statusCode}';
    try {
      final body = jsonDecode(resp.body);
      if (body is Map && body['error'] is String) {
        message = body['error'] as String;
      }
    } catch (_) {}
    throw AgentException(message, statusCode: resp.statusCode);
  }

  void dispose() => _client.close();
}
