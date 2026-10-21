import 'dart:async';
import 'dart:io';

import 'api_client.dart';

/// The four troubleshooting guides (features/diagnose). A [FriendlyError] can
/// point at one so the screen showing it can offer FIX IT.
enum GuideId { piUnreachable, printer, noOrders, piSwap }

/// What staff see for an error: a short sentence, what to do about it, and
/// (behind "Details") the technical text, which also goes to the local log.
class FriendlyError {
  final String title;
  final String whatToDo;
  final String details;
  final GuideId? guide;

  const FriendlyError(this.title, {this.whatToDo = '', this.details = '', this.guide});

  /// One line for a toast.
  String get short => whatToDo.isEmpty ? title : '$title. $whatToDo';

  @override
  String toString() => short;

  static FriendlyError from(Object e) {
    if (e is AgentException) return _fromAgent(e);
    if (e is TimeoutException) {
      return FriendlyError(
        "The Pi didn't answer in time",
        whatToDo: 'Check the Pi is on, then try again',
        details: '$e',
        guide: GuideId.piUnreachable,
      );
    }
    if (e is SocketException || e is HttpException) {
      return FriendlyError(
        "Can't reach the Pi",
        whatToDo: 'Check the tablet is on the store Wi-Fi and the Pi is on',
        details: '$e',
        guide: GuideId.piUnreachable,
      );
    }
    return FriendlyError('Something went wrong', whatToDo: 'Try again', details: '$e');
  }

  static FriendlyError _fromAgent(AgentException e) {
    final details = [
      if (e.statusCode != null) 'HTTP ${e.statusCode}',
      if (e.code != null) e.code!,
      e.message,
      if (e.cause != null) '${e.cause}',
    ].join(' · ');
    FriendlyError f(String title, [String what = '', GuideId? guide]) =>
        FriendlyError(title, whatToDo: what, details: details, guide: guide);

    if (e.isNetwork) {
      return e.isTimeout
          ? f("The Pi didn't answer in time", 'Check the Pi is on, then try again', GuideId.piUnreachable)
          : f("Can't reach the Pi", 'Check the tablet is on the store Wi-Fi and the Pi is on', GuideId.piUnreachable);
    }
    switch (e.code) {
      case 'invalid_credentials':
        return f('Wrong username or password', 'Use the store manager login (the one for the Quicc website)');
      case 'too_many_attempts':
      case 'rate_limited':
        return f('Too many tries', 'Wait a few minutes, then try again');
      case 'link_in_progress':
        return f('The Pi is already being set up', 'Wait a moment');
      case 'already_provisioned':
        return f('This Pi is already set up', 'Pair with a 6-digit code instead');
      case 'needs_internet':
      case 'server_unreachable':
      case 'main_unreachable':
        return f(
          "The Pi can't reach the internet",
          'Check the Pi\'s network cable and the store internet',
          GuideId.noOrders,
        );
      case 'link_failed':
      case 'main_unsupported':
        return f('Setting up the Pi failed', 'Try again in a minute. If it keeps failing, send diagnostics');
      case 'not_linked':
      case 'not_provisioned':
        return f('This Pi is not set up yet', 'Set it up with the manager login', GuideId.piSwap);
      case 'invalid_code':
        return f('That code is wrong or expired', 'Get a new code and type it again');
      case 'name_required':
        return f('Give this tablet a name', 'For example "Counter tablet"');
      case 'credentials_required':
        return f('Type the username and password');
      case 'device_required':
        return f('This tablet is no longer paired', 'Pair it again', GuideId.piSwap);
      case 'nothing_printed':
        return f('Nothing printed', 'Check the printers — the order was not accepted', GuideId.printer);
      case 'receipt_unsupported':
        return f('This Pi needs an update for receipt settings', 'Tell the owner');
      case 'kitchen_unsupported':
        return f('This Pi needs an update to resend to the kitchen', 'Tell the owner');
      case 'not_accepted':
        return f("This order hasn't been accepted yet.");
      case 'nothing_for_kitchen':
        return f('Nothing on this order goes to a kitchen printer.');
      case 'print_failed':
        return f("Printer problem — the kitchen tickets didn't print.", '', GuideId.printer);
      case 'test_in_progress':
        return f('A test print is already running', 'Wait a few seconds');
      case 'already_accepted':
        return f('Someone already accepted this order');
      case 'driver_not_available':
        return f('That driver is out on a run');
      case 'driver_not_found':
      case 'not_found':
        return f('That was already removed', 'The screen will refresh');
      case 'invalid_state':
        return f('That already changed on another tablet', 'The screen will refresh');
      case 'batch_has_leftovers':
        return f('Some orders are not finished yet');
      case 'too_large':
        return f('That was too big to send');
      case 'name_taken':
        return f('There is already a printer with that name', 'Pick another name');
      case 'main_offline':
        return f("The Pi can't reach Quicc right now", 'Check the Pi\'s internet, then try again', GuideId.noOrders);
    }
    if (e.statusCode == 502) return f('Nothing printed', 'Check the printers', GuideId.printer);
    if (e.statusCode == 404) return f('The Pi needs an update for this', 'Tell the owner');
    if (e.statusCode == 409) return f('That already changed on another tablet', 'The screen will refresh');
    if ((e.statusCode ?? 0) >= 500) {
      return f('The Pi had a problem', 'Try again. If it keeps happening, send diagnostics');
    }
    return f('That did not work', 'Try again');
  }
}
