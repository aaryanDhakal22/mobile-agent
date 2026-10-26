import '../common/info_button.dart';

// The plain-words copy for developer mode: one explanation line under every
// tile, and the longer (i) text behind it.

abstract final class DevText {
  static const lockedNote = 'Developer mode locks again after 15 minutes without a touch.';

  // Connections
  static const connectionsTitle = 'Connections';
  static const connectionsSubtitle = 'Is everything talking to everything?';
  static const liveLink = 'Live link';
  static const liveLinkLine = 'The open line from the Pi that brings new orders the moment they come in.';
  static const printers = 'Printers';
  static const printersLine = 'What the Pi sees on the network right now. Printers are set up on the Quicc website.';
  static const pos = 'POS link';
  static const posLine = 'The store hub that connects Quicc to the old POS (SoftTouch).';
  static const versions = 'Versions';
  static const versionsLine = 'What is installed on this tablet and on the Pi.';

  // Logs
  static const logsTitle = 'Logs';
  static const logsSubtitle = 'What this tablet saw, newest first';
  static const logsLine =
      'Every connect and drop of the live link, order changes (numbers only, never names), and failed '
      'refreshes. Kept until the app restarts.';
  static const errorsTitle = 'Errors staff saw';
  static const errorsLine = 'Kept on the tablet across restarts, and sent with every diagnostics report.';
  static const piLogsSoon = 'The Pi\'s own log comes with the next Pi update.';

  // Tests
  static const testsTitle = 'Tests';
  static const testsSubtitle = 'Check the tablet, the Pi and the printers';
  static const fullCheckLine = 'Checks the Wi-Fi, the Pi, its internet, the printers and this tablet in one go.';
  static const tabletChecksLine =
      'Makes sure Android lets Quibase ring over other apps and with the screen off, and that the '
      'alarm volume is up. Run it after an Android update.';
  static const testRingLine = 'Plays the new-order alarm so you can hear it, also with the screen off.';
  static const testPrintLine = 'Prints a short TEST slip on every printer, without switching to a backup printer.';
  static const sendLine = 'Sends the owner a report of this tablet and the Pi, with the recent errors.';

  // Config
  static const configTitle = 'Config';
  static const configSubtitle = 'Features, pairing and versions';

  // POS hub
  static const posHubTitle = 'POS hub';
  static const posHubSubtitle = 'The link to the old POS (SoftTouch)';
  static const update = 'Quibase updates';
  static const updateLine =
      'New versions come from the Pi. The tablet checks every 10 minutes and installs them by itself '
      'after close.';
}

const kLiveLinkInfo = InfoText(
  'Live link',
  'The Pi keeps a line open to this tablet and sends every change down it at once: new orders, '
      'accepted, ready, drivers out.\n\n'
      'Live: working. Syncing: connecting again (it retries by itself, waiting a little longer each '
      'time, up to 30 seconds). Offline: the Pi does not answer.\n\n'
      'Even with the line down the tablet asks the Pi for everything every 20 seconds.',
);

const kPrintersLiveInfo = InfoText(
  'Printers',
  'Each printer the store has, and whether the Pi can reach it right now. A printer that is down '
      'shows the last error the Pi got.\n\n'
      'To add or rename printers use the Quicc website (main). The printer guide in Help walks '
      'through the usual fixes.',
);

const kPosLinkInfo = InfoText(
  'POS link',
  'The store hub is a small program on a store computer that links Quicc to the old POS. It pulls '
      'the cashier\'s orders onto the Kitchen board, tells the POS which driver took a delivery and '
      'can put online orders into the POS.\n\n'
      'Insert mode: off = online orders are not put into the POS; shadow = it only pretends, to test; '
      'live = it really does.',
);

const kVersionsInfo = InfoText(
  'Versions',
  'Quibase is this app. The Pi runs its own program (the agent). When something goes wrong the '
      'owner may ask for these numbers.',
);

const kLogsInfo = InfoText(
  'Logs',
  'A running list of what this tablet saw, to help the owner find out what happened.\n\n'
      'Live link lines: when the tablet connected to the Pi or lost it. Order lines: an order\'s '
      'number and its new state, never the customer. Errors: things that failed, in short.\n\n'
      'The list lives in memory only, so it starts empty when the app restarts. CLEAR empties it.',
);

const kTestsInfo = InfoText(
  'Tests',
  'Safe to run at any time; nothing here changes an order.\n\n'
      'The full check and the tablet checks say what is wrong in plain words and offer FIX IT. '
      'Test print uses a little paper on each printer.',
);

const kUpdateInfo = InfoText(
  'Quibase updates',
  'The owner sends new versions of Quibase to the Pi. The tablet downloads them by itself and '
      'installs them right after Close batch, when nothing is ringing or cooking — no lock, and an '
      'order can always be accepted.\n\n'
      'INSTALL NOW installs a downloaded version straight away; CHECK NOW asks the Pi what it has.',
);
