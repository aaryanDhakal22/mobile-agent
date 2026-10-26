import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/device_platform.dart';
import '../../core/local_log.dart';
import '../../core/providers.dart';
import '../../core/storage.dart';
import '../../core/time.dart';
import 'checks.dart';
import 'guides.dart';

// Diagnostics reports (report v1, contract/main.md): what the tablet and the
// Pi saw, sent to the owner. Sending goes through the Pi when it can, straight
// to main with the tablet's report-only token when the Pi is the problem, and
// otherwise waits in a small outbox on the tablet.

/// Shown in reports when Android can't tell us (tests, desktop).
const String kAppVersionFallback = '1.3.0';

/// main's route for reports sent straight from a tablet.
const String kDirectReportPath = '/store/v1/tablet/diag-reports';
const String kReportKeyHeader = 'X-Quibase-Report-Key';

/// The outbox keeps at most this many reports (oldest dropped).
const int kOutboxMax = 20;

/// A random (v4) UUID.
String uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// One report, as JSON (report v1).
class DiagReport {
  final Map<String, Object?> json;
  const DiagReport(this.json);

  String get id => '${json['id']}';
  String get kind => '${json['kind']}';
  String get outcome => '${json['outcome']}';
}

/// What a report says about the tablet and the Pi, gathered at send time.
class ReportContext {
  final String tabletName;
  final String deviceId;
  final String appVersion;
  final int sdk;
  final String model;
  final Map<String, Object?>? deviceChecks;
  final String piAddress;
  final String piVersion;
  final String store;
  final Map<String, Object?>? lastDiag;
  final List<String> log;

  const ReportContext({
    this.tabletName = '',
    this.deviceId = '',
    this.appVersion = kAppVersionFallback,
    this.sdk = 0,
    this.model = '',
    this.deviceChecks,
    this.piAddress = '',
    this.piVersion = '',
    this.store = '',
    this.lastDiag,
    this.log = const [],
  });
}

String _cap(String s, int n) => s.length <= n ? s : s.substring(0, n);

/// Builds report v1. [kind]: setup | guide | manual | full_check.
/// [outcome]: ok | fixed | needs_part | needs_owner | not_fixed | abandoned | info.
DiagReport composeReport({
  required String kind,
  String? scenario,
  required String outcome,
  String headline = '',
  String? cause,
  String? fixedBy,
  String? note,
  List<StepRecord> steps = const [],
  Map<String, Object?>? checks,
  required ReportContext ctx,
  DateTime? now,
  String? id,
}) {
  final log = ctx.log.length > 300 ? ctx.log.sublist(ctx.log.length - 300) : ctx.log;
  return DiagReport({
    'v': 1,
    'id': id ?? uuidV4(),
    'created_at': (now ?? timeNow()).toUtc().toIso8601String(),
    'kind': kind,
    'scenario': scenario,
    'outcome': outcome,
    'headline': _cap(headline, 120),
    'cause': cause,
    'fixed_by': fixedBy,
    'note': note == null ? null : _cap(note.trim(), 500),
    'steps': [for (final s in steps) s.toJson()],
    'checks': checks ?? const <String, Object?>{},
    'tablet': {
      'name': ctx.tabletName,
      'device_id': ctx.deviceId,
      'app_version': ctx.appVersion,
      'android_sdk': ctx.sdk,
      'model': ctx.model,
      'checks': ctx.deviceChecks ?? const <String, Object?>{},
    },
    'pi': {'address': ctx.piAddress, 'version': ctx.piVersion, 'store': ctx.store, 'last_diag': ctx.lastDiag},
    'log': log,
  });
}

enum ReportOutcome {
  /// Delivered (via the Pi or straight to main).
  sent,

  /// In the outbox; retried later.
  saved,
}

/// Sends reports: via the Pi → straight to main with the report token (minted
/// via the Pi, re-minted once on a 401) → the outbox.
class ReportSender {
  final AppStorage storage;
  final AgentClient? Function() piClient;
  final http.Client Function() httpClient;
  final Future<ReportContext> Function() context;
  final LocalLog? log;

