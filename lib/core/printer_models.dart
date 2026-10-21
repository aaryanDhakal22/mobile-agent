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

/// A printer the Pi found on its network (TCP 9100), from
/// `GET /api/printers/found`. [known] = its IP or MAC matches a printer the
/// store already has.
class FoundPrinter {
  final String ip;
  final String mac;
  final bool known;

  /// The store's name for it when [known].
  final String printerName;

  const FoundPrinter({required this.ip, this.mac = '', this.known = false, this.printerName = ''});

  factory FoundPrinter.fromJson(Map<String, dynamic> json) => FoundPrinter(
    ip: jStr(json['ip']),
    mac: jStr(json['mac']),
    known: jBool(json['known']),
    printerName: jStr(json['printer_name']),
  );
}

/// The Pi's last network scan for printers.
class FoundPrinters {
  /// null = the Pi hasn't scanned yet.
  final DateTime? scannedAt;
  final bool scanning;
  final List<FoundPrinter> printers;

  const FoundPrinters({this.scannedAt, this.scanning = false, this.printers = const []});

  /// The ones the store doesn't have yet (offered with ADD).
  List<FoundPrinter> get unknown => printers.where((p) => !p.known && p.ip.isNotEmpty).toList();

  factory FoundPrinters.fromJson(Map<String, dynamic> json) => FoundPrinters(
    scannedAt: jDate(json['scanned_at']),
    scanning: jBool(json['scanning']),
    printers: jList(json['printers'], FoundPrinter.fromJson),
  );
}

/// `POST /api/printers/add` → the printer main created.
class AddedPrinter {
  final String id;
  final String name;
  final String ip;

  const AddedPrinter({this.id = '', this.name = '', this.ip = ''});

  factory AddedPrinter.fromJson(Map<String, dynamic> json) =>
      AddedPrinter(id: jStr(json['id']), name: jStr(json['name']), ip: jStr(json['ip']));
}
