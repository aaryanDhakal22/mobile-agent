import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/device_platform.dart';
import '../../core/diag_models.dart';
import '../../core/discovery.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/storage.dart';
import 'texts.dart';

/// Every check the troubleshooting runs, in the order the status board shows
/// them. [wire] is the key in a report's `checks`.
enum CheckId {
  tabletNetwork('tablet_network'),
  tabletInternet('tablet_internet'),
  mainFromTablet('main_from_tablet'),
  piDiscovered('pi_discovered'),
  piPort('pi_port'),
  piApi('pi_api'),
  piToMain('pi_to_main'),
  piHealth('pi_health'),
  printers('printers'),
  ordersFlow('orders_flow');

  final String wire;
  const CheckId(this.wire);
}

enum CheckStatus { ok, fail, unknown }

class CheckResult {
  final CheckId id;
  final CheckStatus status;

  /// One plain sentence for staff ("The Pi answers").
  final String plain;

  /// The technical detail (for the owner, in the report).
  final String details;

  const CheckResult(this.id, this.status, this.plain, [this.details = '']);

  bool get ok => status == CheckStatus.ok;
  bool get failed => status == CheckStatus.fail;

  Map<String, Object?> toJson() => {'status': status.name, 'plain': plain, 'details': details};
}

/// What a TCP dial to the Pi's port says.
enum PortState {
  /// Something answers: the agent is listening.
  open,

  /// The Pi is on the network but nothing listens: the agent is down.
  refused,

  /// No answer at all: the Pi is off, or its cable / the network is broken.
  unreachable,
  unknown,
}

/// One run of all checks: the raw facts the guides decide on, plus [results]
/// (plain sentences) for the status board and reports.
class CheckSnapshot {
  final DateTime at;
  final String savedAddress;

  /// Android's view of the tablet (null off-device or when it failed).
  final DeviceChecks? device;
  final bool? internet;
  final bool? mainFromTablet;
  final PortState piPort;

  /// `GET /api/session` at the saved address (null = no answer).
  final AgentProbe? session;

  /// A fresh `GET /api/diag` (null = no answer, or an agent without it).
  final PiDiag? diag;

  /// The agent answered 404 to /api/diag (2.0.0).
  final bool diagUnsupported;

  /// The last diag saved on the tablet — still useful when the Pi is down.
  final PiDiag? lastDiag;

  /// Pis found on the network (empty when discovery didn't run or found none).
  final List<DiscoveredPi> discovered;

  /// This store's Pi, answering at a different address (this tablet's key
  /// works there).
  final DiscoveredPi? piElsewhere;

  /// A quick re-dial of every printer (the printer guide asks for it).
  final List<PrinterTestResult>? printerProbe;

  const CheckSnapshot({
    required this.at,
    this.savedAddress = '',
    this.device,
    this.internet,
    this.mainFromTablet,
    this.piPort = PortState.unknown,
    this.session,
    this.diag,
    this.diagUnsupported = false,
    this.lastDiag,
    this.discovered = const [],
    this.piElsewhere,
    this.printerProbe,
  });

  // --- facts ------------------------------------------------------------------

  bool? get tabletOnNetwork => device?.onNetwork;

  /// The Pi answers at the saved address.
  bool get piAnswers => session != null;

  /// …and is a set-up Pi (a fresh card at the same address isn't "fixed").
  bool get piLinked => session != null && session!.state != 'unconfigured';

  /// A new (unconfigured) Pi on the network, e.g. a spare card that started.
  DiscoveredPi? get newPi {
    for (final p in discovered) {
      if (!p.linked) return p;
    }
    if (session != null && session!.state == 'unconfigured') {
      return DiscoveredPi(address: normalizeAgentAddress(savedAddress), linked: false, via: 'saved');
    }
    return null;
  }

  bool get anyPiFound => session != null || discovered.isNotEmpty;

  /// connected | connecting | rejected | unconfigured | null (unknown).
  String? get piToMain {
    if (diag != null && diag!.mainState.isNotEmpty) return diag!.mainState;
    final s = session?.sseState ?? '';
    return s.isEmpty ? null : s;
  }

