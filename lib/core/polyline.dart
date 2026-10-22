/// A point on the map, WGS84 degrees.
typedef GeoPoint = ({double lat, double lng});

/// Decodes a Google encoded polyline (precision 5, the format main sends for
/// the store → address route and the pool trip). Malformed input decodes as
/// far as it is valid; an empty string gives no points.
///
/// Format: https://developers.google.com/maps/documentation/utilities/polylinealgorithm
List<GeoPoint> decodePolyline(String encoded, {int precision = 5}) {
  final points = <GeoPoint>[];
  var factor = 1.0;
  for (var i = 0; i < precision; i++) {
    factor *= 10;
  }
  var index = 0, lat = 0, lng = 0;
  final len = encoded.length;

  // One signed varint, or null when the string ends mid-value.
  int? next() {
    var result = 0, shift = 0;
    while (index < len) {
      final b = encoded.codeUnitAt(index++) - 63;
      if (b < 0) return null;
      result |= (b & 0x1f) << shift;
      shift += 5;
      if (b < 0x20) return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      if (shift > 30) return null;
    }
    return null;
  }

  while (index < len) {
    final dLat = next();
    final dLng = next();
    if (dLat == null || dLng == null) break;
    lat += dLat;
    lng += dLng;
    points.add((lat: lat / factor, lng: lng / factor));
  }
  return points;
}

/// Encodes [points] as a Google polyline (precision 5). Used by tests and
/// fakes; the app only decodes.
String encodePolyline(List<GeoPoint> points, {int precision = 5}) {
  var factor = 1.0;
  for (var i = 0; i < precision; i++) {
    factor *= 10;
  }
  final out = StringBuffer();
  var pLat = 0, pLng = 0;

  void put(int v) {
    var s = v < 0 ? ~(v << 1) : (v << 1);
    while (s >= 0x20) {
      out.writeCharCode((0x20 | (s & 0x1f)) + 63);
      s >>= 5;
    }
    out.writeCharCode(s + 63);
  }

  for (final p in points) {
    final lat = (p.lat * factor).round();
    final lng = (p.lng * factor).round();
    put(lat - pLat);
    put(lng - pLng);
    pLat = lat;
    pLng = lng;
  }
  return out.toString();
}
