import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';

/// The squish on press (1.9.0).
const double kSquishScale = 0.94;

/// Squishes [child] to [kSquishScale] while pressed and springs it back
/// (ACCEPT, READY, SEND OUT). Motion off: the child as is. [enabled] false
/// (a disabled button): no squish.
class Squish extends ConsumerStatefulWidget {
  final Widget child;
  final bool enabled;
  const Squish({super.key, required this.child, this.enabled = true});

  @override
  ConsumerState<Squish> createState() => _SquishState();
}

class _SquishState extends ConsumerState<Squish> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  Motion _motion = const Motion(full: true, speed: 1);

  @override
  void initState() {
    super.initState();
    _c = AnimationController.unbounded(vsync: this, value: 1);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent _) {
    if (!widget.enabled || !_motion.full) return;
    _c.animateTo(kSquishScale, duration: _motion.scale(const Duration(milliseconds: 90)), curve: Curves.easeOut);
  }

  void _up(PointerEvent _) {
    if (_c.value == 1 && !_c.isAnimating) return;
    final s = _motion.speed <= 0 ? 1.0 : _motion.speed;
    // A springy release (slower with a slower animation speed).
    final spring = SpringDescription(mass: 1, stiffness: 600 / (s * s), damping: 14 / s);
    _c.animateWith(SpringSimulation(spring, _c.value, 1, 0));
  }

  @override
  Widget build(BuildContext context) {
    _motion = Motion.of(context, ref);
    if (!_motion.full) return widget.child;
    return Listener(
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: ScaleTransition(key: const ValueKey('squish'), scale: _c, child: widget.child),
    );
  }
}
