import 'package:shared_preferences/shared_preferences.dart';

/// What the tablet remembers about its pairing with the agent.
class Pairing {
  final String address; // as normalized base URL, e.g. http://192.168.1.219:8080
  final String deviceKey; // qagt_… — sent as X-Agent-Device-Key
  final String deviceName;
  final String deviceId;

  const Pairing({required this.address, required this.deviceKey, this.deviceName = '', this.deviceId = ''});

  Pairing copyWith({String? address}) =>
      Pairing(address: address ?? this.address, deviceKey: deviceKey, deviceName: deviceName, deviceId: deviceId);
}

/// Thin wrapper over SharedPreferences so keys live in one place.
class AppStorage {
  static const _kAddress = 'agent_address';
  static const _kKey = 'device_key';
  static const _kName = 'device_name';
  static const _kId = 'device_id';
  static const _kSound = 'alert_sound';
  static const _kTheme = 'theme_mode';

  // Setup wizard + troubleshooting (JSON blobs owned by their features).
  static const kSetupProgress = 'setup_progress_v1';
  static const kGuideSession = 'guide_session_v1';
  static const kLastPiDiag = 'last_pi_diag';
  static const kDiagOutbox = 'diag_outbox';
  static const kLocalLog = 'local_log';
  static const kTabletChecksPrompted = 'tablet_checks_prompted';
  static const kNoOrdersSnoozedUntil = 'no_orders_snoozed_until';
  static const _kReportToken = 'report_token';
  static const _kMainUrl = 'report_main_url';

  final SharedPreferences prefs;
  const AppStorage(this.prefs);

  Pairing? readPairing() {
    final address = prefs.getString(_kAddress) ?? '';
    final key = prefs.getString(_kKey) ?? '';
    if (address.isEmpty || key.isEmpty) return null;
    return Pairing(
      address: address,
      deviceKey: key,
      deviceName: prefs.getString(_kName) ?? '',
      deviceId: prefs.getString(_kId) ?? '',
    );
  }

  /// Last address used, kept after unpairing so re-pairing is one field less.
  String get lastAddress => prefs.getString(_kAddress) ?? '';
  String get lastDeviceName => prefs.getString(_kName) ?? '';

  Future<void> writePairing(Pairing p) async {
    await prefs.setString(_kAddress, p.address);
    await prefs.setString(_kKey, p.deviceKey);
    await prefs.setString(_kName, p.deviceName);
    await prefs.setString(_kId, p.deviceId);
  }

  /// Wipes the key (the address + name stay as pairing-screen defaults).
  Future<void> clearKey() async {
    await prefs.remove(_kKey);
    await prefs.remove(_kId);
  }

  String? get alertSound => prefs.getString(_kSound);
  Future<void> setAlertSound(String name) => prefs.setString(_kSound, name);

  /// light | dark | system (null = never chosen).
  String? get themeMode => prefs.getString(_kTheme);
  Future<void> setThemeMode(String mode) => prefs.setString(_kTheme, mode);

  Future<void> setDeviceName(String name) => prefs.setString(_kName, name);

  /// The report-only key for main (see ReportSender) and where main is.
  ({String token, String mainUrl})? get reportToken {
    final t = prefs.getString(_kReportToken) ?? '';
    final u = prefs.getString(_kMainUrl) ?? '';
    return t.isEmpty || u.isEmpty ? null : (token: t, mainUrl: u);
  }

  Future<void> setReportToken(String token, String mainUrl) async {
    await prefs.setString(_kReportToken, token);
    await prefs.setString(_kMainUrl, mainUrl);
  }

  Future<void> clearReportToken() async {
    await prefs.remove(_kReportToken);
  }

  String? getJson(String key) => prefs.getString(key);
  Future<void> setJson(String key, String json) => prefs.setString(key, json);
  Future<void> remove(String key) => prefs.remove(key);
}
