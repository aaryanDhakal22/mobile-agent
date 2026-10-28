// 1.9.2: the order callout's fun lines, guest voices and a long voice list
// with online (ElevenLabs) voices.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/features/settings/callout_cards.dart';

import 'callout_test.dart' show container, floorOf, pumpApp;

const _hint = 'Alright alright alright, order for {n} is ready at the counter.';

Map<String, dynamic> _voice(String id, String name, {bool online = false, int ready = 999}) => {
  'id': id,
  'name': name,
  'about': online ? 'ElevenLabs' : 'Kokoro',
  'ready': ready,
  'total': 999,
  if (online) 'online': true,
};

/// `GET /api/callout` of a Pi + hub with fun lines and guest voices (each
/// left out when false: an older Pi / hub).
Map<String, dynamic> calloutJson({
  bool piFun = true,
  bool hubFun = true,
  bool piGuest = true,
  bool hubGuest = true,
  String voice = '',
  String funLines = '',
  String guestVoices = '',
  List<Map<String, dynamic>>? voices,
}) => {
  'settings': {
    'enabled': true,
    'voice': voice,
    'volume': 90,
    'music_dip': 70,
    'restore_seconds': 1.5,
    'chime': true,
    'repeat': 1,
    if (piFun) ...{'fun_chance': 10, 'fun_lines': funLines},
    if (piGuest) ...{'guest_chance': 0, 'guest_voices': guestVoices},
  },
  'hub_connected': true,
  'hub': {
    'voice': 'kokoro:af_heart',
    'default_voice': 'kokoro:af_heart',
    'installed': true,
    'voices':
        voices ??
        [
          _voice('kokoro:af_heart', 'Heart'),
          _voice('kokoro:bf_emma', 'Emma', ready: 312),
          _voice('eleven:rachel', 'Rachel', online: true, ready: 4),
          _voice('eleven:adam', 'Adam', online: true),
        ],
    'fun': ?(hubFun ? true : null),
    'guest': ?(hubGuest ? true : null),
  },
};

