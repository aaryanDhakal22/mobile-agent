import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/features/common/widgets.dart';

// Regression: the dialog's controller used to be disposed as soon as the
// future completed, while the TextField was still animating out — a red
// screen on device ("_dependents.isEmpty") when adding a driver.
void main() {
  for (final button in ['ADD', 'CANCEL']) {
    testWidgets('textDialog closes cleanly via $button', (tester) async {
      String? result = 'unset';
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await textDialog(context, title: 'Add driver', confirm: 'ADD'),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  Sam ');
      await tester.tap(find.text(button));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16)); // through the exit animation
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(result, button == 'ADD' ? 'Sam' : null);
    });
  }
}
