import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/diag_models.dart';
import '../../core/format.dart';
import '../../core/friendly_error.dart';
import '../../core/providers.dart';
import '../../core/receipt_models.dart';
import '../../theme/quicc_colors.dart';
import '../common/info_button.dart';
import '../common/widgets.dart';
import '../setup/steps/test_print_step.dart' show printerAdvice;
import 'settings_card.dart';
import 'settings_texts.dart';
import '../../theme/quicc_type.dart';
import '../../theme/quicc_spacing.dart';

/// Settings → Receipts: kitchen-ticket sizes, the customer receipt's footer,
/// copies and toggles (`/api/settings/receipt`), SAVE, PRINT SAMPLE on a
/// chosen printer (`/api/printers/sample`) and RESET TO DEFAULTS. An older Pi
/// (no such routes) gets "This Pi needs an update for receipt settings".
class ReceiptSettingsCard extends ConsumerStatefulWidget {
  const ReceiptSettingsCard({super.key});

  @override
  ConsumerState<ReceiptSettingsCard> createState() => _ReceiptSettingsCardState();
}

class _ReceiptSettingsCardState extends ConsumerState<ReceiptSettingsCard> {
  final _footerCtrl = TextEditingController();

  bool _loading = true;
  Object? _error;

  /// What the Pi has saved / its defaults / what the user is editing.
  ReceiptPrefs _saved = ReceiptPrefs.standard;
  ReceiptPrefs _defaults = ReceiptPrefs.standard;
  ReceiptPrefs _draft = ReceiptPrefs.standard;

  /// The store's own footer (shown when "Use the store default" is on);
  /// known when the saved footer is the store default.
  String _storeFooter = '';

  /// The last footer typed, restored when "Use the store default" is
  /// switched back off.
  String _typedFooter = '';

  List<DiagPrinter> _printers = const [];
  String? _printerId;

  bool _saving = false;
  bool _printing = false;

