import 'json.dart';

/// Pi 2.3.0 (contract/agent.md §2.9.8–2.9.10): terminal changes to POS
/// checks, finishing orders and the store hub's order callout.

/// One line added to or removed from a POS check at the terminal.
class ChangeLine {
  final String name;
  final int quantity;
  final bool kitchen;
  const ChangeLine({required this.name, this.quantity = 1, this.kitchen = false});

  factory ChangeLine.fromJson(Map<String, dynamic> j) =>
      ChangeLine(name: jStr(j['name']), quantity: jInt(j['quantity'], 1), kitchen: jBool(j['kitchen']));
}

/// A terminal change to a check already on the tablet (`status.pos_change`).
/// It rings (the blue CHANGED alert) until someone presses OK (`acked_at`);
/// after OK the ticket keeps a CHANGED tag until ready (or 10 min).
class PosChange {
  final String id;
  final DateTime? at;

  /// cooking | back_to_cooking | ready | out
  final String kind;
  final String text;
  final List<ChangeLine> added;
  final List<ChangeLine> removed;
  final String driverName;
  final DateTime? ackedAt;

  const PosChange({
    required this.id,
    this.at,
    this.kind = 'cooking',
    this.text = '',
    this.added = const [],
    this.removed = const [],
    this.driverName = '',
    this.ackedAt,
  });

  static PosChange? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = jMap(raw);
    final id = jStr(j['id']);
    if (id.isEmpty) return null;
    return PosChange(
      id: id,
      at: jDate(j['at']),
      kind: jStr(j['kind'], 'cooking'),
      text: jStr(j['text']),
      added: jList(j['added'], ChangeLine.fromJson),
      removed: jList(j['removed'], ChangeLine.fromJson),
      driverName: jStr(j['driver_name']),
      ackedAt: jDate(j['acked_at']),
    );
  }

  /// Nobody pressed OK yet: the tablet rings.
  bool get pending => ackedAt == null;

  bool get isOut => kind == 'out';
  bool get backToCooking => kind == 'back_to_cooking';
}

/// How long a ticket keeps its CHANGED tag after OK (while still cooking).
const Duration kChangedTagFor = Duration(minutes: 10);

/// `settings.finishing`: online pickups finish this long after ready (0 =
/// never); terminal checks finish when the POS closes them (fixed).
class FinishingSettings {
  static const int maxMinutes = 240;
  final int onlinePickupMinutes;
  const FinishingSettings({this.onlinePickupMinutes = 30});

  factory FinishingSettings.fromJson(Map<String, dynamic> j) {
    final v = jIntOrNull(j['online_pickup_minutes']);
    return FinishingSettings(onlinePickupMinutes: (v == null || v < 0 || v > maxMinutes) ? 30 : v);
  }

  Map<String, int> toJson() => {'online_pickup_minutes': onlinePickupMinutes};

  @override
  bool operator ==(Object other) => other is FinishingSettings && other.onlinePickupMinutes == onlinePickupMinutes;

  @override
  int get hashCode => onlinePickupMinutes.hashCode;
}

/// `settings.callout`: the store hub's order callout (Settings › Order callout).
class CalloutSettings {
  final bool enabled;

  /// A voice id from the hub's list; '' = the hub's default.
  final String voice;
  final int volume; // 0-100
  final int musicDip; // 0-100: how far the music goes down
  final double restoreSeconds; // 0-10
  final bool chime;

  const CalloutSettings({
    this.enabled = true,
    this.voice = '',
    this.volume = 90,
    this.musicDip = 70,
    this.restoreSeconds = 1.5,
    this.chime = true,
  });

  factory CalloutSettings.fromJson(Map<String, dynamic> j) => CalloutSettings(
    enabled: jBool(j['enabled'], true),
    voice: jStr(j['voice']),
    volume: jInt(j['volume'], 90).clamp(0, 100),
    musicDip: jInt(j['music_dip'], 70).clamp(0, 100),
    restoreSeconds: (j['restore_seconds'] is num ? (j['restore_seconds'] as num).toDouble() : 1.5)
        .clamp(0, 10)
        .toDouble(),
    chime: jBool(j['chime'], true),
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'voice': voice,
    'volume': volume,
    'music_dip': musicDip,
    'restore_seconds': restoreSeconds,
    'chime': chime,
  };

