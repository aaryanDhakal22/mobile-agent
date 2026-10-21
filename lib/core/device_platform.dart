import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the tablet checks read from Android (MainActivity's "quibase/device"
/// channel, DeviceChannel.kt).
class DeviceChecks {
  final int sdk;
  final String model;
  final String manufacturer;
  final bool notifications;
  final bool fullScreen;
  final bool battery;
  final bool installs;
  final int alarmVolume;
  final int alarmMax;
  final bool wifi;
  final bool ethernet;

  /// Android has confirmed this network reaches the internet.
  final bool validated;

  const DeviceChecks({
    this.sdk = 0,
    this.model = '',
    this.manufacturer = '',
    this.notifications = true,
    this.fullScreen = true,
    this.battery = true,
    this.installs = true,
    this.alarmVolume = 0,
    this.alarmMax = 0,
    this.wifi = true,
    this.ethernet = false,
    this.validated = true,
  });

  /// Alarm volume in percent (null when unknown, e.g. off-device).
  int? get alarmPercent => alarmMax <= 0 ? null : (alarmVolume * 100 / alarmMax).round();
  bool get alarmQuiet => (alarmPercent ?? 100) < 50;
  bool get onNetwork => wifi || ethernet;

  /// Every check the setup wizard asks for is OK (volume included).
  bool get allGood => notifications && fullScreen && battery && installs && !alarmQuiet;

  factory DeviceChecks.fromMap(Map<String, Object?> m) {
    bool b(String k, [bool d = true]) => m[k] is bool ? m[k]! as bool : d;
    int i(String k) => m[k] is int ? m[k]! as int : 0;
    return DeviceChecks(
      sdk: i('sdk'),
      model: '${m['model'] ?? ''}',
      manufacturer: '${m['manufacturer'] ?? ''}',
      notifications: b('notifications'),
      fullScreen: b('fullScreen'),
      battery: b('battery'),
      installs: b('installs'),
      alarmVolume: i('alarmVolume'),
      alarmMax: i('alarmMax'),
      wifi: b('wifi'),
      ethernet: b('ethernet', false),
      validated: b('validated'),
    );
  }

  Map<String, Object?> toReport() => {
    'notifications': notifications,
    'full_screen': fullScreen,
    'battery': battery,
    'installs': installs,
    'alarm_volume_pct': alarmPercent,
  };
}

/// The settings screens a tablet check can open.
enum DeviceSetting { notifications, fullScreen, battery, installs, sound, wifi }

/// The Android side of the tablet checks. Off-device (tests, desktop) every
/// call is harmless and [checks] returns null.
class DevicePlatform {
  static const _ch = MethodChannel('quibase/device');

  Future<DeviceChecks?> checks() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('checks');
      return m == null ? null : DeviceChecks.fromMap(m);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> requestNotifications() async {
    try {
      await _ch.invokeMethod('requestNotifications');
    } on MissingPluginException {
      // off-device
    } on PlatformException {
      // nothing to do
    }
  }

  /// Opens the settings page for [s]; false when nothing could be opened.
  Future<bool> openSettings(DeviceSetting s) async {
    try {
      return await _ch.invokeMethod<bool>('openSettings', {'kind': s.name}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

final devicePlatformProvider = Provider<DevicePlatform>((_) => DevicePlatform());
