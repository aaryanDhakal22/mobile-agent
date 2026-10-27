import 'package:flutter/material.dart';

import '../features/common/island.dart';
import '../theme/quicc_colors.dart';
import 'models.dart';

/// 1234 → "$12.34" (money is always integer cents on the wire).
String money(int cents) {
  final neg = cents < 0;
  final abs = cents.abs();
  final s = '\$${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  return neg ? '-$s' : s;
}

/// Local wall-clock "5:07 PM".
String clock(DateTime? t) {
  if (t == null) return '—';
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final m = l.minute.toString().padLeft(2, '0');
  return '$h:$m ${l.hour < 12 ? 'AM' : 'PM'}';
}

/// A location-local "HH:MM" setting (e.g. the daily driver reset, "10:00")
/// as "10:00 AM". Anything unparsable is shown as-is.
String wallTime(String hhmm) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
  if (m == null) return hhmm;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return hhmm;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${m.group(2)} ${h < 12 ? 'AM' : 'PM'}';
}

/// "Oct 15, 5:07 PM".
String dateClock(DateTime? t) {
  if (t == null) return '—';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = t.toLocal();
  return '${months[l.month - 1]} ${l.day}, ${clock(t)}';
}

/// Elapsed / remaining time as "m:ss" under an hour, "h:mm:ss" above.
String duration(Duration d) {
  final neg = d.isNegative;
  final a = d.abs();
  final h = a.inHours;
  final m = a.inMinutes % 60;
  final s = (a.inSeconds % 60).toString().padLeft(2, '0');
  final body = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  return neg ? '-$body' : body;
}

/// "4 min" / "1 h 5 min".
String minutes(Duration d) {
  final m = d.inMinutes.abs();
  if (m < 60) return '$m min';
  return '${m ~/ 60} h ${m % 60} min';
}

Color stateColor(OrderState s) => switch (s) {
  OrderState.arrived => QuiccColors.statusFiring,
  OrderState.scheduled => Colors.grey,
  OrderState.accepted => QuiccColors.statusOpen,
  OrderState.ready => QuiccColors.statusPaid,
  OrderState.onDelivery => QuiccColors.brand400,
  OrderState.delivered => QuiccColors.statusPaid,
  OrderState.cancelled => Colors.grey,
  OrderState.unknown => Colors.grey,
};

IconData fulfillmentIcon(FulfillmentType t) => switch (t) {
  FulfillmentType.delivery => Icons.delivery_dining,
  FulfillmentType.pickup => Icons.shopping_bag_outlined,
  FulfillmentType.dineIn => Icons.restaurant,
  FulfillmentType.unknown => Icons.receipt_long_outlined,
};

/// "12 Medium Pepperoni Pizza" — size first, as it's called out in a kitchen.
String itemTitle(LineItem i) {
  final q = i.quantity > 1 ? '${i.quantity}× ' : '';
  final size = i.displaySize.isEmpty ? '' : '${i.displaySize} ';
  return '$q$size${i.name}';
}

/// A short notice from anywhere with a context: a pill in the notification
/// island, top-right (1.9.0 — it used to be a full-width bar at the bottom,
/// over SEND OUT and the driver button). [error] makes it red.
/// [rightInset] is kept for old callers and does nothing now.
void toast(BuildContext context, String message, {bool error = false, double rightInset = 0}) {
  Island.show(context, message, kind: error ? IslandKind.error : IslandKind.info);
}
