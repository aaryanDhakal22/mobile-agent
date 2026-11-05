import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';

/// Which tickets Kitchen shows (2.0.4): all, deliveries, or everything else
/// (pickups and counter orders).
enum KitchenFilter {
  all('All'),
  delivery('Delivery'),
  pickup('Pickup');

  final String label;
  const KitchenFilter(this.label);
}

/// How Kitchen orders its tickets (2.0.4): most urgent first (the estimate
/// the cook picked), or by ticket — the order received, online and POS
/// together (their numbers come from different counters).
enum KitchenSort {
  urgency('Urgency'),
  received('Ticket number');

  final String label;
  const KitchenSort(this.label);
}

/// The Kitchen board's view on this tablet (2.0.4): the filter buttons and
/// the gear's two settings. Kept until changed, across restarts.
@immutable
class KitchenView {
  final KitchenFilter filter;

  /// Condensed tickets: the name and the item names, no modifiers or notes.
  final bool condensed;
  final KitchenSort sort;

  const KitchenView({this.filter = KitchenFilter.all, this.condensed = false, this.sort = KitchenSort.urgency});

  KitchenView copyWith({KitchenFilter? filter, bool? condensed, KitchenSort? sort}) =>
      KitchenView(filter: filter ?? this.filter, condensed: condensed ?? this.condensed, sort: sort ?? this.sort);
}

class KitchenViewNotifier extends Notifier<KitchenView> {
  static const kFilter = 'kitchen_filter';
  static const kCondensed = 'kitchen_condensed';
  static const kSort = 'kitchen_sort';