  bool? get piReachesMain => diag?.mainReachable;

  /// The Pi is connected to the Quicc server.
  bool get piMainOk => piToMain == 'connected' && piReachesMain != false;

  /// The Pi's own link to the server is down (known, not just unknown).
  bool get piMainDown =>
      (piToMain != null && piToMain != 'connected' && piToMain != 'unconfigured' && piToMain != 'rejected') ||
      piReachesMain == false;

  /// The last known Pi health (fresh, else saved).
  PiDiag? get knownDiag => diag ?? lastDiag;
  bool get sdSuspect => knownDiag?.health.sdTrouble ?? false;
  bool get powerSuspect => knownDiag?.health.powerTrouble ?? false;

  /// The printers as the Pi sees them, with a fresh [printerProbe] on top.
  List<DiagPrinter> get printers {
    final base = diag?.printers ?? const <DiagPrinter>[];
    final probe = printerProbe;
    if (probe == null) return base;
    final byId = {for (final r in probe) r.id: r};
    final out = <DiagPrinter>[
      for (final p in base)
        byId[p.id] == null
            ? p
            : DiagPrinter(
                id: p.id,
                name: p.name,
                ip: p.ip,
                up: byId[p.id]!.ok,
                isReceipt: p.isReceipt,
                lastError: byId[p.id]!.error,
                downSince: p.downSince,
              ),
    ];
    // A probe can name printers a 2.0.0 Pi's diag didn't list.
    for (final r in probe) {
      if (!out.any((p) => p.id == r.id)) out.add(DiagPrinter(id: r.id, name: r.name, up: r.ok, lastError: r.error));
    }
    return out;
  }

  /// null = not known (no fresh printer data).
  bool? printerUp(String id) {
    if (diag == null && printerProbe == null) return null;
    for (final p in printers) {
      if (p.id == id) return p.up;
    }
    return null;
  }

  /// Open, and no order for longer than is normal (null = unknown: closed
  /// hours, no schedule, or no Pi data).
  bool? get ordersQuiet {
    final d = diag;
    if (d == null || d.openNow == null) return null;
    if (d.openNow == false) return false;
    final last = d.lastArrivedAt;
    if (last == null) return null;
    return at.difference(last) > Duration(minutes: d.quietAlertMinutes);
  }

  // --- plain sentences --------------------------------------------------------

  /// Every check as a plain sentence, status-board order.
  Map<CheckId, CheckResult> get results => {for (final r in _describe()) r.id: r};

