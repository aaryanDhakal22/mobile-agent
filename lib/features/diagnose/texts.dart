// Every sentence the troubleshooting shows, in one place. Written for a store
// manager in the middle of a shift: short, plain, one thing at a time.

import '../../core/format.dart';
import '../common/info_button.dart';

/// A step's title + body.
class StepCopy {
  final String title;
  final String body;
  const StepCopy(this.title, this.body);
}

/// The four guides as the Help tab shows them.
abstract final class GuideText {
  static const piUnreachableName = "Can't reach the Pi";
  static const piUnreachableWhen = 'Use this when the red "Can\'t reach the Pi" bar shows, or nothing updates.';
  static const printerName = 'Printer problem';
  static const printerWhen = "Use this when a printer doesn't print, or tickets say REROUTED.";
  static const noOrdersName = 'No orders coming in';
  static const noOrdersWhen = "Use this when it's busy hours but no online orders arrive.";
  static const piSwapName = 'Swap the Pi card / pair a tablet';
  static const piSwapWhen = 'Use this to put in the spare SD card, set up a new Pi, or pair another tablet.';

  static const helpTitle = 'Help';
  static const helpSubtitle = 'Fix problems step by step';
  static const fullCheck = 'Run a full check';
  static const fullCheckWhen = 'Checks the tablet, the Pi, the printers and the internet in a few seconds.';
  static const sendDiag = 'Send diagnostics to the owner';
  static const sendDiagWhen = "Tells the owner what this tablet and the Pi see. Add a note if you like.";
  static const tabletChecks = 'Tablet checks';
  static const testRing = 'Test ring';
  static const testPrint = 'Test print';
  static const continueGuide = 'Continue';
  static const pairAnother = 'Pair another tablet';

  static const exitTitle = 'Leave this guide?';
  static const exitBody = 'What you did so far is sent to the owner.';
  static const exit = 'EXIT';
  static const stay = 'STAY';

  static const yes = 'YES';
  static const no = 'NO';
  static const next = 'NEXT';
  static const testAgain = 'DONE — TEST AGAIN';
  static const back = 'BACK';
  static const close = 'CLOSE';
  static const fixIt = 'FIX IT';
  static const checking = 'Checking…';
  static const stepOf = 'Step';

  static const worked = 'It worked';
  static const ownerTold = 'The owner has been told';
  static const nothingWrong = 'Everything looks fine';

  static const InfoText guidesInfo = InfoText(
    'How the guides work',
    'Each guide checks what it can by itself, then asks you to do one simple thing at a time — '
        'the quickest fixes first. After each thing, tap DONE — TEST AGAIN. When it works, or when '
        "there's nothing more to try here, the owner gets a report automatically.",
  );
  static const InfoText fullCheckInfo = InfoText(
    'Full check',
    'The tablet checks its Wi-Fi and internet, finds the Pi, asks the Pi about its SD card, power, '
        'printers and connection to the Quicc server. A ✗ with FIX IT opens the guide for it.',
  );
  static const InfoText sendInfo = InfoText(
    'Send diagnostics',
    "Sends what this tablet and the Pi see (no customer details) to the owner. If the internet is "
        "down it's saved and sent as soon as it's back.",
  );
  static const InfoText rerouted = InfoText(
    'What REROUTED means',
    'When a printer is off or not answering, its tickets print on another printer with a big '
        'REROUTED banner at the top. Nothing is lost — take the ticket to the right station.',
  );
  static const InfoText reprint = InfoText(
    'How to reprint',
    'On the Kitchen tab, tap REPRINT on the order. It prints again on every printer it belongs to.',
  );
  static const InfoText sdCard = InfoText(
    'The spare SD card',
    'The Pi keeps everything on a small memory card. The store has a spare one, already set up. '
        'Swapping it takes 2 minutes plus up to 10 minutes for it to start. Orders are kept by the '
        'Quicc server meanwhile.',
  );
  static const InfoText dhcp = InfoText(
    'Why the Pi moved',
    'The router gave the Pi a new address. The tablet found it and now uses the new one. '
        'The owner can ask the router to keep the Pi on one address (a "DHCP reservation").',
  );
}