  bool get _dirty => _draft != _saved;
  bool get _busy => _saving || _printing;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPrinters();
  }

  @override
  void dispose() {
    _footerCtrl.dispose();
    super.dispose();
  }

  AgentClient? get _client => ref.read(agentClientProvider);

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _load();
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) return;
    try {
      final r = await client.getReceiptPrefs();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _defaults = r.defaults;
        _apply(r);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  /// The printer picker's list (from `/api/diag`, which carries ids and the
  /// receipt flag). Without it PRINT SAMPLE uses the receipt printer.
  Future<void> _loadPrinters() async {
    final client = _client;
    if (client == null) return;
    try {
      final d = await client.getDiag(timeout: const Duration(seconds: 6));
      final printers = d.printers.where((p) => p.id.isNotEmpty).toList();
      if (!mounted) return;
      setState(() {
        _printers = printers;
        if (!printers.any((p) => p.id == _printerId)) {
          _printerId = printers.isEmpty
              ? null
              : printers.firstWhere((p) => p.isReceipt, orElse: () => printers.first).id;
        }
      });
    } catch (_) {
      // No list: the sample goes to the receipt printer.
    }
  }

  /// Takes what the Pi saved as the new baseline (and the form's contents).
  void _apply(ReceiptSettings r) {
    _saved = r.prefs;
    _draft = r.prefs;
    if (r.footerStoreDefault.isNotEmpty) {
      _storeFooter = r.footerStoreDefault;
    } else if (r.prefs.usesStoreFooter) {
      _storeFooter = r.footerEffective;
    }
    _syncFooterField();
  }

  void _syncFooterField() {
    final text = _draft.footerText ?? '';
    if (_draft.footerText != null) _typedFooter = text;
    if (_footerCtrl.text != text) _footerCtrl.text = text;
  }

  /// Applies [change] to the latest draft (never a copy captured at build).
  void _edit(ReceiptPrefs Function(ReceiptPrefs) change) => setState(() => _draft = change(_draft));

  void _useStoreFooter(bool on) {
    setState(() {
      _draft = _draft.copyWith(footerText: on ? null : _typedFooter);
      _syncFooterField();
    });
  }

  /// The Pi lacks the receipt routes: the card shows that instead.
  bool _unsupported(Object e) => e is AgentException && e.code == kReceiptUnsupported;

  /// Plain words for a save / sample failure.
  FriendlyError _friendly(Object e) {
    if (e is AgentException && e.statusCode == 400 && e.message.isNotEmpty) {
      return FriendlyError(
        e.message,
        whatToDo: 'Change it, then tap SAVE again',
        details: 'HTTP 400 · ${e.code ?? ''} · ${e.message}',
      );
    }
    if (e is AgentException && e.code == 'not_configured') {
      return FriendlyError(
        'That printer is not set up',
        whatToDo: printerAdvice('not_configured'),
        details: 'HTTP ${e.statusCode} · not_configured · ${e.message}',
        guide: GuideId.printer,
      );
    }
    return FriendlyError.from(e);
  }

  /// PUT the draft. True when saved.
  Future<bool> _save({String? done = 'Receipt settings saved'}) async {
    final client = _client;
    if (client == null) return false;
    setState(() => _saving = true);
    try {
      final r = await client.putReceiptPrefs(_draft);
      if (!mounted) return true;
      setState(() => _apply(r));
      if (done != null) toast(context, done);
      return true;
    } catch (e) {
      if (!mounted) return false;
      if (_unsupported(e)) {
        setState(() => _error = e);
      } else {
        toastError(context, _friendly(e), lead: 'Not saved', area: 'settings');
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    final ok = await confirmDialog(
      context,
      title: 'Reset the receipts?',
      message:
          'Every receipt setting goes back to how it came, and the footer goes back to the store '
          'default.',
      confirm: 'RESET',
    );
    if (!ok || !mounted) return;
    setState(() {
      _draft = _defaults;
      _syncFooterField();
    });
    await _save(done: 'Receipts are back to the defaults');
  }

  /// Saves unsaved changes first, then prints the sample.
  Future<void> _printSample() async {
    final client = _client;
    if (client == null) return;
    if (_dirty && !await _save(done: null)) return;
    if (!mounted) return;
    setState(() => _printing = true);
    try {
      final results = await client.printSample(printerId: _printerId);
      if (!mounted) return;
      final failed = results.where((r) => !r.ok).toList();
      if (results.isEmpty) {
        toastError(
          context,
          const FriendlyError(
            'Nothing printed',
            whatToDo: 'No printers are set up on the Quicc website',
            guide: GuideId.printer,
          ),
          area: 'settings',
        );
      } else if (failed.isEmpty) {
        toast(context, 'Sample printed on ${results.map(_printerName).join(', ')}');
      } else {
        final f = failed.first;
        toastError(
          context,
          FriendlyError(
            'Not printed on ${_printerName(f)}',
            whatToDo: printerAdvice(f.errorCode),
            details: [f.errorCode, f.error].where((s) => s.isNotEmpty).join(' · '),
            guide: GuideId.printer,
          ),
          area: 'settings',
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (_unsupported(e)) {
        setState(() => _error = e);
      } else {
        toastError(context, _friendly(e), lead: 'Sample not printed', area: 'settings');
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  String _printerName(PrinterTestResult r) {
    if (r.name.isNotEmpty) return r.name;
    for (final p in _printers) {
      if (p.id == r.id) return p.name;
    }
    return 'the printer';
  }

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      title: 'Receipts',
      info: kReceiptsInfo,
      subtitle:
          'How the kitchen tickets, the customer receipt and the driver reports print. Used from the next order on.',
      children: [_body(context)],
    );
  }

  Widget _body(BuildContext context) {
    if (ref.watch(agentClientProvider) == null) {
      return Text('Pair this tablet with the Pi first.', style: TextStyle(color: context.palette.textMuted));
    }
    if (_loading) {
      return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
    }
    final err = _error;
    if (err != null) {
      if (_unsupported(err)) return const _NeedsUpdate();
      return InlineError.from(err, lead: 'Receipt settings not loaded', area: 'settings', onRetry: _retry);
    }
    final d = _draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Heading('Kitchen tickets'),
        _Setting(
          label: 'Item text size',
          info: kKitchenItemSizeInfo,
          child: _Choice<ReceiptSize>(
            values: ReceiptSize.values,
            label: (s) => s.label,
            selected: d.kitchenItemSize,
            onChanged: (v) => _edit((p) => p.copyWith(kitchenItemSize: v)),
          ),
        ),
        _Setting(
          label: 'Ticket number size',
          info: kKitchenNumberSizeInfo,
          child: _Choice<NumberSize>(
            values: NumberSize.values,
            label: (s) => s.label,
            selected: d.kitchenNumberSize,
            onChanged: (v) => _edit((p) => p.copyWith(kitchenNumberSize: v)),
          ),
        ),
        _Setting(
          label: 'Line spacing',
          info: kLineSpacingInfo,
          child: Wrap(
            key: const ValueKey('receipt-spacing'),
            spacing: 28,
            runSpacing: 8,
            children: [
              _Stepper(
                id: 'item_mod',
                label: 'Item→mod',
                value: d.spacing.itemMod,
                onStep: (by) => _edit((p) => p.copyWith(spacing: p.spacing.copyWith(itemMod: p.spacing.itemMod + by))),
              ),
              _Stepper(
                id: 'mod_mod',
                label: 'Mod→mod',
                value: d.spacing.modMod,
                onStep: (by) => _edit((p) => p.copyWith(spacing: p.spacing.copyWith(modMod: p.spacing.modMod + by))),
              ),
              _Stepper(
                id: 'item_item',
                label: 'Item→item',
                value: d.spacing.itemItem,
                onStep: (by) =>
                    _edit((p) => p.copyWith(spacing: p.spacing.copyWith(itemItem: p.spacing.itemItem + by))),
              ),
            ],
          ),
        ),
        QuiccSpace.gapSm,
        const _Heading('Customer receipt'),
        _Setting(
          label: 'Footer text',
          info: kFooterInfo,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SwitchRow(label: 'Use the store default', value: d.usesStoreFooter, onChanged: _useStoreFooter),
              QuiccSpace.gapSm,
              TextField(
                key: const ValueKey('receipt-footer'),
                controller: _footerCtrl,
                enabled: !d.usesStoreFooter,
                maxLength: kFooterMaxLength,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [FilteringTextInputFormatter.allow(kFooterAllowed)],
                style: QuiccType.text(QuiccType.heading),
                decoration: InputDecoration(
                  hintText: d.usesStoreFooter
                      ? (_storeFooter.isEmpty ? 'The store default' : _storeFooter)
                      : 'No footer',
                  helperText: d.usesStoreFooter
                      ? (_storeFooter.isEmpty ? null : 'Prints: $_storeFooter')
                      : 'Leave it empty for no footer',
                  prefixIcon: const Icon(Icons.short_text),
                ),
                onChanged: (t) {
                  _typedFooter = t;
                  _edit((p) => p.copyWith(footerText: t));
                },
              ),
            ],
          ),
        ),
        _Setting(
          label: 'Footer size',
          info: kFooterSizeInfo,
          child: _Choice<ReceiptSize>(
            values: ReceiptSize.values,
            label: (s) => s.label,
            selected: d.footerSize,
            onChanged: (v) => _edit((p) => p.copyWith(footerSize: v)),
          ),
        ),
        _Setting(
          label: 'Copies',
          info: kCopiesInfo,
          child: _Choice<int>(
            values: const [1, 2],
            label: (n) => n == 1 ? '1 copy' : '2 copies',
            selected: d.copies,
            onChanged: (v) => _edit((p) => p.copyWith(copies: v)),
          ),
        ),
        _SwitchRow(
          label: 'Show store name and address',
          info: kStoreAddressInfo,
          value: d.showStoreAddress,
          onChanged: (v) => _edit((p) => p.copyWith(showStoreAddress: v)),
        ),
        _SwitchRow(
          label: 'Show customer phone',
          info: kPhoneInfo,
          value: d.showPhone,
          onChanged: (v) => _edit((p) => p.copyWith(showPhone: v)),
        ),
        _SwitchRow(
          label: 'Extra paper before cutting',
          info: kExtraPaperInfo,
          value: d.extraPaper,
          onChanged: (v) => _edit((p) => p.copyWith(extraPaper: v)),
        ),
        QuiccSpace.gapSm,
        const _Heading('Driver reports'),
        _Setting(
          label: 'Text size',
          info: kDriverReportSizeInfo,
          child: _SizeSlider(
            selected: d.driverReportSize,
            onChanged: (v) => _edit((p) => p.copyWith(driverReportSize: v)),
          ),
        ),
        QuiccSpace.gapMd,
        if (_dirty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'You have changes that are not saved yet.',
              style: const TextStyle(color: QuiccColors.statusFiring, fontWeight: FontWeight.w600),
            ),
          ),
        _actions(context),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    Widget spinnerOr(bool spinning, IconData icon) =>
        spinning ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon);
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            onPressed: _dirty && !_busy ? () => _save() : null,
            icon: spinnerOr(_saving && !_printing, Icons.save_outlined),
            label: const Text('SAVE'),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_printers.isNotEmpty) ...[
              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('receipt-sample-printer'),
                  initialValue: _printerId,
                  isExpanded: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.print_outlined)),
                  items: [
                    for (final p in _printers)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(p.isReceipt ? '${p.name} (receipt)' : p.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _busy ? null : (id) => setState(() => _printerId = id),
                ),
              ),
              QuiccSpace.gapSm,
            ],
            SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _printSample,
                icon: spinnerOr(_printing, Icons.receipt_long_outlined),
                label: const Text('PRINT SAMPLE'),
              ),
            ),
            const InfoButton(kPrintSampleInfo),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 56,
              child: TextButton.icon(
                onPressed: _busy || _draft == _defaults ? null : _reset,
                icon: const Icon(Icons.restart_alt),
                label: const Text('RESET TO DEFAULTS'),
              ),
            ),
            const InfoButton(kResetReceiptInfo),
          ],
        ),
      ],
    );
  }
}

