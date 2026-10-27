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

/// A 64-bit FNV-1a fingerprint of decoded JSON (1.9.0): equal JSON → equal
/// sig. A refresh keeps the order instances whose JSON didn't change, so the
/// screens see `identical` orders and skip rebuilding them.
int jsonSig(Object? v) => _sig(v, _fnvOffset);

const int _fnvOffset = 0xcbf29ce484222325;
const int _fnvPrime = 0x100000001b3;

int _mix(int h, int x) => (h ^ x) * _fnvPrime;

int _sigStr(String s, int h) {
  for (var i = 0; i < s.length; i++) {
    h = _mix(h, s.codeUnitAt(i));
  }
  return _mix(h, 0x1F); // end of string
}

int _sig(Object? v, int h) {
  if (v == null) return _mix(h, 1);
  if (v is String) return _sigStr(v, _mix(h, 2));
  if (v is bool) return _mix(h, v ? 3 : 4);
  if (v is num) return _sigStr(v.toString(), _mix(h, 5));
  if (v is List) {
    h = _mix(h, 6);
    for (final x in v) {
      h = _sig(x, h);
    }
    return _mix(h, 7);
  }
  if (v is Map) {
    h = _mix(h, 8);
    for (final e in v.entries) {
      h = _sigStr('${e.key}', h);
      h = _sig(e.value, h);
    }
    return _mix(h, 9);
  }
  return _sigStr('$v', _mix(h, 10));
}
