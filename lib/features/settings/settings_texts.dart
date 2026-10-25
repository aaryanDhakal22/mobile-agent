import '../common/info_button.dart';

// The (i) copy for Settings.

const kPiAddressInfo = InfoText(
  'The Pi\'s address',
  'The Pi is the small box by the router that gets the orders and runs the printers. This tablet '
      'talks to it over the store Wi-Fi.\n\n'
      'You only need to change this if the Pi got a new address (for example after the router was '
      'replaced). Type the numbers, like 192.168.1.219 — the tablet checks as you type and says '
      '"Found the Pi" when it answers. Then tap SAVE.\n\n'
      'The tablet stays paired; nothing else changes.',
);

const kConnectionInfo = InfoText(
  'Live, last sync and backlog',
  'Live: the tablet is connected to the Pi and new orders arrive at once. "Retrying" means it '
      'can\'t reach the Pi right now.\n\n'
      'Last sync: when the tablet last got the full order list from the Pi.\n\n'
      'Sync backlog: changes (accepted, ready, delivered…) the Pi has not yet sent to the Quicc '
      'website. It keeps trying by itself; a number that stays high means the store internet is '
      'down.',
);

const kTabletNameInfo = InfoText(
  'This tablet\'s name',
  'The name the Pi knows this tablet by, for example "Counter tablet". It shows in the Pi\'s list '
      'of tablets, so you can tell them apart if there is more than one. RENAME changes it.',
);

const kPairAnotherInfo = InfoText(
  'Pair another tablet',
  'Use this to add a second tablet (or a replacement) to this store.\n\n'
      'Tap PAIR ANOTHER TABLET: a 6-digit code appears for 5 minutes. On the new tablet, open '
      'Quibase, pick this Pi, choose "I have a code" and type the code.\n\n'
      'No password needed — the code is the proof.',
);

const kUnpairInfo = InfoText(
  'Unpair',
  'Disconnects this tablet from the Pi. It stops ringing for orders and goes back to the setup '
      'screen.\n\n'
      'Only do this if the tablet is being replaced or moved to another store. To connect it again '
      'you need a code from another tablet (Pair another tablet) or the manager login.',
);

const kChimeInfo = InfoText(
  'Order chime',
  'The sound a new order makes. It keeps ringing until every new order is accepted, and gets '
      'louder if an order waits more than 2 minutes.\n\n'
      'PREVIEW plays it for 2 seconds. The tablet\'s alarm volume sets how loud it is.',
);

const kChecksInfo = InfoText(
  'Checks & tests',
  'TABLET CHECKS: makes sure Android lets Quibase ring over other apps and with the screen off, '
      'won\'t put it to sleep, and that the alarm volume is up. Run it after an Android update.\n\n'
      'TEST RING: plays the new-order alarm so you can hear it.\n\n'
      'TEST PRINT: prints a short slip on every printer to check they work.',
);

const kThemeInfo = InfoText(
  'Light or dark',
  'Dark is easier on the eyes in a dim kitchen; light is easier to read in bright sun. System '
      'follows the tablet\'s own setting. Tapping the q logo at the top left also switches between '
      'light and dark.',
);

const kReceiptsInfo = InfoText(
  'Receipts',
  'How the Pi prints the kitchen tickets and the customer receipt. A change is used from the '
      'next order on, on every tablet.\n\n'
      'Change what you like, tap SAVE, then PRINT SAMPLE to see it on paper. RESET TO DEFAULTS '
      'puts everything back to how it came.',
);

const kKitchenItemSizeInfo = InfoText(
  'Item text size',
  'How big the food items print on the kitchen tickets. Bigger is easier to read from a '
      'distance but makes the ticket longer.\n\n'
      'Large is the standard.',
);

const kKitchenNumberSizeInfo = InfoText(
  'Ticket number size',
  'How big the kitchen number (like 1104) prints at the top of each kitchen ticket. Make it bigger '
      'if the cooks can\'t read it from where they stand.\n\n'
      'Extra large is the standard.',
);