/// The status board's sentences, one per check result.
abstract final class CheckText {
  static const tabletNetworkOk = 'The tablet is on a network';
  static const tabletNetworkFail = 'The tablet is not on Wi-Fi';
  static const tabletNetworkUnknown = "Can't tell if the tablet is on Wi-Fi";
  static const internetOk = 'The tablet reaches the internet';
  static const internetFail = "The tablet can't reach the internet";
  static const internetUnknown = "Can't tell if the tablet reaches the internet";
  static const mainOk = 'The tablet reaches the Quicc server';
  static const mainFail = "The tablet can't reach the Quicc server";
  static const mainUnknown = 'The Quicc server was not checked from the tablet';
  static String piMoved(String ip) => "The Pi moved to a new address ($ip)";
  static const piFoundSaved = 'The Pi answers at its usual address';
  static const piFoundNew = 'A new, not set up Pi is on the network';
  static const piFoundOther = "A Pi is on the network, but it isn't this store's";
  static const piNotFound = 'No Pi found on this network';
  static const portOpen = 'The Pi is listening';
  static const portRefused = "The Pi is on, but the Quicc program on it isn't running";
  static const portUnreachable = "The Pi doesn't answer at all (off, or its cable is out)";
  static const portUnknown = 'The Pi was not checked';
  static const apiOk = 'The Pi answers';
  static const apiNew = 'The Pi answers, but it is not set up';
  static const apiFail = "The Pi doesn't answer";
  static const needsPi = "Can't check — the Pi doesn't answer";
  static const piMainOk = 'The Pi is connected to the Quicc server';
  static const piMainRejected = 'This Pi was unlinked from the store';
  static const piMainDown = "The Pi can't reach the Quicc server";
  static const piMainUnknown = "Can't tell if the Pi reaches the Quicc server";
  static const piTooOld = 'The Pi needs an update to check this';
  static const healthOk = "The Pi's SD card and power look fine";
  static const healthUnknown = "The Pi's health isn't known";
  static String healthSd(bool lastKnown) =>
      lastKnown ? "Last time, the Pi's SD card was showing errors" : "The Pi's SD card is showing errors";
  static String healthPower(bool lastKnown) =>
      lastKnown ? "Last time, the Pi's power was too weak" : "The Pi's power supply is too weak";
  static const printersUnknown = "Can't tell how the printers are";
  static const printersNone = 'No printers are set up';
  static String printersOk(int n) => n == 1 ? 'The printer answers' : 'All $n printers answer';
  static String printersDown(List<String> names) =>
      names.length == 1 ? '${names.first} printer is not answering' : 'Not answering: ${names.join(', ')}';
  static String ordersQuiet(Duration d) => 'No orders for ${minutes(d)} while open';
  static const ordersOk = 'Orders are coming in';
  static const ordersClosed = 'The store is closed now';
  static const ordersUnknown = "Can't tell if orders are coming in";
}

/// The guides' steps.
abstract final class StepText {
  // (a) Can't reach the Pi
  static const tabletWifi = StepCopy(
    "Turn on the tablet's Wi-Fi",
    "The tablet isn't on any network. Open Wi-Fi settings, join the store Wi-Fi, then come back here.",
  );
  static const useNewAddress = StepCopy(
    'Found the Pi at a new address',
    'The Pi moved to a new address. The tablet is switching to it now.',
  );
  static const guestWifi = StepCopy(
    'Is the tablet on the store Wi-Fi?',
    'The tablet has internet but sees no Pi. It must be on the store Wi-Fi — not the guest Wi-Fi.',
  );
  static const guestWifiFix = StepCopy(
    'Switch to the store Wi-Fi',
    'Open Wi-Fi settings and pick the store Wi-Fi (not guest). Then come back here.',
  );
  static const agentRestartWait = StepCopy(
    'The Pi is restarting Quicc',
    "The Pi is on, but its Quicc program isn't running. It restarts by itself — please wait.",
  );
  static const piPowerLight = StepCopy(
    'Is the red light on the Pi on?',
    'Look at the Pi (the small green board). There is a small red light near the edge.',
  );
  static const piPowerFix = StepCopy(
    'Plug the Pi in',
    'Push the power plug in firmly, at the Pi and at the wall. Still no red light? Try another socket.',
  );
  static const piCable = StepCopy(
    "Check the Pi's network cable",
    'Push the cable in until it clicks — at the Pi and at the router or switch. The lights next to it should be on.',
  );
  static const piPowerCycle = StepCopy(
    'Restart the Pi',
    'Unplug the Pi\'s power, count to 10, plug it back in. It takes up to 3 minutes to start — the tablet keeps checking.',
  );
  static const sdSwap = StepCopy(
    "Let's try the spare SD card",
    "The Pi's memory card may be worn out. The store has a spare one. It takes a few minutes.",
  );

