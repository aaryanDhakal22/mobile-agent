import 'package:flutter/material.dart';

import '../../theme/quicc_colors.dart';

class QuiccNavDestination {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const QuiccNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
}

/// Narrow left rail where the header sits at the top and every destination
/// gets an equal share of the remaining vertical space. Replaces Flutter's
/// `NavigationRail`, which packs items against the top with fixed sizing.
class QuiccNavRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<QuiccNavDestination> destinations;
  final Widget header;

  const QuiccNavRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.header,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      color: context.palette.bgSurface,
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: header,
            ),
            Expanded(
              child: Column(
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    Expanded(
                      child: _NavItem(
                        destination: destinations[i],
                        selected: i == selectedIndex,
                        onTap: () => onDestinationSelected(i),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final QuiccNavDestination destination;
  final bool selected;
  final VoidCallback onTap;
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = selected ? QuiccColors.brand400 : palette.textMuted;
    // Outer GestureDetector keeps the whole tile tappable (big touch target
    // for busy cashiers); the InkResponse lives on the icon pill only, so
    // the ripple is a tight circle around the icon instead of flooding the
    // rectangular tile all the way to the rail edges.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkResponse(
              onTap: onTap,
              radius: 30,
              containedInkWell: true,
              customBorder: const CircleBorder(),
              highlightShape: BoxShape.circle,
              splashColor: QuiccColors.brand400.withValues(alpha: 0.22),
              highlightColor: QuiccColors.brand400.withValues(alpha: 0.10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? QuiccColors.brand400.withValues(alpha: 0.18)
                      : Colors.transparent,
                ),
                alignment: Alignment.center,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: anim,
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: Icon(
                    selected ? destination.selectedIcon : destination.icon,
                    key: ValueKey<bool>(selected),
                    size: 26,
                    color: color,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 180),
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: color,
              letterSpacing: 0.5,
            ),
            child: Text(destination.label),
          ),
        ],
      ),
    );
  }
}