/// "This Pi needs an update for receipt settings", in place of the controls.
class _NeedsUpdate extends StatelessWidget {
  const _NeedsUpdate();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.system_update_outlined, color: context.palette.textMuted, size: 28),
        QuiccSpace.gapMd,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This Pi needs an update for receipt settings',
                style: QuiccType.text(QuiccType.body, weight: FontWeight.w700),
              ),
              Text(
                'Tell the owner. Receipts keep printing as they are.',
                style: TextStyle(color: context.palette.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700)),
  );
}

/// A label with its (i), then the control under it.
class _Setting extends StatelessWidget {
  final String label;
  final InfoText info;
  final Widget child;
  const _Setting({required this.label, required this.info, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: LabelWithInfo(
            label: Text(label, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
            info: info,
          ),
        ),
        QuiccSpace.gapSm,
        child,
      ],
    ),
  );
}

/// A big segmented picker.
class _Choice<T> extends StatelessWidget {
  final List<T> values;
  final String Function(T) label;
  final T selected;
  final ValueChanged<T> onChanged;
  const _Choice({required this.values, required this.label, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: SegmentedButton<T>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(120, 56),
        textStyle: QuiccType.text(QuiccType.body, weight: FontWeight.w600),
      ),
      segments: [for (final v in values) ButtonSegment(value: v, label: Text(label(v)))],
      selected: {selected},
      onSelectionChanged: (s) => onChanged(s.first),
    ),
  );
}

