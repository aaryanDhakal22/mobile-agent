import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Reconnecting SSE subscription. Yields every `order.arrived` event the agent
/// broadcasts. The loop survives network blips — on any error it waits briefly
/// and re-dials. Keepalive comment lines (`: keepalive`) are silently ignored.
Stream<StoredOrder> arrivedEventStream(String baseUrl) async* {
  final uri = Uri.parse('$baseUrl/api/events');

  while (true) {
    http.Client? client;
    try {
      client = http.Client();
      final req = http.Request('GET', uri);
      req.headers['Accept'] = 'text/event-stream';
      req.headers['Cache-Control'] = 'no-cache';

      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        throw http.ClientException('SSE connect failed: ${resp.statusCode}', uri);
      }

      String? currentEvent;
      final dataBuffer = StringBuffer();

      final lines = resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (line.isEmpty) {
          if (currentEvent == 'order.arrived' && dataBuffer.isNotEmpty) {
            try {
              final decoded = jsonDecode(dataBuffer.toString()) as Map<String, dynamic>;
              yield StoredOrder.fromJson(decoded);
            } catch (_) {
              // Malformed payload — skip, keep the stream alive.
            }
          }
          currentEvent = null;
          dataBuffer.clear();
          continue;
        }
        if (line.startsWith(':')) continue; // comment / keepalive
        if (line.startsWith('event:')) {
          currentEvent = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          dataBuffer.write(line.substring(5).trim());
        }
      }
    } catch (_) {
      // Connection dropped / refused. Back off and try again.
    } finally {
      client?.close();
    }

    await Future<void>.delayed(const Duration(seconds: 2));
  }
}
