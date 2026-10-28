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

  /// Pi 2.3.4: how many times the phrase is said per callout, 1–3; null =
  /// an older Pi without the setting (the Repeat slider is hidden and the
  /// field is never sent).
  final int? repeat;

  static const int minRepeat = 1;
  static const int maxRepeat = 3;

  /// 1.9.2: the percent of READY callouts said with a fun line instead
  /// of the normal phrase, 0–100; null = an older Pi (the Fun lines card is
  /// hidden and the field is never sent).
  final int? funChance;

  /// 1.9.2: the store's own fun lines, one per line ('' = the hub's
  /// built-in lines; `{n}` = the spoken ticket number); null = an older Pi.
  final String? funLines;

  /// 1.9.2: the percent of READY callouts said by a random guest voice
  /// instead of the chosen one, 0–50; null = an older Pi.
  final int? guestChance;

  /// 1.9.2: the guest voice ids, comma-separated ('' = every online
  /// voice); null = an older Pi.
  final String? guestVoices;

  static const int maxFunChance = 100;
  static const int maxFunLines = 10;
  static const int maxFunLineLength = 120;
  static const int maxGuestChance = 50;
  static const int maxGuestVoices = 10;

  const CalloutSettings({
    this.enabled = true,
    this.voice = '',
    this.volume = 90,
    this.musicDip = 70,
    this.restoreSeconds = 1.5,
    this.chime = true,
    this.repeat,
    this.funChance,
    this.funLines,
    this.guestChance,
    this.guestVoices,
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
    repeat: jIntOrNull(j['repeat'])?.clamp(minRepeat, maxRepeat),
    funChance: jIntOrNull(j['fun_chance'])?.clamp(0, maxFunChance),
    funLines: j['fun_lines'] is String ? j['fun_lines'] as String : null,
    guestChance: jIntOrNull(j['guest_chance'])?.clamp(0, maxGuestChance),
    guestVoices: j['guest_voices'] is String ? j['guest_voices'] as String : null,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'voice': voice,
    'volume': volume,
    'music_dip': musicDip,
    'restore_seconds': restoreSeconds,
    'chime': chime,
    'repeat': ?repeat,
    'fun_chance': ?funChance,
    'fun_lines': ?funLines,
    'guest_chance': ?guestChance,
    'guest_voices': ?guestVoices,
  };

  /// The guest voice ids ([guestVoices] split on commas); empty = every
  /// online voice.
  List<String> get guestVoiceIds => [
    for (final id in (guestVoices ?? '').split(','))
      if (id.trim().isNotEmpty) id.trim(),
  ];

  CalloutSettings copyWith({
    bool? enabled,
    String? voice,
    int? volume,
    int? musicDip,
    double? restoreSeconds,
    bool? chime,
    int? repeat,
    int? funChance,
    String? funLines,
    int? guestChance,
    String? guestVoices,
  }) => CalloutSettings(
    enabled: enabled ?? this.enabled,
    voice: voice ?? this.voice,
    volume: volume ?? this.volume,
    musicDip: musicDip ?? this.musicDip,
    restoreSeconds: restoreSeconds ?? this.restoreSeconds,
    chime: chime ?? this.chime,
    repeat: repeat ?? this.repeat,
    funChance: funChance ?? this.funChance,
    funLines: funLines ?? this.funLines,
    guestChance: guestChance ?? this.guestChance,
    guestVoices: guestVoices ?? this.guestVoices,
  );

  @override
  bool operator ==(Object other) =>
      other is CalloutSettings &&
      other.enabled == enabled &&
      other.voice == voice &&
      other.volume == volume &&
      other.musicDip == musicDip &&
      other.restoreSeconds == restoreSeconds &&
      other.chime == chime &&
      other.repeat == repeat &&
      other.funChance == funChance &&
      other.funLines == funLines &&
      other.guestChance == guestChance &&
      other.guestVoices == guestVoices;

  @override
  int get hashCode => Object.hash(
    enabled,
    voice,
    volume,
    musicDip,
    restoreSeconds,
    chime,
    repeat,
    funChance,
    funLines,
    guestChance,
    guestVoices,
  );
}

/// What is wrong with the fun lines typed in [text] (the Pi's rule: at most
/// 10 non-empty lines, each at most 120 characters), or null when they are
/// fine.
String? funLinesProblem(String text) {
  final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.length > CalloutSettings.maxFunLines) {
    return 'At most ${CalloutSettings.maxFunLines} lines (now ${lines.length}).';
  }
  for (var i = 0; i < lines.length; i++) {
    final len = lines[i].trimRight().length;
    if (len > CalloutSettings.maxFunLineLength) {
      return 'Line ${i + 1} is too long ($len letters; at most ${CalloutSettings.maxFunLineLength}).';
    }
  }
  return null;
}

/// One voice the hub offers.
class CalloutVoice {
  final String id;
  final String name;
  final String about;
  final int ready; // numbers 1..999 rendered
  final int total;

  /// 1.9.2: an ElevenLabs voice — each number is made over the internet
  /// the first time it is said, then kept ([ready] = how many are kept).
  final bool online;
  const CalloutVoice({
    required this.id,
    this.name = '',
    this.about = '',
    this.ready = 0,
    this.total = 999,
    this.online = false,
  });

  factory CalloutVoice.fromJson(Map<String, dynamic> j) => CalloutVoice(
    id: jStr(j['id']),
    name: jStr(j['name']),
    about: jStr(j['about']),
    ready: jInt(j['ready']),
    total: jInt(j['total'], 999),
    online: jBool(j['online']),
  );

  String get label => name.isEmpty ? id : name;

  /// How far along the voice is, for the voice picker: '' when every
  /// number is ready.
  String get status => online
      ? 'Online (ElevenLabs) · made on first use'
      : (ready < total ? 'getting ready $ready/$total' : '');
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

  /// 1.9.2: it speaks fun lines (`fun_chance`, `fun_lines`).
  final bool fun;

  /// 1.9.2: it speaks some callouts in a guest voice (`guest_chance`,
  /// `guest_voices`).
  final bool guest;

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
    this.fun = false,
    this.guest = false,
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
      fun: jBool(j['fun']),
      guest: jBool(j['guest']),
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
