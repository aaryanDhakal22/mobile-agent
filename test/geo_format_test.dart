// 1.9.0: delivery tickets on Kitchen show the street. streetOnly mirrors the
// agent's TestStreetOnly (agent/internal/domain/order/round_test.go) — keep
// the two tables in step.
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/features/maps/geo_format.dart';

void main() {
  test('streetOnly: the agent\'s StreetOnly table', () {
    const table = {
      '12 Main St': '12 Main St',
      '12 Main St, Apt 3': '12 Main St',
      '931 Taylor Ave Apt 2B': '931 Taylor Ave',
      '931 Taylor Ave #4': '931 Taylor Ave',
      '40 York Rd Suite 100': '40 York Rd',
      '  7 Unit Rd  ': '7 Unit Rd',
      '1 Charles St Fl 3, rear': '1 Charles St',
      '': '',
    };
    table.forEach((input, want) => expect(streetOnly(input), want, reason: input));
  });

  test('ticketStreet: house number + the first one or two street words, suffix shortened', () {
    const table = <String, String?>{
      '4108 Old Court Rd': '4108 Old Court',
      '12 Main Street': '12 Main St',
      '12 Main St, Apt 3': '12 Main St',
      '931 Taylor Ave Apt 2B': '931 Taylor Ave',
      '931 Taylor Avenue, Towson MD 21286': '931 Taylor Ave',
      '531 Stevenson Ln': '531 Stevenson Ln',
      '40 York Rd Suite 100': '40 York Rd',
      '7 Unit Rd': '7 Unit Rd',
      '12 Broadway': '12 Broadway',
      '1 North Charles Street': '1 N Charles',
      '500 West St': '500 West St',
      '12 Court St': '12 Court St',
      '18b Elm Dr.': '18B Elm Dr',
      // POS capitals.
      '931 TAYLOR AVE': '931 Taylor Ave',
      '4108 OLD COURT RD APT 2': '4108 Old Court',
      '200 W 1ST ST': '200 W 1st',
      '77 MCCORMICK RD': '77 Mccormick Rd',
      '77 McCormick Rd': '77 McCormick Rd',
      // No house number: the ticket shows the name.
      'Towson University': null,
      'Taylor Ave': null,
      '931': null,
      '': null,
    };
    table.forEach((input, want) => expect(ticketStreet(Address(line1: input)), want, reason: input));
    expect(ticketStreet(null), isNull);
    expect(ticketStreet(const Address()), isNull);
  });
}