/// Small / Normal / Large on a three-stop slider, the names under it.
class _SizeSlider extends StatelessWidget {
  final DriverReportSize selected;
  final ValueChanged<DriverReportSize> onChanged;
  const _SizeSlider({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const values = DriverReportSize.values;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Slider(
              key: const ValueKey('receipt-driver-report-size'),
              value: selected.index.toDouble(),
              max: (values.length - 1).toDouble(),
              divisions: values.length - 1,
              label: selected.label,
              onChanged: (v) {
                final next = values[v.round()];
                if (next != selected) onChanged(next);
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final s in values)
                    Text(
                      s.label,
                      style: QuiccType.text(
                        QuiccType.body,
                        weight: s == selected ? FontWeight.w700 : FontWeight.w400,
                        color: s == selected ? null : context.palette.textMuted,
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

/// "Item→mod  −  8  +": extra dots, in [kSpacingStepDots] steps, 0 to
/// [kSpacingMaxDots].
class _Stepper extends StatelessWidget {
  final String id;
  final String label;
  final int value;

  /// Moves the value by ± [kSpacingStepDots] (applied to the latest draft,
  /// so quick taps all count; clamped to 0–[kSpacingMaxDots]).
  final ValueChanged<int> onStep;
  const _Stepper({required this.id, required this.label, required this.value, required this.onStep});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
      const SizedBox(width: 4),
      IconButton(
        key: ValueKey('spacing-$id-minus'),
        tooltip: 'Less space',
        onPressed: value > 0 ? () => onStep(-kSpacingStepDots) : null,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      SizedBox(
        width: 32,
        child: Text(
          '$value',
          key: ValueKey('spacing-$id-value'),
          textAlign: TextAlign.center,
          style: QuiccType.text(QuiccType.heading, weight: FontWeight.w700),
        ),
      ),
      IconButton(
        key: ValueKey('spacing-$id-plus'),
        tooltip: 'More space',
        onPressed: value < kSpacingMaxDots ? () => onStep(kSpacingStepDots) : null,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ],
  );
}

/// A label (+ optional (i)) with a switch at the end of the row.
class _SwitchRow extends StatelessWidget {
  final String label;
  final InfoText? info;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({required this.label, this.info, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: SizedBox(
      height: 56,
      child: Row(
        children: [
          // The label (+ its (i)) takes the free width, so every switch lines
          // up on the right edge.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(label, style: QuiccType.text(QuiccType.body, weight: FontWeight.w600)),
                ),
                if (info != null) InfoButton(info!, size: 18),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    ),
  );
}