  List<CheckResult> _describe() {
    final out = <CheckResult>[];
    CheckResult r(CheckId id, CheckStatus s, String plain, [String details = '']) => CheckResult(id, s, plain, details);

    final d = device;
    out.add(
      d == null
          ? r(CheckId.tabletNetwork, CheckStatus.unknown, CheckText.tabletNetworkUnknown)
          : d.onNetwork
          ? r(CheckId.tabletNetwork, CheckStatus.ok, CheckText.tabletNetworkOk, 'wifi=${d.wifi} ethernet=${d.ethernet}')
          : r(CheckId.tabletNetwork, CheckStatus.fail, CheckText.tabletNetworkFail, 'wifi=false ethernet=false'),
    );
    out.add(switch (internet) {
      true => r(CheckId.tabletInternet, CheckStatus.ok, CheckText.internetOk),
      false => r(CheckId.tabletInternet, CheckStatus.fail, CheckText.internetFail),
      null => r(CheckId.tabletInternet, CheckStatus.unknown, CheckText.internetUnknown),
    });
    out.add(switch (mainFromTablet) {
      true => r(CheckId.mainFromTablet, CheckStatus.ok, CheckText.mainOk),
      false => r(CheckId.mainFromTablet, CheckStatus.fail, CheckText.mainFail),
      null => r(CheckId.mainFromTablet, CheckStatus.unknown, CheckText.mainUnknown),
    });

    final found = discovered.map((p) => '${p.address} (${p.linked ? 'linked' : 'new'}, ${p.via})').join(', ');
    if (piElsewhere != null) {
      out.add(
        r(
          CheckId.piDiscovered,
          CheckStatus.fail,
          CheckText.piMoved(piElsewhere!.ip),
          'saved=$savedAddress found=$found',
        ),
      );
    } else if (session != null) {
      out.add(r(CheckId.piDiscovered, CheckStatus.ok, CheckText.piFoundSaved, 'saved=$savedAddress found=$found'));
    } else if (discovered.isNotEmpty) {
      out.add(
        r(
          CheckId.piDiscovered,
          CheckStatus.fail,
          newPi != null ? CheckText.piFoundNew : CheckText.piFoundOther,
          'saved=$savedAddress found=$found',
        ),
      );
    } else {
      out.add(r(CheckId.piDiscovered, CheckStatus.fail, CheckText.piNotFound, 'saved=$savedAddress'));
    }

    out.add(switch (piPort) {
      PortState.open => r(CheckId.piPort, CheckStatus.ok, CheckText.portOpen, savedAddress),
      PortState.refused => r(CheckId.piPort, CheckStatus.fail, CheckText.portRefused, '$savedAddress refused'),
      PortState.unreachable => r(
        CheckId.piPort,
        CheckStatus.fail,
        CheckText.portUnreachable,
        '$savedAddress no answer',
      ),
      PortState.unknown => r(CheckId.piPort, CheckStatus.unknown, CheckText.portUnknown),
    });

    final s = session;
    out.add(
      s == null
          ? r(CheckId.piApi, CheckStatus.fail, CheckText.apiFail, savedAddress)
          : s.state == 'unconfigured'
          ? r(CheckId.piApi, CheckStatus.fail, CheckText.apiNew, 'state=unconfigured version=${s.version}')
          : r(
              CheckId.piApi,
              CheckStatus.ok,
              CheckText.apiOk,
              'state=${s.state} version=${s.version} store=${s.storeName}',
            ),
    );

    // Everything below needs the Pi to answer.
    if (!piAnswers) {
      out.add(r(CheckId.piToMain, CheckStatus.unknown, CheckText.needsPi));
      final last = lastDiag;
      if (last != null && (last.health.sdTrouble || last.health.powerTrouble)) {
        out.add(_health(last, lastKnown: true));
      } else {
        out.add(r(CheckId.piHealth, CheckStatus.unknown, CheckText.needsPi));
      }
      out.add(r(CheckId.printers, CheckStatus.unknown, CheckText.needsPi));
      out.add(r(CheckId.ordersFlow, CheckStatus.unknown, CheckText.needsPi));
      return out;
    }

    final main = piToMain;
    final mainDetails = 'state=$main reachable=$piReachesMain ${diag?.mainLastError ?? ''}'.trim();
    out.add(
      main == 'connected' && piReachesMain != false
          ? r(CheckId.piToMain, CheckStatus.ok, CheckText.piMainOk, mainDetails)
          : main == 'rejected'
          ? r(CheckId.piToMain, CheckStatus.fail, CheckText.piMainRejected, mainDetails)
          : main == null
          ? r(CheckId.piToMain, CheckStatus.unknown, CheckText.piMainUnknown, mainDetails)
          : r(CheckId.piToMain, CheckStatus.fail, CheckText.piMainDown, mainDetails),
    );

    out.add(
      diag != null
          ? _health(diag!)
          : r(CheckId.piHealth, CheckStatus.unknown, diagUnsupported ? CheckText.piTooOld : CheckText.healthUnknown),
    );

    final ps = printers;
    if (diag == null && printerProbe == null) {
      out.add(
        r(CheckId.printers, CheckStatus.unknown, diagUnsupported ? CheckText.piTooOld : CheckText.printersUnknown),
      );
    } else if (ps.isEmpty) {
      out.add(r(CheckId.printers, CheckStatus.unknown, CheckText.printersNone));
    } else {
      final down = ps.where((p) => !p.up).toList();
      final details = ps.map((p) => '${p.name}@${p.ip}=${p.up ? 'up' : 'down'}').join(', ');
      out.add(
        down.isEmpty
            ? r(CheckId.printers, CheckStatus.ok, CheckText.printersOk(ps.length), details)
            : r(CheckId.printers, CheckStatus.fail, CheckText.printersDown(down.map((p) => p.name).toList()), details),
      );
    }

    final quiet = ordersQuiet;
    final od = diag;
    out.add(switch (quiet) {
      true => r(
        CheckId.ordersFlow,
        CheckStatus.fail,
        CheckText.ordersQuiet(at.difference(od!.lastArrivedAt!)),
        'last_arrived_at=${od.lastArrivedAt?.toUtc().toIso8601String()} quiet_alert_minutes=${od.quietAlertMinutes}',
      ),
      false => r(
        CheckId.ordersFlow,
        CheckStatus.ok,
        od?.openNow == false ? CheckText.ordersClosed : CheckText.ordersOk,
        'last_arrived_at=${od?.lastArrivedAt?.toUtc().toIso8601String()}',
      ),
      null => r(CheckId.ordersFlow, CheckStatus.unknown, CheckText.ordersUnknown),
    });
    return out;
  }

