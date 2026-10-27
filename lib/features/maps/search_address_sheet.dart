import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/friendly_error.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_spacing.dart';
import '../../theme/quicc_type.dart';
import '../common/widgets.dart';
import 'check_address_sheet.dart';

/// What the SEARCH ADDRESS sheet asks the map to do when it closes.
enum SearchAddressOutcome {
  /// Staff gave up on the search: drop a pin on the map instead.
  placePin,
}

/// How long the sheet waits for main's answer after the Pi said 202.
const Duration kGeoSearchTimeout = Duration(seconds: 20);

/// SEARCH ADDRESS (1.7.2): staff type the address again for a delivery main
/// couldn't find (`POST /api/orders/{id}/geo/search`). [canPin] offers PLACE
/// PIN in the sheet (only when the map can take a pin).
Future<SearchAddressOutcome?> showSearchAddressSheet(BuildContext context, StoredOrder order, {bool canPin = true}) =>
    showModalBottomSheet<SearchAddressOutcome>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SearchAddressSheet(order: order, canPin: canPin),
    );

/// "1613 Wadsworth Way" from "1613 Wadsworth Way, HOUSE": the street part of
/// the typed address (its first comma segment), to start the search from.
String searchPrefill(Address? a) {
  if (a == null || a.isEmpty) return '';
  final l1 = a.line1.trim();
  final s = l1.isNotEmpty ? l1 : a.oneLine;
  return s.split(',').first.trim();
}

/// The messages the sheet shows (also used by the tests).
abstract final class SearchAddressText {
  static const searching = 'Searching near the store…';
  static const noMatch = 'No match — try a different spelling, or PLACE PIN';
  static const badQuery = 'Type a street and number';
  static const mainOffline = "The Pi can't reach Quicc right now — try again in a minute";
  static const unsupported = 'This Pi needs an update to search addresses';
  static const found = 'Address found — the route shows in a moment';
}

enum _Phase { idle, sending, searching, results, noMatch, error }

class SearchAddressSheet extends ConsumerStatefulWidget {
  final StoredOrder order;
  final bool canPin;
  const SearchAddressSheet({super.key, required this.order, this.canPin = true});

  @override
  ConsumerState<SearchAddressSheet> createState() => _SearchAddressSheetState();
}

class _SearchAddressSheetState extends ConsumerState<SearchAddressSheet> {
  late final TextEditingController _query = TextEditingController(
    text: searchPrefill(widget.order.order.fulfillment.address),
  );
  _Phase _phase = _Phase.idle;
  String? _error;

  /// The Pi (or main) has no search: only PLACE PIN is left.
  bool _unsupported = false;
  bool _choosing = false;

  /// The order's location when the search was sent; main's answer is the
  /// first different one.
  String? _baseline;
  Timer? _timeout;

  @override
  void dispose() {
    _timeout?.cancel();
    _query.dispose();
    super.dispose();
  }

  static String _signature(OrderGeo? g) => g == null
      ? ''
      : '${g.state.wire}|${g.updatedAt?.toIso8601String()}|${g.candidates.map((c) => c.title).join(';')}';

  OrderGeo? get _geo => ref.read(floorProvider).orders[widget.order.id]?.geo;

