import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'time.dart';

/// One shared 1 s clock for every timer on screen (1.9.0). It replaces a
/// Timer per ticket (the old `Ticker` widget): one timer for the whole app,
/// running only while something listens, and each listener rebuilds only
/// when what it shows changes ([ClockBuilder]). Reads [timeNow], so tests
/// and goldens pin it with `withClock`.
class SharedClock extends ChangeNotifier {
  final Duration interval;
  SharedClock({this.interval = const Duration(seconds: 1)});

  Timer? _timer;

  DateTime get now => timeNow();

  /// Ticks running (someone is listening).
  bool get running => _timer != null;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(interval, (_) => notifyListeners());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Outside a ProviderScope (a bare widget test) the widgets share this one.
final SharedClock _fallbackClock = SharedClock();

final clockProvider = Provider<SharedClock>((ref) {
  final c = SharedClock();
  ref.onDispose(c.dispose);
  return c;
});

/// Rebuilds [builder] on the shared clock, but only when [select] of the
/// current time changes — e.g. a minute count, a colour bucket, a text.
class ClockBuilder<T> extends StatefulWidget {
  final T Function(DateTime now) select;
  final Widget Function(BuildContext context, T value, DateTime now) builder;
  const ClockBuilder({super.key, required this.select, required this.builder});

  @override
  State<ClockBuilder<T>> createState() => _ClockBuilderState<T>();
}

class _ClockBuilderState<T> extends State<ClockBuilder<T>> {
  SharedClock? _clock;
  late T _value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    SharedClock clock;
    try {
      clock = ProviderScope.containerOf(context, listen: false).read(clockProvider);
    } on StateError {
      clock = _fallbackClock;
    }
    if (!identical(clock, _clock)) {
      _clock?.removeListener(_tick);
      _clock = clock..addListener(_tick);
    }
  }

  void _tick() {
    if (!mounted) return;
    if (widget.select(timeNow()) != _value) setState(() {});
  }

  @override
  void dispose() {
    _clock?.removeListener(_tick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = timeNow();
    _value = widget.select(now);
    return widget.builder(context, _value, now);
  }
}

/// A line of text that follows the shared clock: [text] (and [styleAt], when
/// its colour changes with time) — rebuilt only when either changes.
class ClockText extends StatelessWidget {
  final String Function(DateTime now) text;
  final TextStyle? style;
  final TextStyle? Function(DateTime now)? styleAt;
  final int? maxLines;
  final TextOverflow? overflow;

  /// The key of the [Text] inside (tests find the text by it).
  final Key? textKey;
  const ClockText(this.text, {super.key, this.style, this.styleAt, this.maxLines, this.overflow, this.textKey});

  @override
  Widget build(BuildContext context) => ClockBuilder<(String, TextStyle?)>(
    select: (now) => (text(now), styleAt?.call(now) ?? style),
    builder: (context, v, _) => Text(v.$1, key: textKey, style: v.$2, maxLines: maxLines, overflow: overflow),
  );
}
