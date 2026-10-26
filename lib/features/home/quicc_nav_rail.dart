import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import 'rail_blob.dart';
import 'rail_motion.dart';

class QuiccNavDestination {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Count shown as a dot on the icon (hidden when 0).
  final int badge;
  final Color badgeColor;
  const QuiccNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badge = 0,
    this.badgeColor = QuiccColors.brand400,
  });
}

/// The highlight pill's colour (blob and the pills that ride with icons).
Color railPillColor(BuildContext context) =>
    QuiccColors.brand400.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.24);

/// The rail's width.
const double kRailWidth = 104;

/// The highlight pill's resting width and its tallest height.
const double _pillWidth = 80;
const double _pillMaxHeight = 84;

/// Narrow left rail: the header (the q) on top, then the current mode's
/// destinations, each with an equal share of the height.
///
/// When [modeKey] changes the old destinations fall off the bottom and the
/// new ones bounce in (rail_motion.dart); a new [selectedIndex] in the same
/// mode moves the highlight blob (rail_blob.dart). With motion off both
/// become a short cross-fade.
class QuiccNavRail extends StatefulWidget {
  final Object modeKey;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<QuiccNavDestination> destinations;
  final Widget header;
  final Motion motion;

  const QuiccNavRail({
    super.key,
    this.modeKey = 0,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.header,
    this.motion = const Motion(full: true, speed: 1),
  });

  @override
  State<QuiccNavRail> createState() => _QuiccNavRailState();
}

class _QuiccNavRailState extends State<QuiccNavRail> with TickerProviderStateMixin {
  /// The mode switch (fall + bounce-in), linear 0 → 1.
  late final AnimationController _switch;

  /// The blob's move, linear 0 → 1.
  late final AnimationController _blob;

  /// What is falling off (the previous mode), while [_switch] runs.
  List<QuiccNavDestination>? _outgoing;
  int _outgoingSelected = -1;

  /// The blob's start (top, bottom) as fractions of a slot index, so it
  /// survives a resize: (index, null) = at rest on that slot.
  double _blobFrom = 0;
  int _blobTo = 0;

