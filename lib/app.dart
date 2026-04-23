import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'features/alert/new_order_alert_screen.dart';
import 'features/drivers/driver_announcer.dart';
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
        // Optimistically prepend to the arrived queue so the list is already
        // up-to-date the moment the cashier dismisses the alert — no fetch
        // latency visible.
        ref.read(arrivedOrdersProvider.notifier).prepend(order);
      });
    });

    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'quiccpos',
      navigatorKey: rootNavKey,
      debugShowCheckedModeBanner: false,
      theme: QuiccTheme.light(),
      darkTheme: QuiccTheme.dark(),
      themeMode: themeMode,
      home: const HomeScreen(),
      // Driver-name blink rides above every route at the MaterialApp level so
      // it covers both the Home pane and any pushed route (order detail etc).
      builder: (context, child) => Stack(
        children: [
          child ?? const SizedBox.shrink(),
          const Positioned.fill(child: DriverAnnouncer()),
        ],
      ),
    );
  }
}
