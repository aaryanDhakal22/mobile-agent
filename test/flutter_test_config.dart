import 'dart:async';

import 'package:mobile_agent/core/api_client.dart';

/// Runs before every test file: big bodies are parsed on the test's own
/// thread (widget tests run on fake time, which a real isolate never
/// finishes in). test/release_190_test.dart turns it on for its own check.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  parseOffUiThread = false;
  await testMain();
}
