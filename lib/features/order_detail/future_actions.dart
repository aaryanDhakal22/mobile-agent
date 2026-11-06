import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/time.dart';
import '../../theme/quicc_colors.dart';
import '../../theme/quicc_type.dart';
import '../arrived/time_picker.dart';
import '../common/widgets.dart';

// 2.0.5 (Pi 2.4.3): a waiting future order's actions on its details — MAKE
// NOW, CHANGE DUE TIME, PRINT NOW and CANCEL ORDER (next to CHANGE LEAD
// TIME). The dialogs live here; the panel calls the floor notifier.

/// How far ahead a due time may move (the Pi refuses more).
const int kMaxDueDays = 14;

/// The due-time wheel's step.
const int kDueStepMinutes = 5;

/// "Today 7:30 PM", "Tomorrow 11:00 PM" or "Fri, Nov 7 · 11:00 PM".
String dayClock(DateTime t, {DateTime? now}) {
  final l = t.toLocal();
  final n = (now ?? timeNow()).toLocal();
  final day = DateTime(l.year, l.month, l.day);
  final today = DateTime(n.year, n.month, n.day);
  final d = day.difference(today).inDays;
  if (d == 0) return 'Today ${clock(l)}';
  if (d == 1) return 'Tomorrow ${clock(l)}';
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${wd[l.weekday - 1]}, ${mo[l.month - 1]} ${l.day} · ${clock(l)}';
}

/// The times the wheel offers on [day]: every 5 minutes of that day, from
/// the next 5-minute mark after [now] when it is today.
List<DateTime> dueSlots(DateTime day, DateTime now) {
  final start = DateTime(day.year, day.month, day.day);
  final out = <DateTime>[];
  for (var m = 0; m < 24 * 60; m += kDueStepMinutes) {
    final t = start.add(Duration(minutes: m));
    if (t.isAfter(now)) out.add(t);
  }
  return out;
}

// --- MAKE NOW ----------------------------------------------------------------------------

/// "Make it now?" with the prep time: the store default for its type and
/// −5 / +5, like a delivery's ACCEPT. Null = cancelled.
Future<int?> showMakeNowDialog(BuildContext context, {required int base, String? subtitle}) =>
    showDialog<int>(context: context, builder: (_) => _MakeNowDialog(base: base, subtitle: subtitle));

class _MakeNowDialog extends StatefulWidget {
  final int base;
  final String? subtitle;
  const _MakeNowDialog({required this.base, this.subtitle});

  @override
  State<_MakeNowDialog> createState() => _MakeNowDialogState();
}

class _MakeNowDialogState extends State<_MakeNowDialog> {
  late int _v = widget.base.clamp(TimePickerMath.nudgeFloor, DefaultTimes.maxMinutes);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Make it now?'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            [
              ?widget.subtitle,
              'It is accepted right away: the kitchen tickets and the receipt print, and it cooks like a new order.',
            ].join(' — '),
            style: TextStyle(color: context.palette.textSecondary, fontSize: 16),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _NudgeButton(
                key: const ValueKey('make-now-minus'),
                label: '−5',
                onTap: _v <= TimePickerMath.nudgeFloor ? null : () => setState(() => _v = TimePickerMath.nudgeDown(_v)),
              ),
              Expanded(
                child: Text(
                  '$_v MIN',
                  key: const ValueKey('make-now-minutes'),
                  textAlign: TextAlign.center,
                  style: QuiccType.number(QuiccType.display, weight: FontWeight.w700),
                ),
              ),
              _NudgeButton(
                key: const ValueKey('make-now-plus'),
                label: '+5',
                onTap: _v >= DefaultTimes.maxMinutes ? null : () => setState(() => _v = TimePickerMath.nudgeUp(_v)),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CANCEL')),
      FilledButton.icon(
        key: const ValueKey('make-now-confirm'),
        onPressed: () => Navigator.of(context).pop(_v),
        icon: const Icon(Icons.print),
        label: Text('MAKE NOW · $_v MIN'),
      ),
    ],
  );
}

class _NudgeButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _NudgeButton({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 88,
    height: 64,
    child: OutlinedButton(
      onPressed: onTap,
      child: Text(label, style: QuiccType.number(QuiccType.title, weight: FontWeight.w700)),
    ),
  );
}

// --- CHANGE DUE TIME -----------------------------------------------------------------------

/// The new due time: Today / Tomorrow / a picked date (≤ 14 days), then a
/// time on a 5-minute wheel, with "rings at …" when it has a lead. Null =
/// cancelled.
Future<DateTime?> showDuePicker(BuildContext context, {required DateTime current, int? leadMinutes}) =>
    showDialog<DateTime>(
      context: context,
      builder: (_) => _DueDialog(current: current, leadMinutes: leadMinutes),
    );

class _DueDialog extends StatefulWidget {
  final DateTime current;
  final int? leadMinutes;
  const _DueDialog({required this.current, this.leadMinutes});

  @override
  State<_DueDialog> createState() => _DueDialogState();
}

class _DueDialogState extends State<_DueDialog> {
  final DateTime _now = timeNow();
  late DateTime _day;
  late List<DateTime> _slots;
  late FixedExtentScrollController _wheel;
  int _index = 0;

  DateTime get _today => DateTime(_now.year, _now.month, _now.day);

  @override
  void initState() {
    super.initState();
    final cur = widget.current.toLocal();
    final last = _today.add(const Duration(days: kMaxDueDays));
    final day = DateTime(cur.year, cur.month, cur.day);
    _day = day.isBefore(_today) || day.isAfter(last) ? _today : day;
    _slots = dueSlots(_day, _now);
    _index = _closest(cur);
    _wheel = FixedExtentScrollController(initialItem: _index);
  }

