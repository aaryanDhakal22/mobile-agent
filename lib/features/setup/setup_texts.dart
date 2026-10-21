import '../common/info_button.dart';

// Every word the setup wizard shows, in one place. Written for the store
// manager: short, plain, no technical terms.

class SetupInfo {
  const SetupInfo._();

  static const welcome = InfoText(
    'Why set up the tablet?',
    'The tablet rings for every new order and is where staff accept, finish and send out orders. '
        'Setup connects it to the store\'s Pi (the small box that talks to the printers) and checks '
        'that it can ring and print.',
  );

  static const findPi = InfoText(
    'What is the Pi?',
    'The Pi is the small box near the router with a network cable and a power cable. '
        'It receives the online orders and prints the tickets. The tablet must be on the same '
        'Wi-Fi as the Pi to find it.',
  );

  static const typedAddress = InfoText(
    'The Pi\'s address',
    'Every device on the store network has an address like 192.168.0.40. It is printed on the '
        'label on the Pi, or ask the owner. You only need the numbers — the tablet adds the rest.',
  );

  static const managerLogin = InfoText(
    'Which login?',
    'Use the store manager login — the same username and password you use on the Quicc website. '
        'It connects this Pi to your store and brings back today\'s orders and drivers.',
  );

  static const pairingCode = InfoText(
    'Where do I get a code?',
    'On a tablet that already works: Settings → Pair another tablet. The code is 6 digits and '
        'works for 5 minutes. It lets this tablet join the same Pi.',
  );

  static const tabletName = InfoText(
    'Tablet name',
    'A name so you can tell tablets apart, like "Counter tablet" or "Kitchen tablet".',
  );

  static const checks = InfoText(
    'Why these checks?',
    'Android tries to save battery by silencing and closing apps. These settings make sure a new '
        'order always rings — even when the screen is off or someone opened another app.',
  );

  static const notifications = InfoText(
    'Notifications',
    'Quibase shows a small "Listening for new orders" note at the top, and wakes the screen for '
        'a new order. Without notifications it can only ring while it is open on screen.',
  );

  static const fullScreen = InfoText(
    'Full-screen alerts',
    'Lets a new order turn the screen on and show over the lock screen, like an incoming call.',
  );

  static const battery = InfoText(
    'Battery saving',
    'Android may put Quibase to sleep to save battery, and then orders stop ringing. '
        'Turning battery saving off for Quibase keeps it awake.',
  );

  static const installs = InfoText(
    'App updates',
    'Quibase updates itself when the owner releases a new version. Android asks once for '
        'permission to install updates — doing it now means an update never stops the counter '
        'in the middle of a shift.',
  );

  static const volume = InfoText(
    'Order alarm volume',
    'New orders ring on the alarm volume, not the media volume. Keep it at least half way up. '
        'Use the tablet\'s volume buttons, or open sound settings.',
  );

  static const piReady = InfoText(
    'Pi ready',
    'The Pi checks its internet, its connection to Quicc, its memory card and power, and finds '
        'each printer. Printers can take up to 30 seconds to show up.',
  );

  static const testRing = InfoText(
    'Test ring',
    'Plays the order chime so you can check the volume. "Test with the screen off" also checks '
        'that a new order wakes the tablet.',
  );

  static const testPrint = InfoText(
    'Test print',
    'Prints a short "TEST" slip on every printer. A slip for one printer never comes out of '
        'another, so you know exactly which printers work.',
  );

  static const drivers = InfoText(
    'Drivers',
    'Add the drivers who work tonight. Clocked-in drivers are offered when you send a delivery '
        'out. You can change this any time on the Drivers screen.',
  );

  static const chime = InfoText(
    'Order chime',
    'The sound a new order makes. It keeps ringing until every new order is accepted.',
  );
}
