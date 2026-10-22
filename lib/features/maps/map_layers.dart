import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;
// The raw Protomaps v4 layer lists (protomaps-themes-base 4.1.0, CC0) — the
// package's own v4 themes label nothing with vector_tile_renderer 5 (see
// [offlineProtomapsLayers]). vector_map_tiles_pmtiles is pinned to 1.5.0.
// ignore: implementation_imports
import 'package:vector_map_tiles_pmtiles/src/themes/v4/_package.dart' as protomaps_v4;

import '../../core/polyline.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';

/// Where the store's offline map file is: the Pi serves it at
/// `/api/map.pmtiles` (open on the LAN, Range requests). [version] changes
/// when main publishes a new file.
class MapSource {
  final String url;
  final String version;
  const MapSource({required this.url, required this.version});

  @override
  bool operator ==(Object other) => other is MapSource && other.url == url && other.version == version;

  @override
  int get hashCode => Object.hash(url, version);
}

/// The map file to draw, or null while the Pi has none yet ("Map not
/// downloaded yet"). Overridden in tests.
final mapSourceProvider = Provider<MapSource?>((ref) {
  final map = ref.watch(floorProvider.select((s) => s.floor?.map));
  final base = ref.watch(agentClientProvider.select((c) => c?.baseUrl));
  if (map == null || base == null || base.isEmpty) return null;
  final url = map.url.startsWith('http') ? map.url : '$base${map.url.startsWith('/') ? '' : '/'}${map.url}';
  return MapSource(url: url, version: map.version);
});

/// Builds the base-map layer (the streets) for a FlutterMap. The default
/// draws the Pi's PMTiles file with the Protomaps theme; tests override it
/// with a stub so nothing touches the network.
typedef MapBaseLayerBuilder = Widget Function(BuildContext context, MapSource source, bool dark);

final mapBaseLayerProvider = Provider<MapBaseLayerBuilder>(
  (_) =>
      (context, source, dark) => PmTilesBaseLayer(source: source, dark: dark),
);

/// The streets from the Pi's PMTiles file, light or dark. Draws nothing
/// until the file's header is read (or if it can't be — the markers and the
/// route still show on the plain background).
class PmTilesBaseLayer extends StatefulWidget {
  final MapSource source;
  final bool dark;
  const PmTilesBaseLayer({super.key, required this.source, required this.dark});

  @override
  State<PmTilesBaseLayer> createState() => _PmTilesBaseLayerState();
}

class _PmTilesBaseLayerState extends State<PmTilesBaseLayer> {
  // One archive per file version for the whole app: opening it reads the
  // header and root directory over the LAN.
  static final Map<MapSource, Future<PmTilesVectorTileProvider>> _archives = {};
  // Parsed once (lazily) — reading a style is not free on a slow tablet.
  static final _light = protomapsTheme(dark: false);
  static final _dark = protomapsTheme(dark: true);

  late Future<PmTilesVectorTileProvider> _provider;

  @override
  void initState() {
    super.initState();
    _provider = _open(widget.source);
  }

  @override
  void didUpdateWidget(PmTilesBaseLayer old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) _provider = _open(widget.source);
  }

  static Future<PmTilesVectorTileProvider> _open(MapSource s) {
    final f = _archives[s];
    if (f != null) return f;
    final fresh = PmTilesVectorTileProvider.fromSource(s.url);
    _archives[s] = fresh;
    // A failed open (Pi unreachable) is tried again next time.
    unawaited(fresh.then((_) {}, onError: (Object _) => _archives.remove(s)));
    return fresh;
  }

  /// Tiles cached on the tablet per file version; older versions' folders
  /// are deleted.
  Future<Directory> _cacheFolder() async {
    Directory tmp;
    try {
      tmp = await getTemporaryDirectory();
    } catch (_) {
      tmp = Directory.systemTemp; // no platform plugin (tests)
    }
    final root = Directory('${tmp.path}/map-tiles');
    final dir = Directory('${root.path}/${widget.source.version.isEmpty ? 'current' : widget.source.version}');
    try {
      if (root.existsSync()) {
        for (final e in root.listSync()) {
          if (e.path != dir.path) e.deleteSync(recursive: true);
        }
      }
    } catch (_) {}
    return dir.create(recursive: true);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PmTilesVectorTileProvider>(
      future: _provider,
      builder: (context, snap) {
        final p = snap.data;
        if (p == null) return const SizedBox.shrink();
        return VectorTileLayer(
          key: ValueKey('${widget.source.version}-${widget.dark}'),
          theme: widget.dark ? _dark : _light,
          tileProviders: TileProviders({'protomaps': p}),
          // Small tile memory: a low-end tablet with a handful of maps open.
          memoryTileCacheMaxSize: 3 * 1024 * 1024,
          maximumZoom: p.maximumZoom.toDouble(),
          cacheFolder: _cacheFolder,
          // Vector, not the default raster: raster draws nothing on Android
          // with Impeller (checked on the emulator against the real store
          // file); vector draws streets + labels in both themes.
          layerMode: VectorTileLayerMode.vector,
        );
      },
    );
  }
}

