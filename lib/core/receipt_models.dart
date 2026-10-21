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

  const ReceiptPrefs({
    this.kitchenItemSize = ReceiptSize.large,
    this.kitchenNumberSize = NumberSize.xlarge,
    this.footerText,
    this.footerSize = ReceiptSize.xlarge,
    this.copies = 1,
    this.showStoreAddress = true,
    this.showPhone = true,
    this.extraPaper = true,
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
  }) => ReceiptPrefs(
    kitchenItemSize: kitchenItemSize ?? this.kitchenItemSize,
    kitchenNumberSize: kitchenNumberSize ?? this.kitchenNumberSize,
    footerText: identical(footerText, _keep) ? this.footerText : footerText as String?,
    footerSize: footerSize ?? this.footerSize,
    copies: copies ?? this.copies,
    showStoreAddress: showStoreAddress ?? this.showStoreAddress,
    showPhone: showPhone ?? this.showPhone,
    extraPaper: extraPaper ?? this.extraPaper,
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
      other.extraPaper == extraPaper;

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
