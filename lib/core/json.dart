// Defensive JSON readers. The agent omits absent fields (`omitempty`) and older
// orders may predate whole blocks (floor fields, routing), so every model reads
// through these instead of hard casts: a missing / null / wrong-typed value
// falls back to a neutral default rather than throwing.

String jStr(Object? v, [String fallback = '']) {
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return fallback;
}

/// Empty string → null; otherwise the string form.
String? jStrOrNull(Object? v) {
  final s = jStr(v);
  return s.isEmpty ? null : s;
}

int jInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

int? jIntOrNull(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

bool jBool(Object? v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is String) return v == 'true';
  return fallback;
}

/// Parses an RFC3339 timestamp. Go's zero time (`0001-01-01T00:00:00Z`) is
/// treated as absent.
DateTime? jDate(Object? v) {
  if (v is! String || v.isEmpty) return null;
  final d = DateTime.tryParse(v);
  if (d == null || d.year <= 1) return null;
  return d;
}

Map<String, dynamic> jMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  return const {};
}

List<T> jList<T>(Object? raw, T Function(Map<String, dynamic>) fromJson) {
  if (raw is! List) return const [];
  return raw.whereType<Map>().map((m) => fromJson(jMap(m))).toList(growable: false);
}
