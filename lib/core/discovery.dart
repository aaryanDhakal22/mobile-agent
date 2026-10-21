import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'models.dart';

/// UDP port the agent's discovery responder listens on (agent 2.0.1+).
const int kDiscoveryPort = 48080;

/// The Pi's hostname on the card (DietPi), which many routers resolve.
const String kPiHostname = 'quiccpos-pi';

/// A Pi found on the store network.
class DiscoveredPi {
  /// Normalized base URL, e.g. http://192.168.0.40:8080
  final String address;
  final String storeName;

  /// Linked to a store already (otherwise it's a new Pi to set up).
  final bool linked;
  final bool linkAvailable;
  final String version;
  final String host;

  /// How it was found: broadcast | hostname | saved | sweep | typed
  final String via;

  const DiscoveredPi({
    required this.address,
    this.storeName = '',
    this.linked = false,
    this.linkAvailable = false,
    this.version = '',
    this.host = '',
    this.via = 'broadcast',
  });

  bool get isNew => !linked && linkAvailable;

  /// "192.168.0.40" (the port is always 8080 in practice).
  String get ip => Uri.tryParse(address)?.host ?? address;

  DiscoveredPi withProbe(AgentProbe p) => DiscoveredPi(
    address: address,
    storeName: p.storeName.isNotEmpty ? p.storeName : storeName,
    linked: p.state != 'unconfigured',
    linkAvailable: p.linkAvailable,
    version: p.version.isNotEmpty ? p.version : version,
    host: p.hostname.isNotEmpty ? p.hostname : host,
    via: via,
  );
}

/// The probe datagram: padded so a reply can never be bigger than the probe
/// (no amplification), with a nonce the reply must echo.
List<int> discoveryProbe(String nonce) {
  final body = jsonEncode({'q': 'quibase-discover', 'v': 1, 'nonce': nonce});
  return utf8.encode(body.padRight(512));
}

/// Parses one reply datagram from [from]; null if it isn't a Quicc agent
/// answering our [nonce].
DiscoveredPi? parseDiscoveryReply(List<int> data, String fromIp, String nonce) {
  try {
    final m = jsonDecode(utf8.decode(data).trim());
    if (m is! Map || m['svc'] != 'quicc-agent' || m['nonce'] != nonce) return null;
    final port = m['port'] is int ? m['port'] as int : kAgentPort;
    return DiscoveredPi(
      address: normalizeAgentAddress('$fromIp:$port'),
      storeName: '${m['store'] ?? ''}',
      linked: m['linked'] == true,
      linkAvailable: m['link_available'] == true,
      version: '${m['version'] ?? ''}',
      host: '${m['host'] ?? ''}',
    );
  } catch (_) {
    return null;
  }
}

/// The /24 broadcast address for a local IPv4 (Android doesn't tell us the
/// prefix length; store networks are /24 in practice).
String? subnetBroadcast(InternetAddress a) {
  final p = a.address.split('.');
  return p.length == 4 ? '${p[0]}.${p[1]}.${p[2]}.255' : null;
}

/// Finds Pis on the store network, cheapest first:
/// 1. a UDP broadcast that agents 2.0.1+ answer (no Android permission needed:
///    the reply comes back unicast);
/// 2. in parallel, the last saved address and the Pi's hostname;
/// 3. only if nothing turned up, a sweep of the /24 for `:8080/api/version`
///    (works with broadcast blocked and with older agents).
/// Every hit is confirmed with `GET /api/session`. The stream emits the
/// growing list and closes when done.
class PiDiscovery {
  final http.Client Function() clientFactory;
  final Future<List<InternetAddress>> Function() localAddresses;
  final Duration listenFor;

  PiDiscovery({
    http.Client Function()? clientFactory,
    Future<List<InternetAddress>> Function()? localAddresses,
    this.listenFor = const Duration(milliseconds: 2500),
  }) : clientFactory = clientFactory ?? http.Client.new,
       localAddresses = localAddresses ?? _localIPv4;

