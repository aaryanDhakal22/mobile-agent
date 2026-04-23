import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/features/order_detail/order_detail_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

StoredOrder _sampleOrder() => StoredOrder(
      order: const OrderRequest(
        orderId: 1042,
        orderNumber: 1042,
        storeName: "Lombardi's",
        serviceType: 'Takeout',
        orderTotal: 45.03,
        balanceOwing: 0,
        notes: '',
        customer: Customer(
          firstName: 'John',
          lastName: 'Doe',
          phone: '+1 555-1234',
          email: '',
        ),
        deliveryAddress: null,
        payments: [],
        items: [
          Item(
            name: 'Pepperoni',
            sizeName: 'Large',
            quantity: 2,
            price: 16,
            notes: 'extra cheese',
            modifiers: [],
          ),
        ],
        taxes: [Tax(name: 'HST', amount: 3.53)],
        tip: 0,
      ),
      status: OrderStatus(state: 'arrived'),
    );

void main() {
  testWidgets('Order detail renders customer, items and confirm button', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: OrderDetailScreen(order: _sampleOrder()),
        ),
      ),
    );

    expect(find.text('Ticket #1042'), findsOneWidget);
    expect(find.text('John Doe'), findsOneWidget);
    expect(find.textContaining('Pepperoni'), findsOneWidget);
    expect(find.text('CONFIRM & PRINT'), findsOneWidget);
    expect(find.text('REPRINT'), findsOneWidget);
  });

  testWidgets('Accepted order hides confirm button and shows ACCEPTED label', (tester) async {
    final accepted = StoredOrder(
      order: _sampleOrder().order,
      status: OrderStatus(state: 'accepted', printedDate: DateTime(2026, 4, 23)),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: OrderDetailScreen(order: accepted, confirmable: false),
        ),
      ),
    );

    expect(find.text('CONFIRM & PRINT'), findsNothing);
    // "ACCEPTED" appears twice: the state chip in the app bar and the label
    // in the right-side action panel where the CTA would otherwise live.
    expect(find.text('ACCEPTED'), findsNWidgets(2));
  });
}