  CheckResult _health(PiDiag d, {bool lastKnown = false}) {
    final h = d.health;
    final details =
        'sd_errors=${h.sdErrors} rootfs_ro=${h.rootfsReadOnly} under_voltage_now=${h.underVoltageNow} '
        'since_boot=${h.underVoltageSinceBoot} file_stale=${h.fileStale} problems=${d.problems.join(',')}'
        '${lastKnown ? ' (last known, ${d.fetchedAt?.toUtc().toIso8601String()})' : ''}';
    if (h.sdTrouble) return CheckResult(CheckId.piHealth, CheckStatus.fail, CheckText.healthSd(lastKnown), details);
    if (h.powerTrouble) {
      return CheckResult(CheckId.piHealth, CheckStatus.fail, CheckText.healthPower(lastKnown), details);
    }
    // No health file (or an old one): nothing is known, good or bad.
    if (h.fileStale) return CheckResult(CheckId.piHealth, CheckStatus.unknown, CheckText.healthUnknown, details);
    return CheckResult(CheckId.piHealth, CheckStatus.ok, CheckText.healthOk, details);
  }

  Map<String, Object?> toReport() => {for (final r in results.values) r.id.wire: r.toJson()};
}

// =============================================================================
// Probes
// =============================================================================

/// Everything the checks touch outside the app, behind one interface so the
/// tests can fake it.
abstract class DiagProbes {
  Future<DeviceChecks?> device();

  /// Android's "validated" flag, else `GET generate_204`. null = can't tell.
  Future<bool?> internet(DeviceChecks? device);

  /// `GET {mainUrl}/health`.
  Future<bool?> mainHealth(String mainUrl);

  /// A TCP dial to the Pi's host:port.
  Future<PortState> port(String address);

  /// `GET /api/session` at [address]; null = no answer.
  Future<AgentProbe?> session(String address);

  /// `GET /api/diag` with this tablet's key. Throws [AgentException] (404 on
  /// an older agent).
  Future<PiDiag> diag();

  /// Pis on the network (broadcast, saved address, hostname, then a sweep).
  Future<List<DiscoveredPi>> discover(String? savedAddress);

  /// This tablet's key is accepted at [address] (it's our store's Pi).
  Future<bool> keyWorksAt(String address);

  /// `POST /api/printers/test {probe_only:true}`.
  Future<List<PrinterTestResult>> probePrinters();
}

/// The real probes, wired to the app's providers.
class RealDiagProbes implements DiagProbes {
  final Ref ref;
  final http.Client Function() clientFactory;
  RealDiagProbes(this.ref, {http.Client Function()? clientFactory}) : clientFactory = clientFactory ?? http.Client.new;

  @override
  Future<DeviceChecks?> device() => ref.read(devicePlatformProvider).checks();