void main() {
  group('models', () {
    test('fun lines and guest voices round-trip; an older Pi has neither and never sends them', () {
      final s = CalloutSettings.fromJson({
        'enabled': true,
        'fun_chance': 25,
        'fun_lines': 'Number {n}, come on down!\nHey hey',
        'guest_chance': 5,
        'guest_voices': 'eleven:rachel, eleven:adam,',
      });
      expect(s.funChance, 25);
      expect(s.funLines, 'Number {n}, come on down!\nHey hey');
      expect(s.guestChance, 5);
      expect(s.guestVoiceIds, ['eleven:rachel', 'eleven:adam']);
      final j = s.toJson();
      expect(j['fun_chance'], 25);
      expect(j['fun_lines'], 'Number {n}, come on down!\nHey hey');
      expect(j['guest_chance'], 5);
      expect(j['guest_voices'], 'eleven:rachel, eleven:adam,');
      expect(CalloutSettings.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>), s);
      expect(s.copyWith(volume: 10).funLines, s.funLines);
      expect(s == s.copyWith(funChance: 30), isFalse);
      expect(s == s.copyWith(guestVoices: ''), isFalse);
      // '' = the built-in lines / every online voice: kept and sent.
      final empty = CalloutSettings.fromJson({'fun_chance': 0, 'fun_lines': '', 'guest_chance': 0, 'guest_voices': ''});
      expect(empty.funLines, '');
      expect(empty.guestVoiceIds, isEmpty);
      expect(empty.toJson()['fun_lines'], '');
      expect(empty.toJson()['guest_voices'], '');
      // Out of range from the wire: clamped.
      expect(CalloutSettings.fromJson({'fun_chance': 140}).funChance, 100);
      expect(CalloutSettings.fromJson({'guest_chance': 70}).guestChance, 50);
      // An older Pi.
      final old = CalloutSettings.fromJson({'enabled': true, 'volume': 80});
      expect(old.funChance, isNull);
      expect(old.funLines, isNull);
      expect(old.guestChance, isNull);
      expect(old.guestVoices, isNull);
      for (final k in ['fun_chance', 'fun_lines', 'guest_chance', 'guest_voices']) {
        expect(old.toJson().containsKey(k), isFalse, reason: k);
      }
    });

    test('the hub report: fun, guest, online voices', () {
      final hub = CalloutHubReport.fromJson(calloutJson()['hub'])!;
      expect(hub.fun, isTrue);
      expect(hub.guest, isTrue);
      expect(hub.voices.where((v) => v.online).map((v) => v.id), ['eleven:rachel', 'eleven:adam']);
      expect(hub.voices[2].status, 'Online (ElevenLabs) · made on first use');
      expect(hub.voices[3].status, 'Online (ElevenLabs) · made on first use');
      expect(hub.voices[1].status, 'getting ready 312/999');
      expect(hub.voices[0].status, '');
      final old = CalloutHubReport.fromJson(calloutJson(hubFun: false, hubGuest: false)['hub'])!;
      expect(old.fun, isFalse);
      expect(old.guest, isFalse);
      expect(const CalloutVoice(id: 'x').online, isFalse);
    });

    test('fun lines are checked like the Pi: at most 10 lines of 120 letters', () {
      expect(funLinesProblem(''), isNull);
      expect(funLinesProblem('Order {n}!\n\n  \nAnother one'), isNull);
      expect(funLinesProblem(List.filled(10, 'line {n}').join('\n')), isNull);
      expect(funLinesProblem(List.filled(11, 'line {n}').join('\n')), 'At most 10 lines (now 11).');
      expect(funLinesProblem('a' * 120), isNull);
      expect(funLinesProblem('ok\n${'a' * 121}'), 'Line 2 is too long (121 letters; at most 120).');
    });
  });

  group('settings card', () {
    /// The callout card answering [json]; PUTs echo, the test answers [test].
    Future<List<http.Request>> card(
      WidgetTester tester,
      Map<String, dynamic> json, {
      http.Response Function()? test,
    }) async {
      final reqs = <http.Request>[];
      final c = await container(
        floorOf(const []),
        handler: (req) async {
          reqs.add(req);
          switch (req.url.path) {
            case '/api/callout':
              return http.Response(jsonEncode(json), 200);
            case '/api/settings/callout':
              final body = utf8.encode(req.body);
              return http.Response.bytes(body, 200, headers: {'content-type': 'application/json; charset=utf-8'});
            case '/api/callout/test':
              return test?.call() ?? http.Response(jsonEncode({'id': 't1', 'hub_connected': true}), 202);
          }
          return http.Response('{}', 404);
        },
      );
      addTearDown(c.dispose);
      await pumpApp(tester, c, home: const Scaffold(body: SingleChildScrollView(child: OrderCalloutCard())));
      await tester.pumpAndSettle();
      return reqs;
    }

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Map<String, dynamic> lastPut(List<http.Request> reqs) =>
        jsonDecode(reqs.lastWhere((r) => r.url.path == '/api/settings/callout' && r.method == 'PUT').body)
            as Map<String, dynamic>;

    for (final (name, json) in [
      ('an older Pi and hub', calloutJson(piFun: false, hubFun: false, piGuest: false, hubGuest: false)),
      ('an older Pi, a new hub', calloutJson(piFun: false, piGuest: false)),
      ('a new Pi, an older hub', calloutJson(hubFun: false, hubGuest: false)),
    ]) {
      testWidgets('no Fun lines or Guest voices card: $name', (tester) async {
        final reqs = await card(tester, json);
        expect(find.byKey(const ValueKey('callout-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('callout-fun-card')), findsNothing);
        expect(find.byKey(const ValueKey('callout-guest-card')), findsNothing);
        await tap(tester, find.byKey(const ValueKey('callout-chime')));
        final put = lastPut(reqs);
        expect(put['chime'], false);
        if (json['settings']['fun_chance'] == null) {
          expect(put.keys, isNot(contains('fun_chance')));
          expect(put.keys, isNot(contains('fun_lines')));
          expect(put.keys, isNot(contains('guest_chance')));
          expect(put.keys, isNot(contains('guest_voices')));
        }
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('only fun on the hub: the Fun lines card without Guest voices', (tester) async {
      await card(tester, calloutJson(hubGuest: false));
      expect(find.byKey(const ValueKey('callout-fun-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('callout-guest-card')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Fun lines: the slider 0–50 in steps of 5, saved like the others', (tester) async {
      final reqs = await card(tester, calloutJson());
      expect(find.byKey(const ValueKey('callout-fun-card')), findsOneWidget);
      final row = find.byKey(const ValueKey('callout-fun-chance'));
      expect(find.descendant(of: row, matching: find.text('10% of callouts')), findsOneWidget);
      final slider = find.descendant(of: row, matching: find.byType(Slider));
      expect(tester.widget<Slider>(slider).min, 0);
      expect(tester.widget<Slider>(slider).max, 50);
      expect(tester.widget<Slider>(slider).divisions, 10);
      await tester.ensureVisible(slider);
      await tester.drag(slider, const Offset(-900, 0));
      await tester.pumpAndSettle();
      expect(lastPut(reqs)['fun_chance'], 0);
      expect(find.descendant(of: row, matching: find.text('Off')), findsOneWidget);
      expect(find.text('Fun lines off'), findsOneWidget);
      await tester.drag(slider, const Offset(900, 0));
      await tester.pumpAndSettle();
      final put = lastPut(reqs);
      expect(put['fun_chance'], 50);
      expect(put['fun_lines'], '');
      expect(put['volume'], 90);
      expect(find.descendant(of: row, matching: find.text('50% of callouts')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Your lines: the hint, checked like the Pi, SAVE sends them', (tester) async {
      final reqs = await card(tester, calloutJson());
      final field = find.byKey(const ValueKey('callout-fun-lines'));
      expect(find.text(_hint), findsOneWidget);
      expect(find.text('One per line. {n} = the ticket number. Empty = the built-in lines.'), findsOneWidget);
      FilledButton save() => tester.widget<FilledButton>(find.byKey(const ValueKey('callout-fun-save')));
      expect(save().onPressed, isNull, reason: 'nothing changed yet');

      await tester.ensureVisible(field);
      await tester.enterText(field, List.filled(11, 'Number {n}!').join('\n'));
      await tester.pump();
      expect(find.text('At most 10 lines (now 11).'), findsOneWidget);
      expect(save().onPressed, isNull);

      await tester.enterText(field, 'Short one\n${'x' * 121}');
      await tester.pump();
      expect(find.text('Line 2 is too long (121 letters; at most 120).'), findsOneWidget);
      expect(save().onPressed, isNull);

      await tester.enterText(field, 'Number {n}, come on down!\nHey hey!\n');
      await tester.pump();
      expect(find.textContaining('At most'), findsNothing);
      expect(save().onPressed, isNotNull);
      await tap(tester, find.byKey(const ValueKey('callout-fun-save')));
      final put = lastPut(reqs);
      expect(put['fun_lines'], 'Number {n}, come on down!\nHey hey!');
      expect(put['fun_chance'], 10);
      expect(find.text('Fun lines saved'), findsOneWidget);
      expect(save().onPressed, isNull, reason: 'saved');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the saved lines fill the field', (tester) async {
      await card(tester, calloutJson(funLines: 'Ticket {n}, you are a star!'));
      expect(find.text('Ticket {n}, you are a star!'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('TRY A FUN LINE: kind fun, #290, on the store speaker', (tester) async {
      final reqs = await card(tester, calloutJson());
      await tap(tester, find.byKey(const ValueKey('callout-fun-try')));
      final t = reqs.lastWhere((r) => r.url.path == '/api/callout/test');
      expect(t.method, 'POST');
      expect(jsonDecode(t.body), {'number': 290, 'voice': '', 'kind': 'fun'});
      expect(find.text('Playing a fun line for #290 on the store speaker…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('TRY A FUN LINE on a Pi that refuses the kind: update the Pi', (tester) async {
      await card(
        tester,
        calloutJson(),
        test: () => http.Response(jsonEncode({'error': 'bad kind', 'code': 'bad_request'}), 400),
      );
      await tap(tester, find.byKey(const ValueKey('callout-fun-try')));
      expect(find.text('Update the Pi for fun lines'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Guest voices: slider 0–50 step 1, the picked voices saved as a comma list', (tester) async {
      final reqs = await card(tester, calloutJson());
      expect(find.byKey(const ValueKey('callout-guest-card')), findsOneWidget);
      expect(
        find.text("Now and then a guest voice calls the order instead. Online voices are made the first time they're used."),
        findsOneWidget,
      );
      final row = find.byKey(const ValueKey('callout-guest-chance'));
      expect(find.descendant(of: row, matching: find.text('Off')), findsOneWidget);
      final slider = find.descendant(of: row, matching: find.byType(Slider));
      expect(tester.widget<Slider>(slider).min, 0);
      expect(tester.widget<Slider>(slider).max, 50);
      expect(tester.widget<Slider>(slider).divisions, 50);
      await tester.ensureVisible(slider);
      await tester.drag(slider, const Offset(900, 0));
      await tester.pumpAndSettle();
      expect(lastPut(reqs)['guest_chance'], 50);
      expect(find.descendant(of: row, matching: find.text('50% of callouts')), findsOneWidget);

      expect(find.text('All online voices'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('callout-guest-eleven:rachel')));
      expect(lastPut(reqs)['guest_voices'], 'eleven:rachel');
      await tap(tester, find.byKey(const ValueKey('callout-guest-kokoro:bf_emma')));
      expect(lastPut(reqs)['guest_voices'], 'eleven:rachel,kokoro:bf_emma');
      expect(find.text('2 picked'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('callout-guest-eleven:rachel')));
      expect(lastPut(reqs)['guest_voices'], 'kokoro:bf_emma');
      await tap(tester, find.byKey(const ValueKey('callout-guest-all')));
      expect(lastPut(reqs)['guest_voices'], '');
      expect(find.text('All online voices'), findsOneWidget);
      expect(find.byKey(const ValueKey('callout-guest-all')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Guest voices: at most 10 picked', (tester) async {
      final voices = [for (var i = 0; i < 12; i++) _voice('eleven:v$i', 'Voice $i', online: true)];
      await card(
        tester,
        calloutJson(voices: voices, guestVoices: [for (var i = 0; i < 10; i++) 'eleven:v$i'].join(',')),
      );
      expect(find.text('10 picked — at most 10'), findsOneWidget);
      FilterChip chip(int i) => tester.widget<FilterChip>(find.byKey(ValueKey('callout-guest-eleven:v$i')));
      expect(chip(0).selected, isTrue);
      expect(chip(0).onSelected, isNotNull, reason: 'a picked one can be taken off');
      expect(chip(11).selected, isFalse);
      expect(chip(11).onSelected, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an online voice: "made on first use" instead of a count', (tester) async {
      await card(tester, calloutJson(voice: 'eleven:rachel'));
      expect(find.byKey(const ValueKey('voice-status-eleven:rachel')), findsOneWidget);
      expect(find.text('  · Online (ElevenLabs) · made on first use'), findsOneWidget);
      expect(find.textContaining('4/999'), findsNothing);
      expect(find.byKey(const ValueKey('callout-voice-online')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('~30 voices: the picker scrolls to the last one and picks it', (tester) async {
      final voices = [
        for (var i = 0; i < 20; i++) _voice('kokoro:v$i', 'Kokoro $i'),
        for (var i = 0; i < 4; i++) _voice('piper:v$i', 'Piper $i'),
        for (var i = 0; i < 6; i++) _voice('eleven:v$i', 'Eleven $i', online: true, ready: i),
      ];
      final reqs = await card(tester, calloutJson(voices: voices, voice: 'kokoro:v0'));
      await tap(tester, find.byKey(const ValueKey('callout-voice')));
      final menu = find.byType(Scrollable).last;
      final last = find.text('Eleven 5 — ElevenLabs');
      expect(last, findsNothing, reason: 'the menu builds only what it shows');
      await tester.scrollUntilVisible(last, 200, scrollable: menu);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-status-eleven:v5')), findsWidgets);
      await tester.tap(last.last);
      await tester.pumpAndSettle();
      expect(lastPut(reqs)['voice'], 'eleven:v5');
      expect(find.text('Voice: Eleven 5'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
