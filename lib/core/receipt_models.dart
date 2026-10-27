import 'json.dart';

/// A text size on the printed tickets (kitchen item text, receipt footer).
enum ReceiptSize {
  normal('normal', 'Normal'),
  large('large', 'Large'),
  xlarge('xlarge', 'Extra large');

  final String wire;
  final String label;
  const ReceiptSize(this.wire, this.label);

  static ReceiptSize? parse(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

/// The size of the kitchen number on a kitchen ticket.
enum NumberSize {
  large('large', 'Large'),
  xlarge('xlarge', 'Extra large'),
  huge('huge', 'Huge');

  final String wire;
  final String label;
  const NumberSize(this.wire, this.label);

  static NumberSize? parse(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

/// The driver-report slip's text size (Pi 2.3). [large] is how it printed
/// before; [normal] (one size smaller) is the default.
enum DriverReportSize {
  small('small', 'Small'),
  normal('normal', 'Normal'),
  large('large', 'Large');

  final String wire;
  final String label;
  const DriverReportSize(this.wire, this.label);

  static DriverReportSize? parse(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

/// Most extra space the Pi takes between lines, in printer dots, and the
/// step the tablet's − / + move by.
const int kSpacingMaxDots = 48;
const int kSpacingStepDots = 4;

/// Extra space (printer dots, 0–[kSpacingMaxDots]) on kitchen tickets and
/// customer receipts (Pi 2.3): between an item and its first modifier
/// ([itemMod]), between modifiers ([modMod]), and after an item without
/// modifiers before the next item ([itemItem]). All 0 = how it always looked.
class LineSpacing {
  final int itemMod;
  final int modMod;
  final int itemItem;
  const LineSpacing({this.itemMod = 0, this.modMod = 0, this.itemItem = 0});

  static const LineSpacing none = LineSpacing();

  /// Missing / out-of-range values fall back to [fallback]'s.
  factory LineSpacing.fromJson(Object? raw, {LineSpacing fallback = none}) {
    if (raw is! Map) return fallback;
    final j = jMap(raw);
    int read(String key, int fb) {
      final v = jIntOrNull(j[key]);
      return v == null || v < 0 || v > kSpacingMaxDots ? fb : v;
    }

    return LineSpacing(
      itemMod: read('item_mod', fallback.itemMod),
      modMod: read('mod_mod', fallback.modMod),
      itemItem: read('item_item', fallback.itemItem),
    );
  }

  Map<String, Object?> toJson() => {'item_mod': itemMod, 'mod_mod': modMod, 'item_item': itemItem};

  LineSpacing copyWith({int? itemMod, int? modMod, int? itemItem}) => LineSpacing(
    itemMod: _clamp(itemMod ?? this.itemMod),
    modMod: _clamp(modMod ?? this.modMod),
    itemItem: _clamp(itemItem ?? this.itemItem),
  );

  static int _clamp(int v) => v.clamp(0, kSpacingMaxDots);

  @override
  bool operator ==(Object other) =>
      other is LineSpacing && other.itemMod == itemMod && other.modMod == modMod && other.itemItem == itemItem;

  @override
  int get hashCode => Object.hash(itemMod, modMod, itemItem);
}

/// Longest footer the Pi accepts.
const int kFooterMaxLength = 32;

/// Characters the Pi accepts in the footer (printable ASCII: letters, digits,
/// punctuation, space).
final RegExp kFooterAllowed = RegExp(r'[ -~]');

const Object _keep = Object();

/// The store's receipt settings (`GET/PUT /api/settings/receipt`, the `P`
/// object). [footerText] null = use the store default; '' = no footer.
class ReceiptPrefs {
  final ReceiptSize kitchenItemSize;
  final NumberSize kitchenNumberSize;
  final String? footerText;
  final ReceiptSize footerSize;
  final int copies;
  final bool showStoreAddress;
  final bool showPhone;
  final bool extraPaper;

  /// (Pi 2.3) The driver-report slip's text size, and the extra line spacing
  /// on kitchen tickets and receipts. A Pi without them leaves them out:
  /// read as the defaults, still sent on PUT.
  final DriverReportSize driverReportSize;
  final LineSpacing spacing;

  const ReceiptPrefs({
    this.kitchenItemSize = ReceiptSize.large,
    this.kitchenNumberSize = NumberSize.xlarge,
    this.footerText,
    this.footerSize = ReceiptSize.xlarge,
    this.copies = 1,
    this.showStoreAddress = true,
    this.showPhone = true,
    this.extraPaper = true,
    this.driverReportSize = DriverReportSize.normal,
    this.spacing = LineSpacing.none,
  });

  /// What prints today (the agent's defaults); used when the Pi's answer
  /// leaves a field out.
  static const ReceiptPrefs standard = ReceiptPrefs();

  bool get usesStoreFooter => footerText == null;

  /// Missing / unknown fields fall back to [fallback]'s.
  factory ReceiptPrefs.fromJson(Map<String, dynamic> json, {ReceiptPrefs fallback = standard}) {
    final copies = jIntOrNull(json['copies']);
    return ReceiptPrefs(
      kitchenItemSize: ReceiptSize.parse(json['kitchen_item_size']) ?? fallback.kitchenItemSize,
      kitchenNumberSize: NumberSize.parse(json['kitchen_number_size']) ?? fallback.kitchenNumberSize,
      footerText: json.containsKey('footer_text')
          ? (json['footer_text'] is String ? json['footer_text'] as String : null)
          : fallback.footerText,
      footerSize: ReceiptSize.parse(json['footer_size']) ?? fallback.footerSize,
      copies: copies == 1 || copies == 2 ? copies! : fallback.copies,
      showStoreAddress: json['show_store_address'] is bool
          ? json['show_store_address'] as bool
          : fallback.showStoreAddress,
      showPhone: json['show_phone'] is bool ? json['show_phone'] as bool : fallback.showPhone,
      extraPaper: json['extra_paper'] is bool ? json['extra_paper'] as bool : fallback.extraPaper,
      driverReportSize: DriverReportSize.parse(json['driver_report_size']) ?? fallback.driverReportSize,
      spacing: LineSpacing.fromJson(json['spacing'], fallback: fallback.spacing),
    );
  }

  /// The full object (the PUT body); `footer_text` is always present, null
  /// meaning "store default".
  Map<String, Object?> toJson() => {
    'kitchen_item_size': kitchenItemSize.wire,
    'kitchen_number_size': kitchenNumberSize.wire,
    'footer_text': footerText,
    'footer_size': footerSize.wire,
    'copies': copies,
    'show_store_address': showStoreAddress,
    'show_phone': showPhone,
    'extra_paper': extraPaper,
    'driver_report_size': driverReportSize.wire,
    'spacing': spacing.toJson(),
  };

  /// [footerText] takes a String or null (null = store default); leaving it
  /// out keeps the current value.
  ReceiptPrefs copyWith({
    ReceiptSize? kitchenItemSize,
    NumberSize? kitchenNumberSize,
    Object? footerText = _keep,
    ReceiptSize? footerSize,
    int? copies,
    bool? showStoreAddress,
    bool? showPhone,
    bool? extraPaper,
    DriverReportSize? driverReportSize,
    LineSpacing? spacing,
  }) => ReceiptPrefs(
    kitchenItemSize: kitchenItemSize ?? this.kitchenItemSize,
    kitchenNumberSize: kitchenNumberSize ?? this.kitchenNumberSize,
    footerText: identical(footerText, _keep) ? this.footerText : footerText as String?,
    footerSize: footerSize ?? this.footerSize,
    copies: copies ?? this.copies,
    showStoreAddress: showStoreAddress ?? this.showStoreAddress,
    showPhone: showPhone ?? this.showPhone,
    extraPaper: extraPaper ?? this.extraPaper,
    driverReportSize: driverReportSize ?? this.driverReportSize,
    spacing: spacing ?? this.spacing,
  );

  @override
  bool operator ==(Object other) =>
      other is ReceiptPrefs &&
      other.kitchenItemSize == kitchenItemSize &&
      other.kitchenNumberSize == kitchenNumberSize &&
      other.footerText == footerText &&
      other.footerSize == footerSize &&
      other.copies == copies &&
      other.showStoreAddress == showStoreAddress &&
      other.showPhone == showPhone &&
      other.extraPaper == extraPaper &&
      other.driverReportSize == driverReportSize &&
      other.spacing == spacing;

  @override
  int get hashCode => Object.hash(
    kitchenItemSize,
    kitchenNumberSize,
    footerText,
    footerSize,
    copies,
    showStoreAddress,
    showPhone,
    extraPaper,
    driverReportSize,
    spacing,
  );

  @override
  String toString() => 'ReceiptPrefs(${toJson()})';
}

/// `GET /api/settings/receipt` → `{prefs, defaults, footer_effective}` (a PUT
/// answers `{prefs, footer_effective}`: [defaults] is then the standard set).
class ReceiptSettings {
  final ReceiptPrefs prefs;
  final ReceiptPrefs defaults;

  /// The footer that prints with [prefs] (the store default when
  /// `prefs.footerText` is null).
  final String footerEffective;

  /// What prints when the footer is left on the store default (agent sends
  /// `footer_store_default`; empty on a Pi that doesn't).
  final String footerStoreDefault;

  const ReceiptSettings({
    required this.prefs,
    this.defaults = ReceiptPrefs.standard,
    this.footerEffective = '',
    this.footerStoreDefault = '',
  });

  factory ReceiptSettings.fromJson(Map<String, dynamic> json) {
    final defaults = json['defaults'] is Map ? ReceiptPrefs.fromJson(jMap(json['defaults'])) : ReceiptPrefs.standard;
    return ReceiptSettings(
      prefs: ReceiptPrefs.fromJson(jMap(json['prefs']), fallback: defaults),
      defaults: defaults,
      footerEffective: jStr(json['footer_effective']),
      footerStoreDefault: jStr(json['footer_store_default']),
    );
  }
}
