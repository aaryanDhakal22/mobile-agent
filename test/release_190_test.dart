// Quibase 1.9.0: the updater never sticks in "installing" and backs off a
// damaged download.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/floor_state.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/core/providers.dart';
import 'package:mobile_agent/core/sse.dart';
import 'package:mobile_agent/features/update/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// The Android side, recorded; [canInstallError] makes canInstall() throw.
class _Platform extends UpdatePlatform {
  final String dir;
  bool allowed = true;
  Object? canInstallError;
  final List<String> calls = [];
  final _results = StreamController<(InstallResult, String)>.broadcast();

  _Platform(this.dir);

  @override
  Stream<(InstallResult, String)> get results => _results.stream;
  @override
  Future<int?> installedVersion() async => 10;
  @override
  Future<String> updatesDir() async => dir;
  @override
  Future<bool> canInstall() async {
    final e = canInstallError;
    if (e != null) throw e;
    return allowed;
  }

  @override
  Future<void> openInstallSettings() async => calls.add('settings');
  @override
  Future<bool> canInstallSilently() async => true;
  @override
  Future<bool> canReopen() async => true;
  @override
  Future<void> installSession(String path) async => calls.add('session:${path.split('/').last}');
  @override
  Future<bool> confirm() async => true;
  @override
  Future<bool> installWithScreen(String path) async => true;
  @override
  Future<int> sdk() async => 33;
}

final _apk = utf8.encode('fake apk bytes');

class _Floor extends FloorController {
  final FloorState initial;
  _Floor(this.initial);

  @override
  FloorState build() => initial;

  @override
  Future<void> refresh() async {}
}

/// An empty, fresh batch: the updater installs a ready release at once.
FloorState _quietFloor() {
  final f = jsonDecode(floorJson) as Map<String, dynamic>;
  (f['batch'] as Map)['id'] = 8;
  return const FloorState(connection: SseStatus.connected).withSnapshot(
    floor: Floor.fromJson(f),
    current: const [],
    arrived: const [],
    drivers: const [],
    at: DateTime.now(),
  );
}

Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('quibase-190'));
  tearDown(() => dir.delete(recursive: true));

  group('WP3 updater', () {
    /// [sha] is what the Pi says the APK hashes to; [code] its versionCode.
    Future<(ProviderContainer, _Platform, List<String>)> start({
      required String Function() sha,
      int Function()? code,
      void Function(_Platform)? setup,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final platform = _Platform(dir.path);
      setup?.call(platform);
      final requests = <String>[];
      final pi = AgentClient(
        baseUrl: 'http://10.0.0.5:8080',
        deviceKey: 'qagt_k',
        client: MockClient((req) async {
          requests.add(req.url.path);
          if (req.url.path == '/api/app/latest') {
            return http.Response(
              jsonEncode({'version_code': code?.call() ?? 20, 'version_name': '1.9.0', 'sha256': sha()}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (req.url.path == '/api/app/apk') return http.Response.bytes(_apk, 200);
          return http.Response('{}', 404);
        }),
      );
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          floorProvider.overrideWith(() => _Floor(_quietFloor())),
          agentClientProvider.overrideWithValue(pi),
          updatePlatformProvider.overrideWithValue(platform),
        ],
      );
      addTearDown(c.dispose);
      c.listen(updaterProvider, (_, _) {});
      await _drain();
      return (c, platform, requests);
    }

    final goodSha = sha256.convert(_apk).toString();

    test('canInstall() throwing fails the install instead of sticking in installing', () async {
      final (c, platform, _) = await start(
        sha: () => goodSha,
        setup: (p) => p.canInstallError = PlatformException(code: 'boom', message: 'channel died'),
      );
      final u = c.read(updaterProvider);
      expect(u.phase, UpdatePhase.failed, reason: 'the automatic install hit the throw');
      expect(u.error!.details, contains('channel died'));
      expect(platform.calls, isEmpty);

      // The next INSTALL NOW is not swallowed by a stale "installing".
      platform.canInstallError = null;
      await c.read(updaterProvider.notifier).tapInstall();
      expect(platform.calls, ['session:quibase-20.apk']);
      expect(c.read(updaterProvider).phase, UpdatePhase.installing);
    });

    test('canInstall() false: needPermission, never installing', () async {
      final (c, platform, _) = await start(sha: () => goodSha, setup: (p) => p.allowed = false);
      expect(c.read(updaterProvider).phase, UpdatePhase.needPermission);
      await c.read(updaterProvider.notifier).installNow();
      expect(c.read(updaterProvider).phase, UpdatePhase.needPermission);
      expect(platform.calls, isEmpty);
    });

    test('damaged-download delay: 10 min × 2ⁿ, capped at 4 h', () {
      expect(damagedRetryDelay(0), Duration.zero);
      expect(damagedRetryDelay(1), const Duration(minutes: 10));
      expect(damagedRetryDelay(2), const Duration(minutes: 20));
      expect(damagedRetryDelay(3), const Duration(minutes: 40));
      expect(damagedRetryDelay(4), const Duration(minutes: 80));
      expect(damagedRetryDelay(5), const Duration(minutes: 160));
      expect(damagedRetryDelay(6), const Duration(hours: 4));
      expect(damagedRetryDelay(60), const Duration(hours: 4));
    });

    test('a damaged download backs off; a manual retry and a new version start over', () async {
      var now = DateTime(2026, 10, 27, 9);
      await withClock(Clock(() => now), () async {
        var code = 20;
        final (c, _, requests) = await start(sha: () => 'deadbeef', code: () => code);
        final updater = c.read(updaterProvider.notifier);
        int downloads() => requests.where((p) => p == '/api/app/apk').length;

        expect(c.read(updaterProvider).phase, UpdatePhase.failed);
        expect(c.read(updaterProvider).error!.title, 'The download was damaged');
        expect(downloads(), 1);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 10)));

        now = now.add(const Duration(minutes: 9));
        await updater.check();
        expect(downloads(), 1, reason: 'still backing off');

        now = now.add(const Duration(minutes: 2));
        await updater.check();
        expect(downloads(), 2);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 20)));

        now = now.add(const Duration(minutes: 15));
        await updater.check();
        expect(downloads(), 2);
        now = now.add(const Duration(minutes: 6));
        await updater.check();
        expect(downloads(), 3);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 40)));

        // TRY AGAIN: downloads at once and the back-off starts over.
        await updater.tapInstall();
        expect(downloads(), 4);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 10)));

        // A new version on the Pi downloads at once too.
        code = 21;
        await updater.check();
        expect(downloads(), 5);
        expect(c.read(updaterProvider).target!.versionCode, 21);
        expect(updater.damagedRetryAfter, now.add(const Duration(minutes: 10)));
      });
    });
  });
}
