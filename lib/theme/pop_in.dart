import 'dart:async';

import 'package:flutter/material.dart';

/// Small entrance animation: fade + subtle slide-up. Fires once on mount.
/// Use [index] × [stagger] as the delay for list-like reveals so each row
/// animates slightly after the one above it. Quick by default (~220 ms).
class PopIn extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Duration delay;
  final Offset slideFrom;

  const PopIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 220),
    this.delay = Duration.zero,
    this.slideFrom = const Offset(0, 0.06),
  });

  /// Convenience constructor for staggered lists — delay = [index] × 40 ms.
  PopIn.stagger({
    super.key,
    required this.child,
    required int index,
    this.duration = const Duration(milliseconds: 220),
    this.slideFrom = const Offset(0, 0.06),
  }) : delay = Duration(milliseconds: 40 * index);

  @override
  State<PopIn> createState() => _PopInState();
}

class _PopInState extends State<PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.duration);
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _c, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(begin: widget.slideFrom, end: Offset.zero)
            .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic)),
        child: widget.child,
      ),
    );
  }
}
