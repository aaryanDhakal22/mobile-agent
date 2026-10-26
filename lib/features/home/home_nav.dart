import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Every screen the rail can show, across the three rail modes (1.6.0;
/// five each since 1.6.1):
///   kitchen mode: kitchen · deliveries · map · drivers · history
///   store mode:   batch · printers · updates · help · settings
///   dev mode:     connections · pos hub · logs · tests · config
enum HomeDestination {
  kitchen,
  deliveries,
  map,
  drivers,
  history,
  batch,
  printers,
  updates,
  help,
  settings,
  connections,
  posHub,
  logs,
  tests,
  config,
}

/// Which screen is showing. Anything may ask to go somewhere (e.g. the driver
/// button sending you to Deliveries); HomeScreen switches the rail mode to the
/// one that holds the destination. Dev destinations still need the manager
/// login — HomeScreen ignores them while dev mode is locked.
class HomeNavNotifier extends Notifier<HomeDestination> {
  @override
  HomeDestination build() => HomeDestination.kitchen;

  void go(HomeDestination d) => state = d;
}

final homeNavProvider = NotifierProvider<HomeNavNotifier, HomeDestination>(HomeNavNotifier.new);

/// Order ids the Deliveries screen should make glow (e.g. a delivery near the
/// next driver's run, after NEXT redirected there). Cleared when the user acts.
class DeliveryHighlightNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void show(Iterable<String> ids) => state = {...ids};
  void clear() => state = const {};
}

final deliveryHighlightProvider = NotifierProvider<DeliveryHighlightNotifier, Set<String>>(DeliveryHighlightNotifier.new);
