// Opt-in check against a real store map file served over HTTP with Range
// support (like the Pi's /api/map.pmtiles):
//
//   QUIBASE_MAP_URL=http://127.0.0.1:18765/api/map.pmtiles flutter test test/map_file_integration_test.dart
//
// Reads the tile at the store, checks it has the Protomaps v4 layers the
// style draws, and renders it with the offline light + dark styles (labels
// included) to PNGs in QUIBASE_MAP_OUT (if set). Skipped without the URL.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/features/maps/map_layers.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

final _url = Platform.environment['QUIBASE_MAP_URL'];
final _out = Platform.environment['QUIBASE_MAP_OUT'];

void main() {
  test('the store map file reads and renders offline', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null; // a real request to the given URL
    final p = await PmTilesVectorTileProvider.fromSource(_url!);
    const z = 14, lat = 40.6687, lng = -74.1143;
    final n = 1 << z;
    final x = ((lng + 180) / 360 * n).floor();
    final r = lat * math.pi / 180;
    final y = ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n).floor();
    final tile = vtr.VectorTileReader().read(await p.provide(TileIdentity(z, x, y)));
    final names = tile.layers.map((l) => l.name).toSet();
    expect(names, containsAll(['earth', 'water', 'roads']));
    for (final dark in [false, true]) {
      final theme = protomapsTheme(dark: dark);
      final data = vtr.TileFactory(theme, const vtr.Logger.noop()).createTileData(tile).toTile();
      final set = vtr.TilesetPreprocessor(theme).preprocess(vtr.Tileset({'protomaps': data}), zoom: 16);
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec)..scale(2);
      vtr.Renderer(theme: theme).render(canvas, vtr.TileSource(tileset: set), zoomScaleFactor: 2, zoom: 16, rotation: 0);
      final png = await (await rec.endRecording().toImage(512, 512)).toByteData(format: ui.ImageByteFormat.png);
      if (_out != null) File('$_out/store-tile-${dark ? 'dark' : 'light'}.png').writeAsBytesSync(png!.buffer.asUint8List());
    }
  }, skip: _url == null ? 'set QUIBASE_MAP_URL to a served .pmtiles file' : false);
}
