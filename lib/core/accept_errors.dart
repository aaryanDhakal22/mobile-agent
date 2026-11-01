import 'api_client.dart';
import 'friendly_error.dart';

/// Shown while a timed-out accept is being read back from the agent.
const String kAcceptChecking = "Couldn't confirm — checking…";

/// Staff-facing message for a failed accept. A transport error / timeout is
/// ambiguous (the agent may have claimed the order before the answer was
/// lost), so it only says we're checking — see [acceptRecheckMessage].
String acceptErrorMessage(Object e) {
  if (e is AgentException) {
    if (e.isPrinterFailure) {
      return 'Printer problem — order NOT accepted. Check the printers and try again.';
    }
    if (e.isNetwork) return kAcceptChecking;
    if (e.isConflict) {
      return switch (e.code) {
        'already_accepted' => 'Already accepted on another screen.',
        'invalid_state' => 'This order was cancelled or closed with its batch — it can\'t be accepted.',
        _ => 'Not accepted. ${FriendlyError.from(e).short}.',
      };
    }
    if (e.isNotFound) return 'This order is no longer on the agent.';
  }
  return 'Not accepted. ${FriendlyError.from(e).short}.';
}

/// Why an ACCEPT that already left the screen (2.0.0) didn't land, shown
/// when the order rings again. A network failure here has already been
/// retried and read back: the Pi didn't get it.
String acceptErrorMessageFor(Object e) {
  if (e is AgentException && e.isNetwork) return "The Pi didn't get it — order NOT accepted. Try again.";
  return acceptErrorMessage(e);
}