  Stream<List<DiscoveredPi>> discover({String? savedAddress, bool sweep = true}) {
    final out = StreamController<List<DiscoveredPi>>();
    final found = <String, DiscoveredPi>{};
    final client = clientFactory();

    Future<void> confirm(DiscoveredPi p) async {
      if (found.containsKey(p.address)) return;
      try {
        final probe = await AgentClient.probe(address: p.address, client: client, timeout: const Duration(seconds: 3));
        if (found.containsKey(p.address) || out.isClosed) return;
        found[p.address] = p.withProbe(probe);
        out.add(found.values.toList());
      } catch (_) {
        // Not a Pi, or gone.
      }
    }

    Future<void> run() async {
      final locals = await localAddresses();
      final tasks = <Future<void>>[
        _broadcast(locals, (p) => confirm(p)),
        if ((savedAddress ?? '').isNotEmpty)
          confirm(DiscoveredPi(address: normalizeAgentAddress(savedAddress!), via: 'saved')),
        confirm(DiscoveredPi(address: normalizeAgentAddress(kPiHostname), via: 'hostname')),
      ];
      await Future.wait(tasks);
      if (found.isEmpty && sweep) await _sweep(locals, client, confirm);
    }

    run().whenComplete(() {
      client.close();
      if (!out.isClosed) {
        if (found.isEmpty) out.add(const []);
        out.close();
      }
    });
    return out.stream;
  }

  Future<void> _broadcast(List<InternetAddress> locals, Future<void> Function(DiscoveredPi) onHit) async {
    RawDatagramSocket? sock;
    final pending = <Future<void>>[];
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final nonce = _nonce();
      final probe = discoveryProbe(nonce);
      final targets = {
        '255.255.255.255',
        for (final a in locals) ?subnetBroadcast(a),
      }.map(InternetAddress.new).toList();
      final s = sock;
      final sub = s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final dg = s.receive();
        if (dg == null) return;
        final p = parseDiscoveryReply(dg.data, dg.address.address, nonce);
        if (p != null) pending.add(onHit(p));
      });
      for (final delay in const [0, 400, 800]) {
        await Future<void>.delayed(Duration(milliseconds: delay == 0 ? 0 : 400));
        for (final t in targets) {
          try {
            s.send(probe, t, kDiscoveryPort);
          } catch (_) {
            // e.g. no route for that broadcast address
          }
        }
      }
      await Future<void>.delayed(listenFor - const Duration(milliseconds: 800));
      await sub.cancel();
    } catch (_) {
      // No network / sockets refused: the other paths still run.
    } finally {
      sock?.close();
    }
    await Future.wait(pending);
  }

  Future<void> _sweep(
    List<InternetAddress> locals,
    http.Client client,
    Future<void> Function(DiscoveredPi) confirm,
  ) async {
    final hosts = <String>[];
    for (final a in locals) {
      final p = a.address.split('.');
      if (p.length != 4) continue;
      for (var i = 1; i < 255; i++) {
        final ip = '${p[0]}.${p[1]}.${p[2]}.$i';
        if (ip != a.address) hosts.add(ip);
      }
    }
    const batch = 32;
    for (var i = 0; i < hosts.length; i += batch) {
      await Future.wait([
        for (final ip in hosts.skip(i).take(batch))
          AgentClient.version(address: ip, client: client, timeout: const Duration(milliseconds: 400)).then((v) async {
            if (v != null) await confirm(DiscoveredPi(address: normalizeAgentAddress(ip), version: v, via: 'sweep'));
          }),
      ]);
    }
  }

  static String _nonce() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<List<InternetAddress>> _localIPv4() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in ifs)
          for (final a in i.addresses)
            if (!a.isLoopback && !a.address.startsWith('169.254.')) a,
      ];
    } catch (_) {
      return const [];
    }
  }
}

final piDiscoveryProvider = Provider<PiDiscovery>((_) => PiDiscovery());
