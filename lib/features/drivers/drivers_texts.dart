import '../common/info_button.dart';

// The (i) copy for the Drivers tab and the driver button.

const kClockInfo = InfoText(
  'Clock in / clock out',
  'Tap CLOCK IN when a driver starts their shift. They join the back of the queue and can be '
      'sent out with orders.\n\n'
      'Tap CLOCK OUT when they go home. You can only clock out a driver who is here — if they are '
      'out on a run, tap I HAVE RETURNED first.\n\n'
      'Everyone is clocked out automatically once a day (the time is shown on this screen).',
);

const kQueueInfo = InfoText(
  'The queue',
  'The number next to a driver is their place in the queue. Number 1 is NEXT: they get the next '
      'delivery.\n\n'
      'A driver who comes back from a run goes to the back of the queue.\n\n'
      'To change the order by hand, hold the ≡ handle and drag the driver up or down.',
);

const kRemoveDriverInfo = InfoText(
  'Remove a driver',
  'The bin icon takes a driver off the list for good — use it when someone stops working here, '
      'not at the end of a shift (use CLOCK OUT for that).\n\n'
      'Past orders and shift records keep their name. A driver who is out on a run can\'t be '
      'removed until they are back.',
);

const kDriverButtonInfo = InfoText(
  'The driver button',
  'This is the drivers\' corner. The badge shows how many drivers are out on a run.\n\n'
      'NEXT is the driver at the front of the queue, with the tickets in their box. SEND OUT sends them '
      'out with all of them (it asks first if something is still cooking).\n\n'
      'When something needs planning first — their box is empty, or more than one delivery is waiting — '
      'the button opens Deliveries instead. When nobody can go, it opens Drivers.\n\n'
      'Tap a driver who is out = they\'re back. Their orders are marked delivered and they go to the '
      'back of the queue.\n\n'
      'Hold the round button for 2 seconds = undo the last return (up to 10 minutes after it). '
      'The driver is out again; their orders stay delivered.\n\n'
      'Tap anywhere else to close.',
);
