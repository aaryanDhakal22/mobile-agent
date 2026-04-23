import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'features/alert/new_order_alert_screen.dart';
import 'features/home/home_screen.dart';
import 'theme/quicc_theme.dart';

/// Root navigator key — used by the SSE listener at the app root to push the
/// new-order alert without needing a BuildContext from inside the tree.
final rootNavKey = GlobalKey<NavigatorState>();

class MobileAgentApp extends ConsumerWidget {
  const MobileAgentApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the SSE stream at the root so it's always subscribed. Every
    // `order.arrived` event pushes the full-screen alarm on top of whatever
    // route is currently showing.
    ref.listen<AsyncValue<dynamic>>(arrivedEventStreamProvider, (_, next) {
      next.whenData((order) {
        final nav = rootNavKey.currentState;
        if (nav == null) return;
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => NewOrderAlertScreen(order: order),
            fullscreenDialog: true,
          ),
        );
        // New arrival → the `/api/orders/arrived` list is stale. Invalidate so
        // the home pane reflects the queue as soon as the alert is dismissed.
        ref.invalidate(arrivedOrdersProvider);
      });
    });

    return MaterialApp(
      title: 'quiccpos',
      navigatorKey: rootNavKey,
      debugShowCheckedModeBanner: false,
      theme: QuiccTheme.dark(),
      home: const HomeScreen(),
    );
  }
}