  @override
  void initState() {
    super.initState();
    _switch = AnimationController(vsync: this, value: 1)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed && _outgoing != null) setState(() => _outgoing = null);
      });
    _blob = AnimationController(vsync: this, value: 1);
    _blobFrom = widget.selectedIndex.toDouble();
    _blobTo = widget.selectedIndex;
  }

  @override
  void didUpdateWidget(QuiccNavRail old) {
    super.didUpdateWidget(old);
    if (old.modeKey != widget.modeKey) {
      _outgoing = old.destinations;
      _outgoingSelected = old.selectedIndex;
      _blob.value = 1;
      _blobFrom = widget.selectedIndex.toDouble();
      _blobTo = widget.selectedIndex;
      _switch.duration = widget.motion.full
          ? widget.motion.scale(RailSwitchTiming.duration(widget.destinations.length))
          : widget.motion.fade;
      _switch.forward(from: 0);
    } else if (old.selectedIndex != widget.selectedIndex) {
      // Start from wherever the blob is now (it may be mid-move).
      _blobFrom = _blobPosition();
      _blobTo = widget.selectedIndex;
      _blob.duration = widget.motion.full ? widget.motion.scale(const Duration(milliseconds: 560)) : widget.motion.fade;
      _blob.forward(from: 0);
    }
  }

  /// The blob's current centre, in slot-index units.
  double _blobPosition() {
    final t = _blob.value;
    return _blobFrom + (_blobTo - _blobFrom) * Curves.easeInOut.transform(t);
  }

  @override
  void dispose() {
    _switch.dispose();
    _blob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kRailWidth,
      color: context.palette.bgSurface,
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: QuiccSpace.lg),
              child: widget.header,
            ),
            Expanded(
              child: ClipRect(
                child: LayoutBuilder(
                  builder: (context, box) => AnimatedBuilder(
                    animation: Listenable.merge([_switch, _blob]),
                    builder: (context, _) => widget.motion.full ? _buildFull(box.biggest) : _buildPlain(box.biggest),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _pillHeight(double slot) => math.min(_pillMaxHeight, slot * 0.86);

  /// The blob at rest on [index] or moving, painted behind the items.
  Widget _blobLayer(Size size, {double opacity = 1}) {
    final n = widget.destinations.length;
    if (n == 0) return const SizedBox.shrink();
    final slot = size.height / n;
    final h = _pillHeight(slot);
    (double, double) extent(double index) {
      final c = (index + 0.5) * slot;
      return (c - h / 2, c + h / 2);
    }

    final (top, bottom, ws) = BlobGeometry.at(
      _blob.value,
      extent(_blobFrom),
      extent(_blobTo.toDouble()),
      full: widget.motion.full,
    );
    return CustomPaint(
      size: size,
      painter: RailBlobPainter(
        top: top,
        bottom: bottom,
        width: _pillWidth,
        restHeight: h,
        widthScale: ws,
        color: railPillColor(context),
        opacity: opacity,
      ),
    );
  }

  Widget _items(
    Size size,
    List<QuiccNavDestination> list,
    int selected, {
    required bool interactive,
    bool pill = false,
  }) {
    final n = list.length;
    final slot = n == 0 ? 0.0 : size.height / n;
    return Stack(
      children: [
        for (var i = 0; i < n; i++)
          Positioned(
            left: 0,
            right: 0,
            top: i * slot,
            height: slot,
            child: _NavItem(
              destination: list[i],
              selected: i == selected,
              pill: pill && i == selected,
              pillHeight: _pillHeight(slot),
              onTap: interactive ? () => widget.onDestinationSelected(i) : null,
            ),
          ),
      ],
    );
  }

  /// Motion off: a quick cross-fade between modes; the blob slides plainly.
  Widget _buildPlain(Size size) {
    final switching = _outgoing != null && _switch.isAnimating;
    final t = _switch.value;
    return Stack(
      children: [
        Positioned.fill(child: _blobLayer(size, opacity: switching ? t : 1)),
        if (switching)
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 1 - t,
                child: _items(size, _outgoing!, _outgoingSelected, interactive: false, pill: true),
              ),
            ),
          ),
        Positioned.fill(
          child: Opacity(
            opacity: switching ? t : 1,
            child: _items(size, widget.destinations, widget.selectedIndex, interactive: true),
          ),
        ),
      ],
    );
  }

  /// Motion on: gravity fall + staggered bounce-in, blob highlight.
  Widget _buildFull(Size size) {
    final switching = _outgoing != null && _switch.isAnimating;
    if (!switching) {
      return Stack(
        children: [
          Positioned.fill(child: _blobLayer(size)),
          Positioned.fill(child: _items(size, widget.destinations, widget.selectedIndex, interactive: true)),
        ],
      );
    }
    final total = RailSwitchTiming.total(widget.destinations.length);
    final time = _switch.value * total; // designed seconds
    final out = _outgoing!;
    final outSlot = out.isEmpty ? 0.0 : size.height / out.length;
    final inSlot = widget.destinations.isEmpty ? 0.0 : size.height / widget.destinations.length;

    return SizedBox.fromSize(
      size: size,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // Falling: the bottom icon lets go first.
          for (var i = 0; i < out.length; i++)
            _falling(
              size,
              out[i],
              top: i * outSlot,
              slot: outSlot,
              selected: i == _outgoingSelected,
              t: time - (out.length - 1 - i) * RailSwitchTiming.fallStagger,
            ),
          // Popping in, top to bottom.
          for (var i = 0; i < widget.destinations.length; i++)
            _entering(
              i,
              top: i * inSlot,
              slot: inSlot,
              t: time - RailSwitchTiming.enterStart - i * RailSwitchTiming.enterStagger,
            ),
        ],
      ),
    );
  }

  Widget _falling(
    Size size,
    QuiccNavDestination d, {
    required double top,
    required double slot,
    required bool selected,
    required double t,
  }) {
    final body = FallBody.seeded(d.label);
    final pose = FallPose.at(t, body, size.height);
    // Gone: an empty Positioned, so the Stack never sizes itself to it.
    if (top + pose.dy > size.height + slot) return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    final com = Offset(body.comX * _pillWidth, body.comY * slot * 0.6);
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      height: slot,
      child: IgnorePointer(
        child: Transform(
          alignment: Alignment.center,
          origin: com,
          transform: Matrix4.translationValues(pose.dx, pose.dy, 0)..rotateZ(pose.angle),
          child: _NavItem(
            destination: d,
            selected: selected,
            pill: selected,
            pillHeight: _pillHeight(slot),
            onTap: null,
          ),
        ),
      ),
    );
  }

  Widget _entering(int i, {required double top, required double slot, required double t}) {
    final k = (t / RailSwitchTiming.bounce).clamp(0.0, 1.0);
    final scale = kRailBounce.transform(k);
    final selected = i == widget.selectedIndex;
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      height: slot,
      // Scale alone (it starts at 0): no opacity layer to composite per icon.
      child: Transform.scale(
        scale: scale,
        child: _NavItem(
          destination: widget.destinations[i],
          selected: selected,
          pill: selected,
          pillHeight: _pillHeight(slot),
          onTap: () => widget.onDestinationSelected(i),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final QuiccNavDestination destination;
  final bool selected;

  /// Draw the highlight pill in the item itself (while the rail switches
  /// modes the blob layer is hidden and the pills ride with their icons).
  final bool pill;
  final double pillHeight;
  final VoidCallback? onTap;

  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
    this.pill = false,
    this.pillHeight = _pillMaxHeight,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Lavender reads on the dark rail; the light rail needs the deeper shade.
    final color = selected ? (dark ? QuiccColors.brand400 : QuiccColors.brand600) : palette.textMuted;
    final content = FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Badge(
            isLabelVisible: destination.badge > 0,
            backgroundColor: destination.badgeColor,
            textColor: QuiccColors.brand900,
            offset: const Offset(4, -4),
            label: Text('${destination.badge}', style: QuiccType.number(QuiccType.caption, weight: FontWeight.w800)),
            child: SizedBox(
              width: 44,
              height: 36,
              child: Icon(selected ? destination.selectedIcon : destination.icon, size: 28, color: color),
            ),
          ),
          QuiccSpace.gapXs,
          Text(
            destination.label,
            style: QuiccType.text(
              QuiccType.caption,
              weight: selected ? FontWeight.w700 : FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
    // The whole slot is the touch target (big, for busy hands).
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (pill)
              Container(
                width: _pillWidth,
                height: pillHeight,
                decoration: BoxDecoration(
                  color: railPillColor(context),
                  borderRadius: BorderRadius.circular(math.min(_pillWidth, pillHeight) / 2),
                ),
              ),
            content,
          ],
        ),
      ),
    );
  }
}
