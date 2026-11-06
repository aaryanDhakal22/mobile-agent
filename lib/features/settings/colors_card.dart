import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import 'settings_card.dart';

// 2.0.5 (Pi 2.4.3): the store's colours — saved on the Pi, so every tablet
// and the Pi's web page change together.

/// A named colour on the swatch rows.
typedef Swatch = ({String name, Color color});

/// The accents: light enough that the deep shade reads on them, like the
/// brand lavender.
const List<Swatch> kAccentSwatches = [
  (name: 'Lavender', color: StoreLook.defaultAccent),
  (name: 'Blue', color: Color(0xFF7AA2F7)),
  (name: 'Sky', color: Color(0xFF5EC2F2)),
  (name: 'Teal', color: Color(0xFF4FD1C5)),
  (name: 'Green', color: Color(0xFF6ED69A)),
  (name: 'Amber', color: Color(0xFFF5C451)),
  (name: 'Orange', color: Color(0xFFF59E62)),
  (name: 'Coral', color: Color(0xFFF28B8B)),
  (name: 'Pink', color: Color(0xFFF48FC7)),
  (name: 'Slate', color: Color(0xFF94A3B8)),
];

/// The ticket bars.
const List<Swatch> kTicketSwatches = [
  (name: 'Blue', color: StoreLook.defaultTicket),
  (name: 'Purple', color: Color(0xFF8B5CF6)),
  (name: 'Indigo', color: Color(0xFF6366F1)),
  (name: 'Teal', color: Color(0xFF14B8A6)),
  (name: 'Green', color: Color(0xFF22C55E)),
  (name: 'Amber', color: Color(0xFFF59E0B)),
  (name: 'Orange', color: Color(0xFFF97316)),
  (name: 'Red', color: Color(0xFFEF4444)),
  (name: 'Pink', color: Color(0xFFEC4899)),
  (name: 'Slate', color: Color(0xFF64748B)),
];

const kColorsInfo = InfoText(
  'Colors',
  'The accent is the colour of the buttons, highlights and the rail on every tablet, and on the '
      "Pi's web page.\n\n"
      'Ticket colours paint the top bar of each kitchen ticket by its type, so deliveries, pickups '
      'and counter orders are easy to tell apart. The timer on each ticket still goes green → amber '
      '→ red as it waits.\n\n'
      'Saved on the Pi: every tablet changes together.',
);

/// Settings → Colors: the accent and the three ticket colours.
class StoreColorsCard extends ConsumerStatefulWidget {
  const StoreColorsCard({super.key});

  @override
  ConsumerState<StoreColorsCard> createState() => _StoreColorsCardState();
}

class _StoreColorsCardState extends ConsumerState<StoreColorsCard> {
  bool _saving = false;

  Future<void> _save({Color? accent, Color? delivery, Color? pickup, Color? counter}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(floorProvider.notifier)
          .saveLook(accent: accent, delivery: delivery, pickup: pickup, counter: counter);
    } catch (e) {
      if (!mounted) return;
      e is AgentException && e.code == kFutureActionsUnsupported
          ? toast(context, 'This Pi needs an update to change the colours.', error: true)
          : toastError(context, e, lead: 'Colour not saved', area: 'settings');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final look = ref.watch(storeLookProvider);
    final older = ref.watch(floorProvider.select((s) => s.floor != null && s.floor!.settings.look == null)) ||
        ref.watch(futureActionsUnsupportedProvider);
    return SettingsCard(
      title: 'Colors',
      info: kColorsInfo,
      subtitle: 'For every tablet and the Pi\'s web page.',
      children: [
        if (older)
          Text(
            'This Pi needs an update to change the colours.',
            key: const ValueKey('colors-older-pi'),
            style: QuiccType.text(QuiccType.body, color: context.palette.textMuted),
          )
        else ...[
          _SwatchRow(
            key: const ValueKey('accent-swatches'),
            label: 'Accent',
            swatches: kAccentSwatches,
            value: look.accent,
            enabled: !_saving,
            onPick: (c) => _save(accent: c),
          ),
          QuiccSpace.gapLg,
          _SwatchRow(
            key: const ValueKey('delivery-swatches'),
            label: 'Delivery tickets',
            swatches: kTicketSwatches,
            value: look.delivery,
            enabled: !_saving,
            onPick: (c) => _save(delivery: c),
          ),
          QuiccSpace.gapMd,
          _SwatchRow(
            key: const ValueKey('pickup-swatches'),
            label: 'Pickup tickets',
            swatches: kTicketSwatches,
            value: look.pickup,
            enabled: !_saving,
            onPick: (c) => _save(pickup: c),
          ),
          QuiccSpace.gapMd,
          _SwatchRow(
            key: const ValueKey('counter-swatches'),
            label: 'Counter tickets',
            swatches: kTicketSwatches,
            value: look.counter,
            enabled: !_saving,
            onPick: (c) => _save(counter: c),
          ),
        ],
      ],
    );
  }
}

/// A label and a row of round swatches; the chosen one has a check.
class _SwatchRow extends StatelessWidget {
  final String label;
  final List<Swatch> swatches;
  final Color value;
  final bool enabled;
  final ValueChanged<Color> onPick;
  const _SwatchRow({
    super.key,
    required this.label,
    required this.swatches,
    required this.value,
    required this.enabled,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final custom = !swatches.any((s) => s.color.toARGB32() == value.toARGB32());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
        QuiccSpace.gapSm,
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final s in swatches)
              _Dot(
                key: ValueKey('swatch-${label.split(' ').first.toLowerCase()}-${s.name.toLowerCase()}'),
                name: s.name,
                color: s.color,
                selected: s.color.toARGB32() == value.toARGB32(),
                onTap: enabled ? () => onPick(s.color) : null,
              ),
            // A colour set on the Pi's web page that isn't a swatch.
            if (custom) _Dot(name: 'Custom ${hexOfColor(value)}', color: value, selected: true, onTap: null),
          ],
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final String name;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  const _Dot({super.key, required this.name, required this.color, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    final ink = color.computeLuminance() > 0.4 ? Colors.black87 : Colors.white;
    return Tooltip(
      message: name,
      child: Semantics(
        button: true,
        selected: selected,
        label: name,
        child: InkResponse(
          onTap: onTap,
          radius: 32,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? context.palette.textPrimary : context.palette.borderSoft,
                width: selected ? 3 : 1,
              ),
            ),
            child: selected ? Icon(Icons.check, color: ink, size: 28) : null,
          ),
        ),
      ),
    );
  }
}
