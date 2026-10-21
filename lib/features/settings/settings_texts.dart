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
