import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/friendly_error.dart';
import '../../core/models.dart';
import '../../theme/quicc_type.dart';
import '../common/island.dart';
import '../common/widgets.dart';

/// What the add / edit driver dialog returns.
typedef DriverInput = ({String name, String posNumber, String pushoverDevice});

/// Help under the Driver # field.
const String kDriverNumberHelp = 'Their SoftTouch Employee Number. The POS gets it when they go out.';

/// Help under the phone field.
const String kPushoverDeviceHelp = "Their phone's device name in the Pushover app. SEND OUT sends them their route.";

/// Add / edit a driver: name + Driver # (their SoftTouch Employee Number,
/// optional) + their phone's Pushover device name (optional, Pi 2.3.7).
/// [onSendTest] (an edit of a saved driver) adds SEND TEST, enabled while the
/// saved [pushoverDevice] is in the field. Resolves the trimmed values, or
/// null when cancelled.
Future<DriverInput?> driverDialog(
  BuildContext context, {
  required String title,
  String name = '',
  String posNumber = '',
  String pushoverDevice = '',
  String confirm = 'SAVE',
  Future<RouteTest> Function()? onSendTest,
}) => showDialog<DriverInput>(
  context: context,
  builder: (_) => _DriverDialog(
    title: title,
    name: name,
    posNumber: posNumber,
    pushoverDevice: pushoverDevice,
    confirm: confirm,
    onSendTest: onSendTest,
  ),
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
    style: QuiccType.number(QuiccType.heading, weight: FontWeight.w500),
    decoration: InputDecoration(
      labelText: 'Driver #',
      hintText: '12',
      helperText: dense ? null : kDriverNumberHelp,
      helperMaxLines: 2,
    ),
    onSubmitted: onSubmitted,
  );
}

/// The phone field: the driver's Pushover device name, [errorText] under it
/// when it isn't one ([pushoverDeviceError]).
class PushoverDeviceField extends StatelessWidget {
  final TextEditingController controller;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  const PushoverDeviceField({super.key, required this.controller, this.errorText, this.onChanged, this.onSubmitted});

  @override
  Widget build(BuildContext context) => TextField(
    key: const ValueKey('driver-pushover-device'),
    controller: controller,
    autocorrect: false,
    enableSuggestions: false,
    style: QuiccType.text(QuiccType.heading),
    decoration: InputDecoration(
      labelText: 'Phone (Pushover device)',
      hintText: 'e.g. abdul',
      helperText: kPushoverDeviceHelp,
      helperMaxLines: 2,
      errorText: errorText,
      errorMaxLines: 2,
    ),
    onChanged: onChanged,
    onSubmitted: onSubmitted,
  );
}

// Owns its controllers: disposing them when showDialog's future completes is
// too early — the fields still build during the exit animation.
class _DriverDialog extends StatefulWidget {
  final String title, name, posNumber, pushoverDevice, confirm;
  final Future<RouteTest> Function()? onSendTest;
  const _DriverDialog({
    required this.title,
    required this.name,
    required this.posNumber,
    required this.pushoverDevice,
    required this.confirm,
    this.onSendTest,
  });

  @override
  State<_DriverDialog> createState() => _DriverDialogState();
}

class _DriverDialogState extends State<_DriverDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late final TextEditingController _number = TextEditingController(text: widget.posNumber);
  late final TextEditingController _device = TextEditingController(text: widget.pushoverDevice);

  /// Why the phone field can't be saved (null = it can).
  String? _deviceError;

  /// SEND TEST is waiting for the Pi.
  bool _testing = false;

  @override
  void dispose() {
    _name.dispose();
    _number.dispose();
    _device.dispose();
    super.dispose();
  }

  void _done() {
    final error = pushoverDeviceError(_device.text);
    if (error != null) {
      setState(() => _deviceError = error);
      return;
    }
    Navigator.of(
      context,
    ).pop((name: _name.text.trim(), posNumber: _number.text.trim(), pushoverDevice: _device.text.trim()));
  }

  /// The saved phone is still in the field: SEND TEST tests what is saved.
  bool get _canTest => widget.pushoverDevice.isNotEmpty && _device.text.trim() == widget.pushoverDevice && !_testing;

  /// SEND TEST: the Pi sends a sample route to the saved phone; the answer
  /// shows in the island (even when the dialog was closed meanwhile).
  Future<void> _sendTest() async {
    final island = Island.maybeOf(context);
    setState(() => _testing = true);
    try {
      final r = await widget.onSendTest!();
      island?.show(r.message(widget.name), kind: r.ok ? IslandKind.info : IslandKind.error);
    } catch (e) {
      if (mounted) {
        toastError(context, e, lead: "Couldn't send the test", area: 'drivers');
      } else {
        island?.show(FriendlyError.from(e).short, kind: IslandKind.error);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

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
            style: QuiccType.text(QuiccType.heading),
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 4),
          DriverNumberField(controller: _number, onSubmitted: (_) => _done()),
          const SizedBox(height: 4),
          PushoverDeviceField(
            controller: _device,
            errorText: _deviceError,
            onChanged: (v) => setState(() => _deviceError = pushoverDeviceError(v)),
            onSubmitted: (_) => _done(),
          ),
          if (widget.onSendTest != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('driver-send-test'),
                onPressed: _canTest ? _sendTest : null,
                icon: _testing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_to_mobile_outlined),
                label: const Text('SEND TEST'),
              ),
            ),
          ],
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
