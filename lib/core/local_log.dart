import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'storage.dart';

/// A small on-tablet log (the last [capacity] lines, kept across restarts) of
/// what went wrong: errors staff saw, troubleshooting steps, ring problems.
/// It rides along in every diagnostics report so the owner sees the history,
/// and staff never have to read it.
class LocalLog {
  static const capacity = 300;

  final AppStorage _storage;
  final DateTime Function() _now;
  List<String>? _lines;

  LocalLog(this._storage, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  List<String> get lines => List.unmodifiable(_load());

  /// [level] is one letter: I(nfo), W(arning), E(rror).
  void add(String area, String message, {String level = 'I'}) {
    final ls = _load();
    final clean = message.replaceAll('\n', ' ').trim();
    ls.add('${_now().toUtc().toIso8601String()} $level $area: ${clean.length > 400 ? clean.substring(0, 400) : clean}');
    if (ls.length > capacity) ls.removeRange(0, ls.length - capacity);
    _storage.setJson(AppStorage.kLocalLog, jsonEncode(ls));
  }

  void warn(String area, String message) => add(area, message, level: 'W');
  void error(String area, String message) => add(area, message, level: 'E');

  List<String> _load() {
    if (_lines != null) return _lines!;
    try {
      final raw = _storage.getJson(AppStorage.kLocalLog);
      _lines = raw == null ? [] : [for (final l in jsonDecode(raw) as List) '$l'];
    } catch (_) {
      _lines = [];
    }
    return _lines!;
  }
}

final localLogProvider = Provider<LocalLog>((ref) => LocalLog(ref.watch(storageProvider)));