const kFooterInfo = InfoText(
  'Footer text',
  'A short line printed at the bottom of the customer receipt, for example "THANK YOU".\n\n'
      'Use the store default: prints the line set for the store on the Quicc website (or ONLINE '
      'ORDER if none is set).\n\n'
      'Switch it off to type your own line, up to 32 letters. Leave it empty for no footer at all.',
);

const kFooterSizeInfo = InfoText('Footer size', 'How big the footer line prints. Extra large is the standard.');

const kCopiesInfo = InfoText(
  'Copies',
  'How many customer receipts print for each order. Choose 2 if you staple one to the bag and '
      'keep one. The kitchen tickets always print once.',
);

const kStoreAddressInfo = InfoText(
  'Store name and address',
  'Prints the store\'s name and address at the top of the customer receipt. Switch it off for a '
      'shorter receipt.',
);

const kPhoneInfo = InfoText(
  'Customer phone',
  'Prints the customer\'s phone number on the receipt, so a driver can call them. Switch it off '
      'if you don\'t want phone numbers on paper.',
);

const kExtraPaperInfo = InfoText(
  'Extra paper before cutting',
  'Feeds a little more paper before the printer cuts, so the last line isn\'t cut in half. '
      'Switch it off to save paper.',
);

const kPrintSampleInfo = InfoText(
  'Print sample',
  'Prints a made-up customer receipt and kitchen ticket on the printer you pick, using the saved '
      'settings. Nothing is sent to the kitchen and no order is made.\n\n'
      'If you have changes that are not saved yet, they are saved first.',
);

const kResetReceiptInfo = InfoText(
  'Reset to defaults',
  'Puts every receipt setting back to how it came and saves it. The footer goes back to the '
      'store default.',
);

const kDeliveriesInfo = InfoText(
  'Deliveries',
  'How AUTO on the Deliveries screen plans the runs. Saved on the Pi, so every tablet uses the '
      'same numbers.\n\n'
      'Delivery target: the most minutes from when the customer ordered to the door. AUTO starts '
      'hurrying an order 10 minutes before it, and an order past it goes first, even alone.\n\n'
      'Soon ready: AUTO also plans deliveries still cooking that should be ready within this many '
      'minutes, so a driver can wait for them.',
);

const kFeaturesInfo = InfoText(
  'Features',
  'Switches for the newer parts of Quicc. Each one takes effect at once on the Pi, this tablet and '
      'the store hub (the box that links Quicc to the old POS).\n\n'
      'POS orders pull-in: phone and counter orders keyed on the old POS show up here.\n'
      'Online order insert: online cash pickups are put into the old POS when you accept them, so '
      'they can be paid at the terminal.\n'
      'Driver write-back: the old POS learns which driver took its deliveries.\n'
      'Address heal: a delivery address you fix here is fixed in the old POS too.\n'
      'Future orders: an order for later rings once to pick a lead time, then again when it is time '
      'to cook. Off: it is treated like any other order.\n'
      'Paid wave: paid tickets that aren\'t ready yet get a slow green wave on the Kitchen board.',
);

const kTicketsInfo = InfoText(
  'Kitchen tickets',
  'Which orders print kitchen (station) tickets by themselves.\n\n'
      'POS orders are printed by the old POS when the cashier sends them, so their switches start '
      'off. Turn one on only if the old POS stops printing that kind.\n\n'
      'Online cash pickups print tickets only while the store hub is really putting them into the '
      'old POS; otherwise they print just the receipt, as before.\n\n'
      'Reprint and Resend on a ticket always work.',
);

const kTimesInfo = InfoText(
  'Default times',
  'The time picker you see when you accept an order starts from these: the pickup time for pickup '
      'and counter orders, the delivery time for deliveries. You can pick that time, 5 more, or 10 '
      'more (and step it up from there).\n\n'
      'POS orders use them too: their "ready by" counts from when the cashier sent them.',
);
