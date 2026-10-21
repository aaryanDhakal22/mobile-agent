import 'json.dart';

/// One printer's last probe, from `GET /api/printers` (read-only — printers
/// are configured in main's web app and pushed to the agent).
class PrinterStatus {
  final String name;
  final String ip;
  final bool up;
  final DateTime? lastChecked;
  final String lastError;
  final DateTime? upSince;
  final DateTime? downSince;

  const PrinterStatus({
    required this.name,
    this.ip = '',
    this.up = false,
    this.lastChecked,
    this.lastError = '',
    this.upSince,
    this.downSince,
  });

  bool get hasIP => ip.isNotEmpty;

  factory PrinterStatus.fromJson(Map<String, dynamic> json) => PrinterStatus(
    name: jStr(json['name']),
    ip: jStr(json['ip']),
    up: jBool(json['up']),
    lastChecked: jDate(json['last_checked']),
    lastError: jStr(json['last_error']),
    upSince: jDate(json['up_since']),
    downSince: jDate(json['down_since']),
  );
}
