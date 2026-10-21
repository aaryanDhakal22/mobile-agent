import '../common/info_button.dart';

// The (i) copy for the Batch tab.

const kCloseBatchInfo = InfoText(
  'Close batch',
  'Do it once at the end of the day (or the end of a shift), after the last order is out.\n\n'
      'What happens:\n'
      '• Each driver\'s report prints on the receipt printer — one slip per driver.\n'
      '• Kitchen numbers start again at 1100.\n'
      '• Drivers who are still out go back to the queue.\n\n'
      'If some orders are not finished, the tablet lists them and asks first. Closing anyway marks '
      'them done; orders nobody accepted are cancelled.',
);

/// The driver report maths, with the store's tip tax ([tipTaxPercent], 6 %
/// unless changed in the agent web UI).
InfoText driverReportInfo(double tipTaxPercent) {
  final pct = tipTaxPercent == tipTaxPercent.roundToDouble()
      ? tipTaxPercent.toStringAsFixed(0)
      : tipTaxPercent.toStringAsFixed(1);
  return InfoText(
    'How the driver report adds up',
    'Deliveries: how many orders the driver took out in this batch.\n\n'
        'Cash owed: the cash the driver collected from customers who paid cash. Card orders are '
        'paid to the store, so they don\'t count here.\n\n'
        'Tips (A/T): all the driver\'s tips — cash and card — minus the $pct% tip tax. '
        'Example: \$10.00 in tips → \$${(10 * (100 - tipTaxPercent) / 100).toStringAsFixed(2)} for the driver.\n\n'
        'Owed to store = cash owed − tips after tax. The driver hands that much to the store. If the '
        'tips are bigger than the cash, it shows "Store owes driver" and the store pays them that '
        'amount.\n\n'
        'Delivery fees are paid weekly, not on this report.',
  );
}