  @override
  Future<bool?> internet(DeviceChecks? device) async {
    if (device != null && device.validated) return true;
    final c = clientFactory();
    try {
      final r = await c
          .get(Uri.parse('http://connectivitycheck.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 3));
      return r.statusCode == 204;
    } catch (_) {
      return false;
    } finally {
      c.close();
    }
  }

  @override
  Future<bool?> mainHealth(String mainUrl) async {
    final c = clientFactory();
    try {
      final r = await c
          .get(Uri.parse('${mainUrl.replaceAll(RegExp(r'/+$'), '')}/health'))
          .timeout(const Duration(seconds: 3));
      return r.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      c.close();
    }
  }

  @override
  Future<PortState> port(String address) => dialPort(address);

  @override
  Future<AgentProbe?> session(String address) async {
    try {
      return await AgentClient.probe(address: address, timeout: const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PiDiag> diag() async {
    final c = ref.read(agentClientProvider);
    if (c == null) throw const AgentException('This tablet is not paired');
    return c.getDiag(timeout: const Duration(seconds: 4));
  }

  @override
  Future<List<DiscoveredPi>> discover(String? savedAddress) async {
    var last = const <DiscoveredPi>[];
    try {
      await for (final l in ref.read(piDiscoveryProvider).discover(savedAddress: savedAddress)) {
        last = l;
      }
    } catch (_) {
      // Keep what was found.
    }
    return last;
  }

  @override
  Future<bool> keyWorksAt(String address) async {
    final p = ref.read(pairingProvider);
    if (p == null) return false;
    // A throwaway client: no onDeviceRevoked, so a 401 here can't unpair us.
    final c = AgentClient(baseUrl: address, deviceKey: p.deviceKey, timeout: const Duration(seconds: 3));
    try {
      await c.listDrivers();
      return true;
    } catch (_) {
      return false;
    } finally {
      c.dispose();
    }
  }

  @override
  Future<List<PrinterTestResult>> probePrinters() async {
    final c = ref.read(agentClientProvider);
    if (c == null) return const [];
    return c.testPrinters(probeOnly: true);
  }
}

/// TCP dial to the agent's host:port: open / refused / unreachable.
Future<PortState> dialPort(String address, {Duration timeout = const Duration(seconds: 2)}) async {
  final u = Uri.tryParse(normalizeAgentAddress(address));
  if (u == null || u.host.isEmpty) return PortState.unknown;
  Socket? s;
  try {
    s = await Socket.connect(u.host, u.hasPort ? u.port : kAgentPort, timeout: timeout);
    return PortState.open;
  } on SocketException catch (e) {
    final code = e.osError?.errorCode;
    // ECONNREFUSED is 111 on Linux / Android (61 on macOS).
    if (code == 111 || code == 61 || '$e'.toLowerCase().contains('refused')) return PortState.refused;
    return PortState.unreachable;
  } catch (_) {
    return PortState.unreachable;
  } finally {
    s?.destroy();
  }
}

// =============================================================================
// Running the checks
// =============================================================================

/// Runs every check (≤ ~8 s: the probes run in parallel, each with its own
/// timeout). [probePrinters] re-dials the printers now (the printer guide).
/// [discover] can be turned off when the Pi answering is all that matters.
Future<CheckSnapshot> runChecks(
  DiagProbes probes, {
  required String savedAddress,
  String? mainUrl,
  PiDiag? lastDiag,
  bool probePrinters = false,
  bool discover = true,
  DateTime Function() now = DateTime.now,
}) async {
  Future<T?> guard<T>(Future<T?> f, Duration t) async {
    try {
      return await f.timeout(t);
    } catch (_) {
      return null;
    }
  }

  final deviceF = guard(probes.device(), const Duration(seconds: 3));
  final sessionF = savedAddress.isEmpty
      ? Future<AgentProbe?>.value()
      : guard(probes.session(savedAddress), const Duration(seconds: 4));
  final portF = savedAddress.isEmpty
      ? Future<PortState?>.value(PortState.unknown)
      : guard(probes.port(savedAddress), const Duration(seconds: 3));
  final mainF = (mainUrl ?? '').isEmpty
      ? Future<bool?>.value()
      : guard(probes.mainHealth(mainUrl!), const Duration(seconds: 4));
  final discoverF = discover
      ? guard(probes.discover(savedAddress.isEmpty ? null : savedAddress), const Duration(seconds: 5))
      : Future<List<DiscoveredPi>?>.value();

  var diagUnsupported = false;
  final diagF = savedAddress.isEmpty
      ? Future<PiDiag?>.value()
      : probes.diag().timeout(const Duration(seconds: 5)).then<PiDiag?>((d) => d).catchError((Object e) {
          if (e is AgentException && e.isNotFound) diagUnsupported = true;
          return null;
        });
  final printersF = probePrinters && savedAddress.isNotEmpty
      ? guard(probes.probePrinters(), const Duration(seconds: 7))
      : Future<List<PrinterTestResult>?>.value();

  final device = await deviceF;
  final internet = await guard(probes.internet(device), const Duration(seconds: 4));
  final session = await sessionF;
  final port = await portF ?? PortState.unknown;
  final main = await mainF;
  final diag = await diagF;
  final found = await discoverF ?? const <DiscoveredPi>[];
  final printerProbe = await printersF;

  // The saved address stopped answering (or now hosts a fresh card): is our
  // Pi answering somewhere else? Our key working there is the proof.
  DiscoveredPi? elsewhere;
  if (session == null || session.state == 'unconfigured') {
    final saved = normalizeAgentAddress(savedAddress);
    final candidates = found.where((p) => p.linked && p.address != saved).take(3).toList();
    final works = await Future.wait([
      for (final p in candidates) guard(probes.keyWorksAt(p.address), const Duration(milliseconds: 2500)),
    ]);
    for (var i = 0; i < candidates.length; i++) {
      if (works[i] == true) {
        elsewhere = candidates[i];
        break;
      }
    }
  }

  return CheckSnapshot(
    at: now(),
    savedAddress: savedAddress,
    device: device,
    internet: internet,
    mainFromTablet: main,
    piPort: port,
    session: session,
    diag: diag,
    diagUnsupported: diagUnsupported,
    lastDiag: lastDiag,
    discovered: found,
    piElsewhere: elsewhere,
    printerProbe: printerProbe,
  );
}

final diagProbesProvider = Provider<DiagProbes>((ref) => RealDiagProbes(ref));

/// Runs the checks with what the app knows (pairing, report main URL, last
/// Pi diag). Saves a fresh diag as the last-known one.
class ChecksRunner {
  final Ref ref;
  ChecksRunner(this.ref);

  Future<CheckSnapshot> run({bool probePrinters = false, bool discover = true}) async {
    final storage = ref.read(storageProvider);
    final s = await runChecks(
      ref.read(diagProbesProvider),
      savedAddress: ref.read(pairingProvider)?.address ?? '',
      mainUrl: storage.reportToken?.mainUrl ?? storage.getJson(kMainUrlKey),
      lastDiag: readLastPiDiag(storage),
      probePrinters: probePrinters,
      discover: discover,
    );
    if (s.diag != null) await saveLastPiDiag(storage, s.diag!, force: true);
    return s;
  }
}

final checksRunnerProvider = Provider<ChecksRunner>((ref) => ChecksRunner(ref));

/// Where the tablet remembers main's URL even after the report token is
/// cleared (a 401) — the main-from-tablet check still needs it.
const String kMainUrlKey = 'diag_main_url';

PiDiag? readLastPiDiag(AppStorage storage) {
  try {
    final raw = storage.getJson(AppStorage.kLastPiDiag);
    if (raw == null) return null;
    final m = jsonDecode(raw);
    return m is Map<String, dynamic> ? PiDiag.fromStored(m) : null;
  } catch (_) {
    return null;
  }
}

/// Saves [d] as the last-known diag, at most every 5 min unless [force].
Future<void> saveLastPiDiag(AppStorage storage, PiDiag d, {bool force = false}) async {
  if (!force) {
    final prev = readLastPiDiag(storage);
    final at = prev?.fetchedAt;
    if (at != null && DateTime.now().difference(at) < const Duration(minutes: 5)) return;
  }
  await storage.setJson(AppStorage.kLastPiDiag, jsonEncode(d.toJson()));
}