  bool get _waiting => _phase == _Phase.sending || _phase == _Phase.searching;

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) {
      setState(() {
        _phase = _Phase.error;
        _error = SearchAddressText.badQuery;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    _timeout?.cancel();
    _baseline = _signature(_geo);
    setState(() {
      _phase = _Phase.sending;
      _error = null;
    });
    try {
      await ref.read(floorProvider.notifier).searchGeo(widget.order.id, q);
      if (!mounted || _phase != _Phase.sending) return; // main already answered
      setState(() => _phase = _Phase.searching);
      _timeout = Timer(kGeoSearchTimeout, () {
        if (mounted && _waiting) setState(() => _phase = _Phase.noMatch);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = switch (e) {
          AgentException(code: kBadQuery) => SearchAddressText.badQuery,
          AgentException(code: kMainOffline) => SearchAddressText.mainOffline,
          AgentException(code: kGeoSearchUnsupported) => SearchAddressText.unsupported,
          _ => 'Not searched. ${FriendlyError.from(e).short}.',
        };
        if (e is AgentException && e.code == kGeoSearchUnsupported) _unsupported = true;
      });
    }
  }

  /// Main's answer arrives as an order update.
  void _onGeo(OrderGeo? g) {
    if (!_waiting || g == null || g.state == GeoState.pending) return;
    if (_signature(g) == _baseline) return;
    _timeout?.cancel();
    switch (g.state) {
      case GeoState.check when g.candidates.isNotEmpty:
        setState(() => _phase = _Phase.results);
      case GeoState.located:
        final messenger = ScaffoldMessenger.maybeOf(context);
        Navigator.of(context).pop();
        messenger?.showSnackBar(
          const SnackBar(behavior: SnackBarBehavior.floating, content: Text(SearchAddressText.found)),
        );
      default:
        setState(() => _phase = _Phase.noMatch);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<OrderGeo?>(floorProvider.select((s) => s.orders[widget.order.id]?.geo), (_, g) => _onGeo(g));
    final so = ref.watch(floorProvider.select((s) => s.orders[widget.order.id])) ?? widget.order;
    final typed = so.order.fulfillment.address;
    final candidates = so.geo?.candidates ?? const <GeoCandidate>[];
    final p = context.palette;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(28, 0, 28, QuiccSpace.xl + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Search the address · ${so.displayNumber}',
                style: QuiccType.text(QuiccType.title, weight: FontWeight.w700),
              ),
              QuiccSpace.gapXs,
              Text(
                'Typed: ${typed == null || typed.isEmpty ? 'no address' : typed.oneLine}',
                style: QuiccType.text(QuiccType.body, color: p.textSecondary),
              ),
              QuiccSpace.gapLg,
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('search-query'),
                      controller: _query,
                      enabled: !_waiting && !_unsupported,
                      textInputAction: TextInputAction.search,
                      textCapitalization: TextCapitalization.words,
                      style: QuiccType.text(QuiccType.heading),
                      decoration: const InputDecoration(
                        labelText: 'Street and number',
                        hintText: 'e.g. 1613 Wadsworth Way',
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  QuiccSpace.gapMd,
                  SizedBox(
                    height: 56,
                    child: FilledButton.icon(
                      key: const ValueKey('search-go'),
                      onPressed: _waiting || _unsupported || _choosing ? null : _search,
                      icon: const Icon(Icons.search),
                      label: const Text('SEARCH'),
                    ),
                  ),
                ],
              ),
              QuiccSpace.gapLg,
              ..._status(candidates, p),
              if (widget.canPin) ...[
                QuiccSpace.gapMd,
                SizedBox(
                  height: 56,
                  child: _unsupported || _phase == _Phase.noMatch
                      ? FilledButton.icon(
                          key: const ValueKey('search-place-pin'),
                          onPressed: _placePin,
                          icon: const Icon(Icons.push_pin_outlined),
                          label: const Text('PLACE PIN'),
                        )
                      : OutlinedButton.icon(
                          key: const ValueKey('search-place-pin'),
                          onPressed: _choosing ? null : _placePin,
                          icon: const Icon(Icons.push_pin_outlined),
                          label: const Text('PLACE PIN'),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _placePin() => Navigator.of(context).pop(SearchAddressOutcome.placePin);

  List<Widget> _status(List<GeoCandidate> candidates, QuiccPalette p) => switch (_phase) {
    _Phase.idle => [
      Text(
        'Fix the spelling or the number, then SEARCH. Quicc looks near the store.',
        style: QuiccType.text(QuiccType.label, color: p.textMuted),
      ),
    ],
    _Phase.sending || _Phase.searching => [
      Row(
        key: const ValueKey('search-busy'),
        children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          QuiccSpace.gapMd,
          Text(SearchAddressText.searching, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
        ],
      ),
    ],
    _Phase.results => [
      Text('Which one is it?', style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
      QuiccSpace.gapSm,
      CandidateList(orderId: widget.order.id, candidates: candidates, onBusy: (b) => setState(() => _choosing = b)),
    ],
    _Phase.noMatch => [
      Row(
        key: const ValueKey('search-no-match'),
        children: [
          const Icon(Icons.search_off, color: QuiccColors.statusFiring),
          QuiccSpace.gapSm,
          Expanded(
            child: Text(SearchAddressText.noMatch, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
          ),
        ],
      ),
    ],
    _Phase.error => [InlineError(_error ?? SearchAddressText.badQuery)],
  };
}