  CalloutSettings copyWith({
    bool? enabled,
    String? voice,
    int? volume,
    int? musicDip,
    double? restoreSeconds,
    bool? chime,
  }) => CalloutSettings(
    enabled: enabled ?? this.enabled,
    voice: voice ?? this.voice,
    volume: volume ?? this.volume,
    musicDip: musicDip ?? this.musicDip,
    restoreSeconds: restoreSeconds ?? this.restoreSeconds,
    chime: chime ?? this.chime,
  );

  @override
  bool operator ==(Object other) =>
      other is CalloutSettings &&
      other.enabled == enabled &&
      other.voice == voice &&
      other.volume == volume &&
      other.musicDip == musicDip &&
      other.restoreSeconds == restoreSeconds &&
      other.chime == chime;

  @override
  int get hashCode => Object.hash(enabled, voice, volume, musicDip, restoreSeconds, chime);
}

/// One voice the hub offers.
class CalloutVoice {
  final String id;
  final String name;
  final String about;
  final int ready; // numbers 1..999 rendered
  final int total;
  const CalloutVoice({required this.id, this.name = '', this.about = '', this.ready = 0, this.total = 999});

  factory CalloutVoice.fromJson(Map<String, dynamic> j) => CalloutVoice(
    id: jStr(j['id']),
    name: jStr(j['name']),
    about: jStr(j['about']),
    ready: jInt(j['ready']),
    total: jInt(j['total'], 999),
  );

  String get label => name.isEmpty ? id : name;
}

/// The last callout the hub spoke.
class CalloutSpoken {
  final int number;
  final String kind;
  final String voice;
  final DateTime? at;
  final bool ok;
  final String error;
  const CalloutSpoken({this.number = 0, this.kind = '', this.voice = '', this.at, this.ok = false, this.error = ''});

  static CalloutSpoken? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = jMap(raw);
    return CalloutSpoken(
      number: jInt(j['number']),
      kind: jStr(j['kind']),
      voice: jStr(j['voice']),
      at: jDate(j['at']),
      ok: jBool(j['ok']),
      error: jStr(j['error']),
    );
  }
}

/// What the hub reports about its callout (`integration.callout`, the `hub`
/// of `GET /api/callout`); null before a hub with the callout reported.
class CalloutHubReport {
  final String voice;
  final String defaultVoice;
  final List<CalloutVoice> voices;
  final bool installed;
  final String error;
  final String renderingVoice;
  final int renderingDone;
  final int renderingTotal;
  final CalloutSpoken? last;

  /// Hub 0.2.2: it can make a preview for a tablet (`callout.render`).
  final bool preview;

  const CalloutHubReport({
    this.voice = '',
    this.defaultVoice = '',
    this.voices = const [],
    this.installed = false,
    this.error = '',
    this.renderingVoice = '',
    this.renderingDone = 0,
    this.renderingTotal = 0,
    this.last,
    this.preview = false,
  });

  static CalloutHubReport? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = jMap(raw);
    final r = jMap(j['rendering']);
    return CalloutHubReport(
      voice: jStr(j['voice']),
      defaultVoice: jStr(j['default_voice']),
      voices: jList(j['voices'], CalloutVoice.fromJson).where((v) => v.id.isNotEmpty).toList(),
      installed: jBool(j['installed']),
      error: jStr(j['error']),
      renderingVoice: jStr(r['voice']),
      renderingDone: jInt(r['done']),
      renderingTotal: jInt(r['total']),
      last: CalloutSpoken.fromJson(j['last']),
      preview: jBool(j['preview']),
    );
  }

  bool get rendering => renderingTotal > 0 && renderingVoice.isNotEmpty;
}

/// `GET /api/callout`.
class CalloutView {
  final CalloutSettings settings;
  final bool hubConnected;
  final CalloutHubReport? hub;

  /// Pi 2.3.2: `POST /api/callout/preview` exists — the card shows ON THIS
  /// TABLET (an older Pi: only ON THE STORE SPEAKER).
  final bool preview;
  const CalloutView({
    this.settings = const CalloutSettings(),
    this.hubConnected = false,
    this.hub,
    this.preview = false,
  });

  factory CalloutView.fromJson(Map<String, dynamic> j) => CalloutView(
    settings: CalloutSettings.fromJson(jMap(j['settings'])),
    hubConnected: jBool(j['hub_connected']),
    hub: CalloutHubReport.fromJson(j['hub']),
    preview: jBool(j['preview']),
  );
}
