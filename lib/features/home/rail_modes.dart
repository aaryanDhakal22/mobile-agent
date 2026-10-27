import 'package:flutter/material.dart';

import 'home_nav.dart';

/// The rail's three modes (1.6.0), five destinations each (1.6.1). The `q`
/// switches between kitchen and store; a long press opens developer mode
/// behind the developer PIN.
enum RailMode { kitchen, store, dev }

/// What a rail destination looks like.
@immutable
class DestinationLook {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const DestinationLook(this.icon, this.selectedIcon, this.label);
}

/// Each mode's destinations, top to bottom.
const Map<RailMode, List<HomeDestination>> kRailDestinations = {
  RailMode.kitchen: [
    HomeDestination.kitchen,
    HomeDestination.deliveries,
    HomeDestination.map,
    HomeDestination.drivers,
    HomeDestination.history,
  ],
  RailMode.store: [
    HomeDestination.batch,
    HomeDestination.printers,
    HomeDestination.updates,
    HomeDestination.help,
    HomeDestination.settings,
  ],
  RailMode.dev: [
    HomeDestination.connections,
    HomeDestination.posHub,
    HomeDestination.logs,
    HomeDestination.tests,
    HomeDestination.config,
  ],
};

/// The mode that holds [d].
RailMode railModeOf(HomeDestination d) => kRailDestinations.entries.firstWhere((e) => e.value.contains(d)).key;

DestinationLook lookOf(HomeDestination d) => switch (d) {
  HomeDestination.kitchen => const DestinationLook(Icons.soup_kitchen_outlined, Icons.soup_kitchen, 'Kitchen'),
  HomeDestination.deliveries => const DestinationLook(
    Icons.delivery_dining_outlined,
    Icons.delivery_dining,
    'Deliveries',
  ),
  HomeDestination.map => const DestinationLook(Icons.map_outlined, Icons.map, 'Map'),
  HomeDestination.drivers => const DestinationLook(Icons.groups_outlined, Icons.groups, 'Drivers'),
  HomeDestination.history => const DestinationLook(Icons.receipt_long_outlined, Icons.receipt_long, 'History'),
  HomeDestination.batch => const DestinationLook(Icons.layers_outlined, Icons.layers, 'Batch'),
  HomeDestination.printers => const DestinationLook(Icons.print_outlined, Icons.print, 'Printers'),
  HomeDestination.updates => const DestinationLook(Icons.system_update_outlined, Icons.system_update, 'Updates'),
  HomeDestination.help => const DestinationLook(Icons.help_outline, Icons.help, 'Help'),
  HomeDestination.settings => const DestinationLook(Icons.settings_outlined, Icons.settings, 'Settings'),
  HomeDestination.connections => const DestinationLook(Icons.lan_outlined, Icons.lan, 'Connections'),
  HomeDestination.posHub => const DestinationLook(Icons.point_of_sale_outlined, Icons.point_of_sale, 'POS hub'),
  HomeDestination.logs => const DestinationLook(Icons.receipt_outlined, Icons.receipt, 'Logs'),
  HomeDestination.tests => const DestinationLook(Icons.science_outlined, Icons.science, 'Tests'),
  HomeDestination.config => const DestinationLook(Icons.tune_outlined, Icons.tune, 'Config'),
};