  // Swap steps (shared by the Pi guide and the swap guide)
  static const swapUnplug = StepCopy('Unplug the Pi', "Pull the Pi's power cable out. Leave the network cable in.");
  static const swapCard = StepCopy(
    'Swap the SD card',
    'Pull the small card out of the slot at the end of the Pi. Push the spare card in, the same way round, until it stops.',
  );
  static const swapPlug = StepCopy('Plug the Pi back in', 'Plug the power back in. The red light should come on.');
  static const swapWaitNew = StepCopy(
    'Starting the new card',
    'The first start takes up to 10 minutes. Leave the Pi alone — the tablet will find it.',
  );
  static const swapLogin = StepCopy(
    'Sign in to set up the Pi',
    'Use the store manager login (the one for the Quicc website). Orders come back by themselves.',
  );
  static const swapReady = StepCopy(
    'Getting the Pi ready',
    'Connecting to the Quicc server and the printers. This takes about a minute.',
  );
  static const swapBack = StepCopy(
    'Put the original card back',
    "The spare card didn't start, so the old card was probably fine. Unplug the Pi, put the original card back, plug it in.",
  );

  // (b) Printer — [name] may be empty (a printer the Pi didn't name).
  static String _p(String name) => name.isEmpty ? 'the printer' : 'the $name printer';
  static const pickPrinter = StepCopy('Which printer?', 'Tap the printer that has the problem.');
  static const switchCheck = StepCopy(
    'Check the network switch',
    'No printer answers, so check the small box their cables go into (the switch): is it plugged in, are its lights on?',
  );
  static StepCopy printerPowerLight(String name) =>
      StepCopy("Is ${_p(name)}'s power light on?", 'Look at the front of the printer, near the button.');
  static StepCopy printerPowerFix(String name) => StepCopy(
    'Turn ${_p(name)} on',
    'Press the power switch (side or back) and check its power cable is pushed in at both ends.',
  );
  static StepCopy printerPaper(String name) =>
      StepCopy('Paper loaded and lid shut?', 'Is there paper in ${_p(name)}, and is the lid snapped shut?');
  static StepCopy printerPaperFix(String name) => StepCopy(
    'Load the paper',
    'Open the lid. The paper must come off the BOTTOM of the roll toward you. Snap the lid shut.',
  );
  static StepCopy printerCable(String name) => StepCopy(
    "Check ${_p(name)}'s network cable",
    'Push the cable in until it clicks — at the back of the printer and at the switch or router.',
  );
  static StepCopy printerPowerCycle(String name) =>
      StepCopy('Restart ${_p(name)}', 'Turn it off, count to 10, turn it on. The tablet keeps checking for a minute.');
  static StepCopy testPrint(String name) =>
      StepCopy('Printing a test slip', 'Sending a short test slip to ${_p(name)}…');
  static StepCopy slipCameOut(String name) =>
      StepCopy('Did a slip come out?', 'Look at ${_p(name)}. Did a slip saying "TEST" come out?');
  static StepCopy paperOrientation(String name) => StepCopy(
    'Turn the paper roll around',
    "The printer answers but the slip may be blank or missing: the roll may be in backwards. Paper must come off "
        'the BOTTOM of the roll toward you.',
  );

  // (c) No orders
  static const unlinked = StepCopy(
    'This Pi was unlinked',
    'The Quicc server no longer accepts this Pi. Sign in with the store manager login to set it up again.',
  );
  static const routerLights = StepCopy(
    "Are the router's lights on?",
    'Look at the internet router (the box from your internet company). Are its lights on, and none red?',
  );
  static const routerRestart = StepCopy(
    'Restart the internet router',
    'Unplug the router, count to 30, plug it back in. It takes about 3 minutes — the tablet keeps checking.',
  );

  // (d) Swap / pair
  static const dChoice = StepCopy('What do you need?', 'Pick one.');
  static const dChoiceSwap = 'Put in the spare SD card';
  static const dChoicePair = 'Pair another tablet';
  static const relinkWait = StepCopy(
    'Waiting for the Pi',
    'The Pi is getting ready to be set up again. This takes a minute.',
  );
  static const pairCode = StepCopy(
    'Pair another tablet',
    'On the other tablet: open Quibase, pick this Pi, choose "Pair with a code" and type this code.',
  );
}

