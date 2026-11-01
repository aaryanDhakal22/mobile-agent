import '../common/info_button.dart';

// The (i) copy for the Drivers tab and the driver button.

const kClockInfo = InfoText(
  'The Drivers tab',
  'The buttons on the right: UNASSIGNED (deliveries marked delivered with no driver), the drivers '
      'who are clocked in (in queue order — hold one and drag it to change the queue), and the ones '
      'who are clocked out, small and grey. Tap one to see their deliveries this batch.\n\n'
      'Tap a delivery to select it (hold it to open it), then tap a driver to give it to them. '
      'Nothing goes to a clocked-out driver.\n\n'
      'Tap CLOCK IN when a driver starts their shift. They join the back of the queue and can be '
      'sent out with orders.\n\n'
      'Tap CLOCK OUT when they go home. You can only clock out a driver who is here — if they are '
      'out on a run, tap I HAVE RETURNED first. Clocking out prints their driver report on the '
      'receipt printer; a message says when it has printed.\n\n'
      'PRINT REPORT prints one driver\'s report for this batch so far, any time: their deliveries, '
      'the cash they collected, their tips and what they owe the store. When the store uses the POS, '
      'the Pi checks the POS\'s deliveries for that driver too and marks anything only one side had.\n\n'
      'Everyone is clocked out automatically once a day (the time is set on the Pi web page).',
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
