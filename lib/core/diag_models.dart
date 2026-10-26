import 'json.dart';
import 'time.dart';

/// `GET /api/diag` — the Pi's view of itself (contract/agent.md §2.6).
class PiDiag {
  final String version;
  final String hostname;
  final String storeName;
  final int uptimeSeconds;

  /// connected | connecting | rejected | unconfigured
  final String mainState;

  /// The Pi could reach main's /health just now (null = unknown).
  final bool? mainReachable;
  final String mainLastError;
  final PiHealth health;

  /// Short problem codes: sd_errors, rootfs_ro, under_voltage, ntp,
  /// health_stale, main_down, printer_down.
  final List<String> problems;
  final List<DiagPrinter> printers;
  final DateTime? lastArrivedAt;
  final int openBatchOrders;
  final int waiting;

  /// Inside opening hours (null = the Pi doesn't know the hours).
  final bool? openNow;
  final int quietAlertMinutes;

  /// When this snapshot was taken on the tablet (not part of the wire shape).
  final DateTime? fetchedAt;

  const PiDiag({
    this.version = '',
    this.hostname = '',
    this.storeName = '',
    this.uptimeSeconds = 0,
    this.mainState = '',
    this.mainReachable,
    this.mainLastError = '',
    this.health = const PiHealth(),
    this.problems = const [],
    this.printers = const [],
    this.lastArrivedAt,
    this.openBatchOrders = 0,
    this.waiting = 0,
    this.openNow,
    this.quietAlertMinutes = 90,
    this.fetchedAt,
  });

  bool get connectedToMain => mainState == 'connected';
  bool has(String problem) => problems.contains(problem);
  List<DiagPrinter> get printersDown => printers.where((p) => !p.up).toList();

  factory PiDiag.fromJson(Map<String, dynamic> json, {DateTime? fetchedAt}) {
    final main = jMap(json['main']);
    final orders = jMap(json['orders']);
    return PiDiag(
      version: jStr(json['version']),
      hostname: jStr(json['hostname']),
      storeName: jStr(json['store_name']),
      uptimeSeconds: jInt(json['uptime_s']),
      mainState: jStr(main['state']),
      mainReachable: main['reachable'] is bool ? main['reachable'] as bool : null,
      mainLastError: jStr(main['last_error']),
      health: PiHealth.fromJson(jMap(json['health'])),
      problems: [for (final p in (json['problems'] is List ? json['problems'] as List : const [])) '$p'],
      printers: jList(json['printers'], DiagPrinter.fromJson),
      lastArrivedAt: jDate(orders['last_arrived_at']),
      openBatchOrders: jInt(orders['open_batch_orders']),
      waiting: jInt(orders['waiting']),
      openNow: json['open_now'] is bool ? json['open_now'] as bool : null,
      quietAlertMinutes: json['quiet_alert_minutes'] == null ? 90 : jInt(json['quiet_alert_minutes']),
      fetchedAt: fetchedAt ?? timeNow(),
    );
  }

  /// For storing the last-known diag on the tablet (and in reports).
  Map<String, Object?> toJson() => {
    'version': version,
    'hostname': hostname,
    'store_name': storeName,
    'uptime_s': uptimeSeconds,
    'main': {'state': mainState, 'reachable': mainReachable, 'last_error': mainLastError},
    'health': health.toJson(),
    'problems': problems,
    'printers': [for (final p in printers) p.toJson()],
    'orders': {
      'last_arrived_at': lastArrivedAt?.toUtc().toIso8601String(),
      'open_batch_orders': openBatchOrders,
      'waiting': waiting,
    },
    'open_now': openNow,
    'quiet_alert_minutes': quietAlertMinutes,
    'fetched_at': fetchedAt?.toUtc().toIso8601String(),
  };

  factory PiDiag.fromStored(Map<String, dynamic> json) => PiDiag.fromJson(json, fetchedAt: jDate(json['fetched_at']));
}

