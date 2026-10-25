import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the add / edit driver dialog returns.
typedef DriverInput = ({String name, String posNumber});

/// Help under the Driver # field.
const String kDriverNumberHelp = 'Their SoftTouch login number. The POS gets it when they go out.';

/// Add / edit a driver: name + Driver # (their SoftTouch login #, optional).
/// Resolves the trimmed values, or null when cancelled.
Future<DriverInput?> driverDialog(
  BuildContext context, {
  required String title,
  String name = '',
  String posNumber = '',
  String confirm = 'SAVE',
}) => showDialog<DriverInput>(
  context: context,
  builder: (_) => _DriverDialog(title: title, name: name, posNumber: posNumber, confirm: confirm),
);

/// The Driver # text field (digits only), shared with the setup wizard.
class DriverNumberField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onSubmitted;
  final bool dense;
  const DriverNumberField({super.key, required this.controller, this.onSubmitted, this.dense = false});

  @override
  Widget build(BuildContext context) => TextField(
    key: const ValueKey('driver-pos-number'),
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
    style: const TextStyle(fontSize: 20),
    decoration: InputDecoration(
      labelText: 'Driver #',
      hintText: '12',
      helperText: dense ? null : kDriverNumberHelp,
      helperMaxLines: 2,
    ),
    onSubmitted: onSubmitted,
  );
}

// Owns its controllers: disposing them when showDialog's future completes is
// too early — the fields still build during the exit animation.
class _DriverDialog extends StatefulWidget {
  final String title, name, posNumber, confirm;
  const _DriverDialog({required this.title, required this.name, required this.posNumber, required this.confirm});

  @override
  State<_DriverDialog> createState() => _DriverDialogState();
}

class _DriverDialogState extends State<_DriverDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late final TextEditingController _number = TextEditingController(text: widget.posNumber);

  @override
  void dispose() {
    _name.dispose();
    _number.dispose();
    super.dispose();
  }

  void _done() => Navigator.of(context).pop((name: _name.text.trim(), posNumber: _number.text.trim()));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('driver-name'),
            controller: _name,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(fontSize: 20),
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 4),
          DriverNumberField(controller: _number, onSubmitted: (_) => _done()),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CANCEL')),
      FilledButton(key: const ValueKey('driver-save'), onPressed: _done, child: Text(widget.confirm)),
    ],
  );
}

/// "Driver #12" (or nothing) for a row.
String? driverNumberLabel(String? n) => (n == null || n.isEmpty) ? null : 'Driver #$n';