/// Conclusions: the headline (≤120 chars) and what staff do meanwhile.
abstract final class ConclusionText {
  static const fixedPrefix = 'Fixed: ';
  static const piReachableNow = 'The tablet reaches the Pi now.';
  static const piStillDown = "The Pi still isn't answering.";
  static const piStillDownMeanwhile =
      "Orders won't ring or print here. Take orders by phone, and keep this tablet on — it reconnects by itself.";
  static const ipChangedNote = 'The Pi got a new address. Consider a DHCP reservation for it on the router.';
  static const swapWorked = 'It worked — the old card was bad. The owner has been told to send a new spare.';
  static const swapWorkedPrinters = 'The spare card works, but a printer is not answering yet. Use the Printer guide.';
  static const swapNeverStarted = "The spare card didn't start. The Pi or its power supply may be broken.";
  static const swapBackMeanwhile = 'With the original card back in, take orders by phone until the owner calls.';
  static const relinked = 'The Pi is set up again.';
  static const meanwhileNone = '';
  static String printerDead(String name, String ip) =>
      "${name.isEmpty ? 'The printer' : name}${ip.isEmpty ? '' : ' at $ip'} isn't answering — its address may have changed.";
  static const printerMeanwhile = "Its tickets print on another printer with a REROUTED banner. Use those.";
  static String printerNoPrint(String name) =>
      "${name.isEmpty ? 'The printer' : name} answers but doesn't print — it may be jammed or broken.";
  static const piTooOld = 'The Pi needs an update before this guide can help.';
  static const printerWorks = 'The printer works.';
  static const noPrinters = 'No printers are set up on this Pi.';
  static const storeInternet = 'The store internet is down.';
  static const storeInternetMeanwhile =
      'Call your internet provider. Take orders by phone meanwhile — online orders wait on the server.';
  static const piNoInternet = "The Pi can't reach the internet.";
  static const piNoInternetMeanwhile = 'Take orders by phone until it is fixed.';
  static const serverDown = 'The Quicc server has a problem — the owner has been told.';
  static const serverDownMeanwhile = 'Take orders by phone until it is back.';
  static const allOk = 'Everything on our side works. Orders may just be slow, or the ordering website has a problem.';
  static const allOkMeanwhile = 'Keep this tablet on. If customers say they ordered and nothing came, call the owner.';
  static const paired = 'Pairing code shown.';
  static const abandoned = 'Guide left before the end.';
}

/// Report sending, as staff see it.
abstract final class ReportText {
  static const sent = 'Sent to the owner';
  static const saved = 'Saved — will send when the internet is back';
  static const sending = 'Sending to the owner…';
  static const notePrompt = 'What happened? (optional)';
  static const noteHint = 'e.g. "Printer beeps and nothing comes out"';
  static const send = 'SEND';
  static const copy = 'COPY DIAGNOSTICS';
  static const sendToOwner = 'SEND DIAGNOSTICS TO THE OWNER';
  static const copied = 'Copied';
}

/// The warning bars on Home.
abstract final class WarningText {
  static String printerDown(String name) => '$name printer is not answering';
  static const printersDown = 'Printers are not answering';
  static const noOrders = 'No online orders for a while';
  static String noOrdersFor(Duration d) => 'No online orders for ${minutes(d)} — probably just quiet';
  static const snooze = 'HIDE 1 HOUR';
  static String alarmQuiet(int pct) => 'Order alarm is quiet ($pct%) — turn it up with the volume buttons';
  static const checksNeedAttention = 'Some tablet settings need attention — orders may not ring';
  static const open = 'OPEN';
  static const InfoText alarmInfo = InfoText(
    'Alarm volume',
    'New orders ring on the tablet\'s ALARM volume. Press the volume-up button and make sure the alarm '
        'slider is at least half way. Quibase never changes it for you.',
  );
  static const InfoText noOrdersInfo = InfoText(
    'No orders for a while',
    'The store is open but no online order came in for longer than usual. Often it is just quiet. '
        'FIX IT checks the internet, the Pi and the Quicc server.',
  );
}

/// Settings → About & diagnostics.
abstract final class AboutText {
  static const title = 'About & diagnostics';
  static const appVersion = 'Quibase version';
  static const piAddress = 'Pi address';
  static const piVersion = 'Pi version';
  static const store = 'Store';
  static const lastSync = 'Last sync';
  static const piHealth = 'Pi health';
  static const unknown = 'unknown';
  static const healthGood = 'Good';
  static const InfoText info = InfoText(
    'About & diagnostics',
    'COPY puts a plain-text summary on the clipboard (to paste in a message). SEND sends the full '
        'report to the owner.',
  );
}