  @override
  KitchenView build() {
    final prefs = ref.watch(storageProvider).prefs;
    T pick<T extends Enum>(List<T> values, String? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    return KitchenView(
      filter: pick(KitchenFilter.values, prefs.getString(kFilter), KitchenFilter.all),
      condensed: prefs.getBool(kCondensed) ?? false,
      sort: pick(KitchenSort.values, prefs.getString(kSort), KitchenSort.urgency),
    );
  }

  void setFilter(KitchenFilter f) {
    state = state.copyWith(filter: f);
    unawaited(ref.read(storageProvider).prefs.setString(kFilter, f.name));
  }

  void setCondensed(bool on) {
    state = state.copyWith(condensed: on);
    unawaited(ref.read(storageProvider).prefs.setBool(kCondensed, on));
  }

  void setSort(KitchenSort s) {
    state = state.copyWith(sort: s);
    unawaited(ref.read(storageProvider).prefs.setString(kSort, s.name));
  }
}

final kitchenViewProvider = NotifierProvider<KitchenViewNotifier, KitchenView>(KitchenViewNotifier.new);

/// Whether [filter] shows [so]: Delivery = deliveries, Pickup = the rest
/// (pickups and counter / dine-in orders).
bool kitchenShows(KitchenFilter filter, StoredOrder so) =>
    filter == KitchenFilter.all || (filter == KitchenFilter.delivery) == so.isDelivery;

/// The filter button an order counts under (never All).
KitchenFilter kitchenKind(StoredOrder so) => so.isDelivery ? KitchenFilter.delivery : KitchenFilter.pickup;

/// When a ticket arrived in the kitchen — what its timer counts from: a POS
/// check's send, else the Pi's arrival, the order's own time, the accept.
DateTime? ticketArrival(StoredOrder so) =>
    so.status.sentAt ?? so.status.arrivalDate ?? so.order.receivedAt ?? so.status.acceptedAt;

/// [orders] by ticket: oldest received first (online and POS together);
/// one with no time goes last; ties keep their urgency order.
List<StoredOrder> byReceived(List<StoredOrder> orders) {
  final indexed = [for (var i = 0; i < orders.length; i++) (i, orders[i])];
  indexed.sort((a, b) {
    final ta = ticketArrival(a.$2), tb = ticketArrival(b.$2);
    if (ta != null && tb != null && ta != tb) return ta.compareTo(tb);
    if ((ta == null) != (tb == null)) return ta == null ? 1 : -1;
    return a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// New tickets the filter hides (2.0.4), for the whole session like
/// [KitchenSeen]: the board on the first load is known, every later ticket
/// is noted once, and one the filter hides stays "unseen" under its button
/// until that button (or All) is chosen or the ticket leaves the board.
class KitchenHiddenNew {
  final Set<String> _known = {};
  final Map<KitchenFilter, Set<String>> _unseen = {KitchenFilter.delivery: {}, KitchenFilter.pickup: {}};
  bool _seeded = false;

  bool get seeded => _seeded;

  void seed(Iterable<String> ids) {
    _known.addAll(ids);
    _seeded = true;
  }

  /// Notes [board] (every cooking order, unfiltered) under [filter]; returns
  /// the buttons that should blink.
  Set<KitchenFilter> update(List<StoredOrder> board, KitchenFilter filter) {
    final on = {for (final o in board) o.id};
    for (final s in _unseen.values) {
      s.removeWhere((id) => !on.contains(id));
    }
    if (_seeded) {
      for (final o in board) {
        if (_known.add(o.id) && !kitchenShows(filter, o)) _unseen[kitchenKind(o)]!.add(o.id);
      }
    }
    choose(filter); // what the filter shows is seen
    final blink = {
      for (final e in _unseen.entries)
        if (e.value.isNotEmpty) e.key,
    };
    if (blink.isNotEmpty && filter != KitchenFilter.all) blink.add(KitchenFilter.all);
    return blink;
  }

  /// The button [chosen] shows its kind's new tickets: they are seen.
  void choose(KitchenFilter chosen) {
    for (final k in _unseen.keys) {
      if (chosen == KitchenFilter.all || chosen == k) _unseen[k]!.clear();
    }
  }
}

final kitchenHiddenNewProvider = Provider<KitchenHiddenNew>((_) => KitchenHiddenNew());

/// All · Delivery · Pickup with their counts, and the gear (2.0.4). A
/// button with a new ticket the filter hides blinks (Motion off: a solid
/// amber highlight).
class KitchenFilterRow extends ConsumerWidget {
  final Map<KitchenFilter, int> counts;
  final Set<KitchenFilter> blink;
  const KitchenFilterRow({super.key, required this.counts, this.blink = const {}});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(kitchenViewProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
      child: Row(
        children: [
          for (final f in KitchenFilter.values) ...[
            _FilterButton(
              key: ValueKey('kitchen-filter-${f.name}'),
              label: f.label,
              count: counts[f] ?? 0,
              selected: view.filter == f,
              blink: blink.contains(f),
              onTap: () {
                ref.read(kitchenHiddenNewProvider).choose(f);
                ref.read(kitchenViewProvider.notifier).setFilter(f);
              },
            ),
            QuiccSpace.gapSm,
          ],
          const Spacer(),
          Tooltip(
            message: 'Kitchen view',
            child: SizedBox(
              width: 56,
              height: 52,
              child: OutlinedButton(
                key: const ValueKey('kitchen-gear'),
                style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(56, 52)),
                onPressed: () => showKitchenViewSheet(context),
                child: const Icon(Icons.settings_outlined, size: 26, semanticLabel: 'Kitchen view'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterButton extends ConsumerStatefulWidget {
  final String label;
  final int count;
  final bool selected;
  final bool blink;
  final VoidCallback onTap;
  const _FilterButton({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.blink,
    required this.onTap,
  });

  @override
  ConsumerState<_FilterButton> createState() => _FilterButtonState();
}

/// One blink: about 0.9 s on, then off.
const Duration kFilterBlink = Duration(milliseconds: 1800);

/// The highlight of a button with hidden new tickets.
const Color kFilterBlinkColor = QuiccColors.statusFiring;

class _FilterButtonState extends ConsumerState<_FilterButton> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(vsync: this, duration: kFilterBlink);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final motion = Motion.of(context, ref);
    final animate = widget.blink && motion.full;
    if (animate && !_blink.isAnimating) {
      _blink.repeat();
    } else if (!animate && _blink.isAnimating) {
      _blink.stop();
      _blink.value = 0;
    }
    final p = context.palette;
    final fg = widget.selected ? Colors.white : p.textPrimary;
    Widget button(double glow) {
      final bg = widget.selected ? QuiccColors.brand600 : p.bgSurface;
      return Material(
        color: Color.lerp(bg, kFilterBlinkColor, glow),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          side: BorderSide(
            color: glow > 0 ? kFilterBlinkColor : (widget.selected ? QuiccColors.brand600 : p.borderSoft),
            width: 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52, minWidth: 112),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: QuiccSpace.lg),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.label,
                    style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700, color: fg),
                  ),
                  QuiccSpace.gapSm,
                  Text(
                    '${widget.count}',
                    key: const ValueKey('filter-count'),
                    style: QuiccType.number(
                      QuiccType.heading,
                      weight: FontWeight.w700,
                      color: fg.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final Widget child;
    if (animate) {
      child = AnimatedBuilder(
        animation: _blink,
        // On for the first half of each beat, off for the second.
        builder: (context, _) => button(_blink.value < 0.5 ? 0.85 : 0),
      );
    } else {
      child = button(widget.blink ? 0.85 : 0);
    }
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.label}, ${widget.count}${widget.blink ? ', new' : ''}',
      child: KeyedSubtree(key: widget.blink ? const ValueKey('filter-blink') : null, child: child),
    );
  }
}

/// The gear's sheet (2.0.4): Expanded / Condensed tickets and Urgency /
/// Ticket number order, for this tablet.
Future<void> showKitchenViewSheet(BuildContext context) =>
    showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (_) => const KitchenViewSheet());

class KitchenViewSheet extends ConsumerWidget {
  const KitchenViewSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(kitchenViewProvider);
    final n = ref.read(kitchenViewProvider.notifier);
    Widget row<T>(
      String title,
      String caption,
      Key key,
      List<T> values,
      String Function(T) label,
      T selected,
      ValueChanged<T> onChanged,
    ) {
      return Padding(
        padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700)),
                  Text(caption, style: QuiccType.text(QuiccType.caption, color: context.palette.textMuted)),
                ],
              ),
            ),
            QuiccSpace.gapMd,
            SegmentedButton<T>(
              key: key,
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                minimumSize: const Size(150, 56),
                textStyle: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
              ),
              segments: [for (final v in values) ButtonSegment(value: v, label: Text(label(v)))],
              selected: {selected},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ],
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(QuiccSpace.xl, 0, QuiccSpace.xl, QuiccSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: QuiccSpace.lg),
              child: Text('Kitchen view', style: QuiccType.text(QuiccType.title, weight: FontWeight.w700)),
            ),
            row<bool>(
              'Tickets',
              'Condensed: the name and the items, no modifiers or notes.',
              const ValueKey('kitchen-condensed'),
              const [false, true],
              (v) => v ? 'Condensed' : 'Expanded',
              view.condensed,
              n.setCondensed,
            ),
            row<KitchenSort>(
              'Order',
              'Ticket number: the order received, online and POS together.',
              const ValueKey('kitchen-sort'),
              KitchenSort.values,
              (v) => v.label,
              view.sort,
              n.setSort,
            ),
          ],
        ),
      ),
    );
  }
}
