import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/api_client.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/features/arrived/accept_controls.dart';
import 'package:mobile_agent/features/drivers/drivers_pane.dart';

StoredOrder _inState(String state) => StoredOrder.fromJson({
  'order': {'id': 'o1'},
  'status': {'state': state},
});

void main() {
  test('a timeout / transport error is ambiguous: "checking", never "NOT accepted"', () {
    final m = acceptErrorMessage(const AgentException("Agent didn't answer in time"));
    expect(m, kAcceptChecking);
    expect(m, isNot(contains('NOT')));
  });

  test('409 codes are told apart', () {
    expect(
      acceptErrorMessage(const AgentException('x', statusCode: 409, code: 'already_accepted')),
      'Already accepted on another screen.',
    );
    expect(
      acceptErrorMessage(const AgentException('x', statusCode: 409, code: 'invalid_state')),
      contains('cancelled or closed'),
    );
    // Anything else is said in plain words — never the agent's raw text.
    final other = acceptErrorMessage(const AgentException('weird', statusCode: 409, code: 'other'));
    expect(other, startsWith('Not accepted.'));
    expect(other, isNot(contains('weird')));
  });

  test('printer failure and 404 keep their messages', () {
    expect(acceptErrorMessage(const AgentException('x', statusCode: 502)), contains('Printer problem'));
    expect(acceptErrorMessage(const AgentException('x', statusCode: 404)), contains('no longer on the agent'));
  });

  test('after the read-back', () {
    expect(acceptRecheckMessage(_inState('accepted')), isNull, reason: 'it went through');
    expect(acceptRecheckMessage(_inState('ready')), isNull);
    expect(acceptRecheckMessage(_inState('arrived')), contains('NOT accepted'));
    expect(acceptRecheckMessage(_inState('cancelled')), contains('cancelled'));
    expect(acceptRecheckMessage(null), contains("couldn't confirm"));
  });

  test('removing a driver who is out', () {
    expect(removeDriverOutMessage('Sam'), contains("Can't remove a driver who is out on a run"));
  });
}