class PiHealth {
  final int sdErrors;
  final bool rootfsReadOnly;
  final bool underVoltageNow;
  final bool underVoltageSinceBoot;
  final String ntpSynced;
  final double? tempC;
  final bool fileStale;

  const PiHealth({
    this.sdErrors = 0,
    this.rootfsReadOnly = false,
    this.underVoltageNow = false,
    this.underVoltageSinceBoot = false,
    this.ntpSynced = '',
    this.tempC,
    this.fileStale = false,
  });

  /// SD-card trouble (errors logged, or the card went read-only).
  bool get sdTrouble => sdErrors > 0 || rootfsReadOnly;
  bool get powerTrouble => underVoltageNow || underVoltageSinceBoot;

  factory PiHealth.fromJson(Map<String, dynamic> json) => PiHealth(
    sdErrors: jInt(json['sd_errors']),
    rootfsReadOnly: json['rootfs_ro'] == true,
    underVoltageNow: json['under_voltage_now'] == true,
    underVoltageSinceBoot: json['under_voltage_since_boot'] == true,
    ntpSynced: jStr(json['ntp_synced']),
    tempC: json['temp_c'] is num ? (json['temp_c'] as num).toDouble() : null,
    fileStale: json['file_stale'] == true,
  );

  Map<String, Object?> toJson() => {
    'sd_errors': sdErrors,
    'rootfs_ro': rootfsReadOnly,
    'under_voltage_now': underVoltageNow,
    'under_voltage_since_boot': underVoltageSinceBoot,
    'ntp_synced': ntpSynced,
    'temp_c': tempC,
    'file_stale': fileStale,
  };
}

class DiagPrinter {
  final String id;
  final String name;
  final String ip;
  final bool up;
  final bool isReceipt;
  final String lastError;
  final DateTime? downSince;

  const DiagPrinter({
    required this.id,
    required this.name,
    this.ip = '',
    this.up = false,
    this.isReceipt = false,
    this.lastError = '',
    this.downSince,
  });

  factory DiagPrinter.fromJson(Map<String, dynamic> json) => DiagPrinter(
    id: jStr(json['id']),
    name: jStr(json['name']),
    ip: jStr(json['ip']),
    up: json['up'] == true,
    isReceipt: json['is_receipt'] == true,
    lastError: jStr(json['last_error']),
    downSince: jDate(json['down_since']),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'ip': ip,
    'up': up,
    'is_receipt': isReceipt,
    'last_error': lastError,
    'down_since': downSince?.toUtc().toIso8601String(),
  };
}

/// One printer's answer to `POST /api/printers/test`.
class PrinterTestResult {
  final String id;
  final String name;
  final bool ok;

  /// unreachable | write_failed | not_configured
  final String errorCode;
  final String error;

  const PrinterTestResult({
    required this.id,
    required this.name,
    required this.ok,
    this.errorCode = '',
    this.error = '',
  });

  factory PrinterTestResult.fromJson(Map<String, dynamic> json) => PrinterTestResult(
    id: jStr(json['id']),
    name: jStr(json['name']),
    ok: json['ok'] == true,
    errorCode: jStr(json['error_code']),
    error: jStr(json['error']),
  );
}

/// `POST /api/pairing/code` → `{code, expires_at}`.
class PairingCode {
  final String code;
  final DateTime? expiresAt;
  const PairingCode({required this.code, this.expiresAt});

  factory PairingCode.fromJson(Map<String, dynamic> json) =>
      PairingCode(code: jStr(json['code']), expiresAt: jDate(json['expires_at']));
}

/// `POST /api/device/report-token` → a report-only key for main.
class ReportToken {
  final String token;
  final String mainUrl;
  const ReportToken({required this.token, required this.mainUrl});

  bool get isEmpty => token.isEmpty || mainUrl.isEmpty;

  factory ReportToken.fromJson(Map<String, dynamic> json) =>
      ReportToken(token: jStr(json['token']), mainUrl: jStr(json['main_url']));
}