  ReportSender({
    required this.storage,
    required this.piClient,
    http.Client Function()? httpClient,
    Future<ReportContext> Function()? context,
    this.log,
  }) : httpClient = httpClient ?? http.Client.new,
       context = context ?? (() async => const ReportContext());

  bool _flushing = false;

  /// Builds a report with everything the tablet knows right now (tablet,
  /// Pi, last diag, local log). The setup wizard uses this too.
  Future<DiagReport> buildReport({
    required String kind,
    String? scenario,
    required String outcome,
    String headline = '',
    String? cause,
    String? fixedBy,
    String? note,
    List<StepRecord> steps = const [],
    Map<String, Object?>? checks,
  }) async => composeReport(
    kind: kind,
    scenario: scenario,
    outcome: outcome,
    headline: headline,
    cause: cause,
    fixedBy: fixedBy,
    note: note,
    steps: steps,
    checks: checks,
    ctx: await context(),
  );

  /// Sends [r] now, or saves it for later. Never throws.
  Future<ReportOutcome> send(DiagReport r) async {
    final res = await _deliver(r);
    if (res == _Try.sent) {
      log?.add('report', 'sent ${r.kind}/${r.outcome} ${r.id}');
      unawaited(flushOutbox());
      return ReportOutcome.sent;
    }
    await _enqueue(r);
    log?.warn('report', 'saved for later ${r.kind}/${r.outcome} ${r.id}');
    return ReportOutcome.saved;
  }

  /// Retries the outbox (app start, reconnect, every 10 min). Returns how
  /// many were delivered.
  Future<int> flushOutbox() async {
    if (_flushing) return 0;
    _flushing = true;
    var sent = 0;
    try {
      final queue = readOutbox();
      for (final r in queue) {
        final res = await _deliver(r);
        if (res != _Try.sent) break;
        sent++;
        await _remove(r.id);
      }
    } finally {
      _flushing = false;
    }
    return sent;
  }

  /// Mints a report token now (while the Pi answers) so a report can still
  /// reach the owner when the Pi is down later.
  Future<void> ensureToken() async {
    if (storage.reportToken != null) return;
    final pi = piClient();
    if (pi != null) await _mint(pi);
  }

  // --- delivery ---------------------------------------------------------------

  Future<_Try> _deliver(DiagReport r) async {
    final pi = piClient();
    var piUp = false;
    if (pi != null) {
      try {
        await pi.sendReport(r.json);
        return _Try.sent;
      } on AgentException catch (e) {
        // main's limits: don't hammer it another way.
        if (e.statusCode == 429) return _Try.later;
        piUp = !e.isNetwork;
        log?.warn('report', 'via Pi failed: ${e.statusCode ?? 'network'} ${e.code ?? e.message}');
      } catch (e) {
        log?.warn('report', 'via Pi failed: $e');
      }
    }
    return _direct(r, pi: piUp ? pi : null);
  }

  Future<_Try> _direct(DiagReport r, {AgentClient? pi}) async {
    var tok = storage.reportToken;
    if (tok == null && pi != null) tok = await _mint(pi);
    if (tok == null) return _Try.later;
    var status = await _post(r, tok.token, tok.mainUrl);
    if (status == 401) {
      await storage.clearReportToken();
      final fresh = pi == null ? null : await _mint(pi);
      if (fresh == null) return _Try.later;
      status = await _post(r, fresh.token, fresh.mainUrl);
    }
    // 200 = main already has it (a resend).
    return status == 200 || status == 202 ? _Try.sent : _Try.later;
  }

