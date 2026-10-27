import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'time.dart';

/// How far back [FrameStats] looks.
const Duration kFrameStatsWindow = Duration(minutes: 5);

/// A frame slower than this to build or to raster missed the 60 Hz budget.
const Duration kFrameBudget = Duration(microseconds: 16667);

/// One frame: when it was reported and how long it took to build (UI
/// thread) and to raster (raster thread).
typedef FrameSample = ({DateTime at, int buildUs, int rasterUs});

/// How smooth the screen has been (1.9.0): every frame of the last
/// [kFrameStatsWindow] from Flutter's frame timings — count, jank % and
/// p50 / p90 / max build and raster times. Sent with diagnostics under
/// `tablet.frames`, and shown in developer Config.
class FrameStats {
  final Duration window;
  FrameStats({this.window = kFrameStatsWindow});

  final _samples = ListQueue<FrameSample>();
  bool _listening = false;

  /// Starts listening to the engine's frame timings.
  void start() {
    if (_listening) return;
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _listening = true;
    } catch (_) {
      // No Flutter binding (a plain unit test): nothing to listen to.
    }
  }

  void stop() {
    if (!_listening) return;
    _listening = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    final now = timeNow();
    for (final t in timings) {
      add((at: now, buildUs: t.buildDuration.inMicroseconds, rasterUs: t.rasterDuration.inMicroseconds));
    }
  }

  /// Records one frame (and drops the ones older than the window).
  void add(FrameSample s) {
    _samples.addLast(s);
    _prune(s.at);
  }

  void _prune(DateTime now) {
    final cut = now.subtract(window);
    while (_samples.isNotEmpty && _samples.first.at.isBefore(cut)) {
      _samples.removeFirst();
    }
  }

  /// The window's numbers, as diagnostics send them:
  /// `{window_s, frames, jank_frames, jank_pct, build_ms: {p50, p90, max},
  /// raster_ms: {…}}`.
  Map<String, Object?> summary([DateTime? now]) {
    _prune(now ?? timeNow());
    final n = _samples.length;
    final budget = kFrameBudget.inMicroseconds;
    final builds = [for (final s in _samples) s.buildUs]..sort();
    final rasters = [for (final s in _samples) s.rasterUs]..sort();
    final jank = _samples.where((s) => s.buildUs > budget || s.rasterUs > budget).length;
    return {
      'window_s': window.inSeconds,
      'frames': n,
      'jank_frames': jank,
      'jank_pct': n == 0 ? 0.0 : _round1(100 * jank / n),
      'build_ms': _spread(builds),
      'raster_ms': _spread(rasters),
    };
  }

  /// "312 frames · 1.3 % jank · build p90 4.1 ms · raster p90 6.0 ms".
  String line([DateTime? now]) {
    final s = summary(now);
    if (s['frames'] == 0) return 'No frames drawn in the last ${window.inMinutes} min';
    final b = s['build_ms'] as Map, r = s['raster_ms'] as Map;
    return '${s['frames']} frames · ${s['jank_pct']} % jank · build p90 ${b['p90']} ms (max ${b['max']}) · '
        'raster p90 ${r['p90']} ms (max ${r['max']})';
  }

  static double _round1(num v) => (v * 10).round() / 10;

  static Map<String, double> _spread(List<int> sortedUs) {
    if (sortedUs.isEmpty) return const {'p50': 0, 'p90': 0, 'max': 0};
    double at(double q) => _round1(sortedUs[((sortedUs.length - 1) * q).round()] / 1000);
    return {'p50': at(0.5), 'p90': at(0.9), 'max': _round1(sortedUs.last / 1000)};
  }
}

/// The app's frame stats, listening from the first read (main.dart).
final frameStatsProvider = Provider<FrameStats>((ref) {
  final s = FrameStats()..start();
  ref.onDispose(s.stop);
  return s;
});

/// Developer Config → "Performance overlay": Flutter's frame graphs over the
/// app (MaterialApp.showPerformanceOverlay). Memory only — off after a restart.
final perfOverlayProvider = StateProvider<bool>((_) => false);
