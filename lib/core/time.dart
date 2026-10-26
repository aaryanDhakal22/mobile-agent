import 'package:clock/clock.dart' as c;

/// The current time. Use this instead of `DateTime.now()`: it reads
/// package:clock, so tests (the goldens) can pin it with `withClock`. In the
/// app it is exactly `DateTime.now()`.
DateTime timeNow() => c.clock.now();