  Future<int?> _post(DiagReport r, String token, String mainUrl) async {
    final c = httpClient();
    try {
      final resp = await c
          .post(
            Uri.parse('${mainUrl.replaceAll(RegExp(r'/+$'), '')}$kDirectReportPath'),
            headers: {kReportKeyHeader: token, 'Content-Type': 'application/json'},
            body: jsonEncode(r.json),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode >= 300) log?.warn('report', 'direct: HTTP ${resp.statusCode}');
      return resp.statusCode;
    } catch (e) {
      log?.warn('report', 'direct failed: $e');
      return null;
    } finally {
      c.close();
    }
  }

  Future<({String token, String mainUrl})?> _mint(AgentClient pi) async {
    try {
      final t = await pi.reportToken();
      if (t.isEmpty) return null;
      await storage.setReportToken(t.token, t.mainUrl);
      await storage.setJson(kMainUrlKey, t.mainUrl);
      return (token: t.token, mainUrl: t.mainUrl);
    } catch (e) {
      log?.warn('report', 'report token: $e');
      return null;
    }
  }

  // --- outbox -----------------------------------------------------------------

  List<DiagReport> readOutbox() {
    try {
      final raw = storage.getJson(AppStorage.kDiagOutbox);
      if (raw == null) return [];
      return [
        for (final m in jsonDecode(raw) as List)
          if (m is Map) DiagReport(Map<String, Object?>.from(m)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _write(List<DiagReport> q) =>
      storage.setJson(AppStorage.kDiagOutbox, jsonEncode([for (final r in q) r.json]));

  Future<void> _enqueue(DiagReport r) async {
    final q = readOutbox()..removeWhere((x) => x.id == r.id);
    q.add(r);
    if (q.length > kOutboxMax) q.removeRange(0, q.length - kOutboxMax);
    await _write(q);
  }

  Future<void> _remove(String id) async => _write(readOutbox()..removeWhere((x) => x.id == id));
}

enum _Try { sent, later }

/// The installed Quibase version name ("1.3.0"), from the 'quibase/install'
/// channel; [kAppVersionFallback] off-device.
Future<String> installedVersionName() async {
  try {
    final m = await const MethodChannel('quibase/install').invokeMapMethod<String, Object?>('version');
    final v = '${m?['versionName'] ?? ''}';
    return v.isEmpty ? kAppVersionFallback : v;
  } on MissingPluginException {
    return kAppVersionFallback;
  } on PlatformException {
    return kAppVersionFallback;
  }
}

/// Gathers [ReportContext] from the app.
Future<ReportContext> gatherReportContext(Ref ref) async {
  final pairing = ref.read(pairingProvider);
  final storage = ref.read(storageProvider);
  DeviceChecks? dc;
  try {
    dc = await ref.read(devicePlatformProvider).checks().timeout(const Duration(seconds: 2));
  } catch (_) {}
  final last = readLastPiDiag(storage);
  return ReportContext(
    tabletName: pairing?.deviceName ?? storage.lastDeviceName,
    deviceId: pairing?.deviceId ?? '',
    appVersion: await installedVersionName(),
    sdk: dc?.sdk ?? 0,
    model: [dc?.manufacturer ?? '', dc?.model ?? ''].where((s) => s.isNotEmpty).join(' '),
    deviceChecks: dc?.toReport(),
    piAddress: pairing?.address ?? storage.lastAddress,
    piVersion: last?.version ?? '',
    store: last?.storeName ?? '',
    lastDiag: last?.toJson(),
    log: ref.read(localLogProvider).lines,
  );
}

/// The app's report sender. The setup wizard sends its reports through this:
///
/// ```dart
/// final sender = ref.read(reportSenderProvider);
/// final r = await sender.buildReport(kind: 'setup', scenario: 'setup', outcome: 'ok', headline: '…');
/// final outcome = await sender.send(r); // ReportOutcome.sent | .saved
/// ```
final reportSenderProvider = Provider<ReportSender>((ref) {
  return ReportSender(
    storage: ref.watch(storageProvider),
    piClient: () => ref.read(agentClientProvider),
    context: () => gatherReportContext(ref),
    log: ref.read(localLogProvider),
  );
});
