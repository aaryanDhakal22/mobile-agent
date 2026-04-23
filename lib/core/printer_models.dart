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
    required this.ip,
    required this.up,
    required this.lastChecked,
    required this.lastError,
    required this.upSince,
    required this.downSince,
  });

  bool get hasIP => ip.isNotEmpty;

  factory PrinterStatus.fromJson(Map<String, dynamic> json) => PrinterStatus(
        name: json['name'] as String? ?? '',
        ip: json['ip'] as String? ?? '',
        up: json['up'] as bool? ?? false,
        lastChecked: _date(json['last_checked']),
        lastError: json['last_error'] as String? ?? '',
        upSince: _date(json['up_since']),
        downSince: _date(json['down_since']),
      );
}

DateTime? _date(dynamic v) {
  if (v == null) return null;
  if (v is String && v.isEmpty) return null;
  return DateTime.tryParse(v as String);
}