  @override
  void dispose() {
    _wheel.dispose();
    super.dispose();
  }

  int _closest(DateTime t) {
    if (_slots.isEmpty) return 0;
    var best = 0;
    for (var i = 0; i < _slots.length; i++) {
      if ((_slots[i].difference(t)).abs() < (_slots[best].difference(t)).abs()) best = i;
    }
    return best;
  }

  void _pickDay(DateTime day) {
    final keep = _slots.isEmpty ? null : _slots[_index];
    setState(() {
      _day = day;
      _slots = dueSlots(day, _now);
      _index = keep == null
          ? 0
          : _closest(DateTime(day.year, day.month, day.day, keep.hour, keep.minute));
    });
    // A new list: start the wheel where the same time of day is.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_wheel.hasClients) _wheel.jumpToItem(_index);
    });
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: _today,
      lastDate: _today.add(const Duration(days: kMaxDueDays)),
    );
    if (d != null && mounted) _pickDay(d);
  }

  @override
  Widget build(BuildContext context) {
    final tomorrow = _today.add(const Duration(days: 1));
    final picked = _slots.isEmpty ? null : _slots[math.min(_index, _slots.length - 1)];
    final lead = widget.leadMinutes;
    final otherDay = _day != _today && _day != tomorrow;
    return AlertDialog(
      title: const Text('When is it due?'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                ChoiceChip(
                  key: const ValueKey('due-today'),
                  label: const Text('Today'),
                  selected: _day == _today,
                  onSelected: (_) => _pickDay(_today),
                ),
                ChoiceChip(
                  key: const ValueKey('due-tomorrow'),
                  label: const Text('Tomorrow'),
                  selected: _day == tomorrow,
                  onSelected: (_) => _pickDay(tomorrow),
                ),
                ChoiceChip(
                  key: const ValueKey('due-date'),
                  avatar: const Icon(Icons.calendar_month, size: 18),
                  label: Text(otherDay ? dayClock(_day, now: _now).split(' · ').first : 'Pick a date'),
                  selected: otherDay,
                  onSelected: (_) => _pickDate(),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 220,
              child: _slots.isEmpty
                  ? Center(
                      child: Text('No times left today.', style: TextStyle(color: context.palette.textSecondary)),
                    )
                  : ListWheelScrollView.useDelegate(
                      key: ValueKey('due-wheel-$_day'),
                      controller: _wheel,
                      itemExtent: 52,
                      diameterRatio: 1.6,
                      physics: const FixedExtentScrollPhysics(),
                      onSelectedItemChanged: (i) => setState(() => _index = i),
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: _slots.length,
                        builder: (context, i) => Center(
                          child: Text(
                            clock(_slots[i]),
                            style: QuiccType.number(
                              QuiccType.title,
                              weight: i == _index ? FontWeight.w800 : FontWeight.w500,
                              color: i == _index ? null : context.palette.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              picked == null
                  ? 'Pick another day.'
                  : 'Due ${dayClock(picked, now: _now)}'
                        '${lead == null ? '' : ' · rings at ${clock(picked.subtract(Duration(minutes: lead)))}'}',
              key: const ValueKey('due-summary'),
              style: TextStyle(color: context.palette.textSecondary, fontSize: 16),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CANCEL')),
        FilledButton(
          key: const ValueKey('due-confirm'),
          onPressed: picked == null ? null : () => Navigator.of(context).pop(picked),
          child: const Text('SAVE'),
        ),
      ],
    );
  }
}

// --- PRINT NOW -----------------------------------------------------------------------------

/// What PRINT NOW prints.
enum FuturePrint {
  kitchen(withKitchen: true, withReceipt: false, label: 'Kitchen tickets'),
  receipt(withKitchen: false, withReceipt: true, label: 'Receipt'),
  both(withKitchen: true, withReceipt: true, label: 'Both');

  final bool withKitchen;
  final bool withReceipt;
  final String label;
  const FuturePrint({required this.withKitchen, required this.withReceipt, required this.label});
}

/// Kitchen tickets / Receipt / Both. Null = cancelled.
Future<FuturePrint?> showPrintNowDialog(BuildContext context) => showDialog<FuturePrint>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('Print now?'),
    content: SizedBox(
      width: 460,
      child: Text(
        'The kitchen tickets say DO NOT MAKE with when it is due; the receipt has FUTURE on top. '
        'Nothing changes on the order.',
        style: TextStyle(color: ctx.palette.textSecondary, fontSize: 16),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('CANCEL')),
      for (final p in FuturePrint.values)
        FilledButton.tonal(
          key: ValueKey('print-now-${p.name}'),
          onPressed: () => Navigator.of(ctx).pop(p),
          child: Text(p.label.toUpperCase()),
        ),
    ],
  ),
);

// --- CANCEL ---------------------------------------------------------------------------------

/// The refund line on a card-paid future order's cancel.
const String kCardRefundNote = 'Paid by card — refund it with the online ordering company.';

/// The red "Cancel this order?" with the customer and total (and the card
/// refund reminder).
Future<bool> confirmCancelFuture(BuildContext context, StoredOrder so) {
  final o = so.order;
  final who = o.customerName.trim().isEmpty ? so.displayNumber : o.customerName.trim();
  final due = so.dueAt;
  return confirmDialog(
    context,
    title: 'Cancel this order?',
    message: [
      '$who · ${money(o.money.totalCents)}${due == null ? '' : ' · due ${dayClock(due)}'}',
      'It leaves the board for good.',
      if (o.isPrepaid) kCardRefundNote,
    ].join('\n\n'),
    confirm: 'CANCEL ORDER',
    cancel: 'KEEP IT',
    destructive: true,
  );
}