/// The Protomaps v4 style (for basemap v4 tiles — what the map pipeline
/// builds), light or dark, made fully offline: no sprites (no icons), and
/// labels from the tiles' own names drawn with the tablet's fonts (no glyph
/// downloads).
vtr.Theme protomapsTheme({required bool dark}) =>
    const ProtomapsThemes().build(offlineProtomapsLayers(dark ? protomaps_v4.themeDark : protomaps_v4.themeLight));

/// The v4 layers with every label rewritten to an expression
/// vector_tile_renderer 5 understands. Upstream labels use `format` (and
/// script-dependent fonts), which it can't evaluate — so no street or place
/// names would show. Here a label is the English name, else the local one,
/// in one plain font; icon layers (sprites) are dropped.
List<Map<String, Object>> offlineProtomapsLayers(List<Map<String, Object>> layers) {
  final out = <Map<String, Object>>[];
  for (final l in layers) {
    final copy = jsonDecode(jsonEncode(l)) as Map<String, dynamic>;
    final layout = copy['layout'];
    if (layout is Map<String, dynamic>) {
      if (layout.containsKey('icon-image') && !layout.containsKey('text-field')) continue;
      layout.remove('icon-image');
      if (layout.containsKey('text-field')) {
        layout['text-field'] = [
          'coalesce',
          ['get', 'name:en'],
          ['get', 'name'],
        ];
        final font = layout['text-font'];
        final plain = font is List && font.isNotEmpty && font.every((f) => f is String);
        layout['text-font'] = plain ? [font.first] : ['Noto Sans Regular'];
      }
    }
    out.add(copy.cast<String, Object>());
  }
  return out;
}

LatLng ll(GeoPoint p) => LatLng(p.lat, p.lng);

/// The store pin.
Marker storeMarker(GeoPoint p) => Marker(
  point: ll(p),
  width: 40,
  height: 40,
  child: const _Pin(icon: Icons.storefront, color: QuiccColors.brand600),
);

/// The customer's door ([approx] = amber).
Marker destinationMarker(GeoPoint p, {bool approx = false}) => Marker(
  point: ll(p),
  width: 40,
  height: 40,
  alignment: Alignment.topCenter,
  child: Icon(Icons.location_on, size: 40, color: approx ? QuiccColors.statusFiring : QuiccColors.statusVoided),
);

/// A numbered stop of a run ([yellow] = an AUTO suggestion).
Marker stopMarker(GeoPoint p, int n, {bool yellow = false}) => Marker(
  point: ll(p),
  width: 34,
  height: 34,
  child: Container(
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: yellow ? QuiccColors.statusFiring : QuiccColors.brand600,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
    ),
    child: Text(
      '$n',
      style: TextStyle(
        color: yellow ? QuiccColors.brand900 : Colors.white,
        fontWeight: FontWeight.w800,
        fontSize: 16,
      ),
    ),
  ),
);

class _Pin extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _Pin({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
    ),
    child: Icon(icon, color: Colors.white, size: 22),
  );
}

/// A route line: solid along the road, dashed when it is only a straight
/// guess.
Polyline routeLine(List<GeoPoint> points, {bool dashed = false}) => Polyline(
  points: [for (final p in points) ll(p)],
  strokeWidth: dashed ? 3 : 5,
  color: QuiccColors.brand500,
  borderStrokeWidth: dashed ? 0 : 2,
  borderColor: Colors.white70,
  pattern: dashed ? StrokePattern.dashed(segments: const [10, 8]) : const StrokePattern.solid(),
);

/// Fits [points] in the map with some room around them; one point is shown
/// at street level.
CameraFit fitPoints(List<GeoPoint> points, {EdgeInsets padding = const EdgeInsets.all(48)}) {
  if (points.length == 1) {
    return CameraFit.coordinates(coordinates: [ll(points.first)], maxZoom: 15, padding: padding);
  }
  return CameraFit.coordinates(coordinates: [for (final p in points) ll(p)], maxZoom: 16, padding: padding);
}

/// The map background under the tiles (and instead of them while loading).
Color mapBackground(bool dark) => dark ? const Color(0xFF34373D) : const Color(0xFFE2DFDA);

/// "© OpenStreetMap" — the map data's licence asks for it.
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomLeft,
    child: Container(
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      color: Colors.white70,
      child: const Text('© OpenStreetMap · Protomaps', style: TextStyle(fontSize: 9, color: Colors.black87)),
    ),
  );
}
