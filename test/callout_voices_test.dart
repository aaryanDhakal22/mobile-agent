// 1.9.2: the order callout's voice lines, guest voices and a long voice
// list with online (ElevenLabs) voices.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/features/settings/callout_cards.dart';

import 'callout_test.dart' show FakePreviewPlayer, container, floorOf, pumpApp;

const _hint = 'This is Narrator and order number <x> is ready';

Map<String, dynamic> _voice(String id, String name, {bool online = false, int ready = 999}) => {
  'id': id,
  'name': name,
  'about': online ? 'ElevenLabs' : 'Kokoro',
  'ready': ready,
  'total': 999,
  if (online) 'online': true,
};

/// `GET /api/callout` of a Pi + hub with voice lines and guest voices (each
/// left out when false: an older Pi / hub).
Map<String, dynamic> calloutJson({
  bool piLines = true,
  bool hubLines = true,
  bool piGuest = true,
  bool hubGuest = true,
  bool preview = false,
  String voice = '',
  Map<String, String> voiceLines = const {},
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
    if (piLines) 'voice_lines': voiceLines,
    if (piGuest) ...{'guest_chance': 0, 'guest_voices': guestVoices},
  },
  'hub_connected': true,
  'preview': ?(preview ? true : null),
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
    'preview': ?(preview ? true : null),
    'lines': ?(hubLines ? true : null),
    'guest': ?(hubGuest ? true : null),
  },
};

void main() {
  group('models', () {
    test('voice lines and guest voices round-trip; an older Pi has neither and never sends them', () {
      final s = CalloutSettings.fromJson({
        'enabled': true,
        'voice_lines': {'kokoro:bf_emma': 'Emma here, order <x>', 'eleven:adam': 'Adam calling {n}', 'bad': 3},
        'guest_chance': 5,
        'guest_voices': 'eleven:rachel, eleven:adam,',
      });
      expect(s.voiceLines, {'kokoro:bf_emma': 'Emma here, order <x>', 'eleven:adam': 'Adam calling {n}'});
      expect(s.guestChance, 5);
      expect(s.guestVoiceIds, ['eleven:rachel', 'eleven:adam']);
      final j = s.toJson();
      expect(j['voice_lines'], {'kokoro:bf_emma': 'Emma here, order <x>', 'eleven:adam': 'Adam calling {n}'});
      expect(j['guest_chance'], 5);
      expect(j['guest_voices'], 'eleven:rachel, eleven:adam,');
      final back = CalloutSettings.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(back, s);
      expect(back.hashCode, s.hashCode);
      expect(s.copyWith(volume: 10).voiceLines, s.voiceLines);
      expect(s == s.copyWith(voiceLines: {'kokoro:bf_emma': 'Emma here, order <x>'}), isFalse);
      expect(s == s.copyWith(guestVoices: ''), isFalse);
      // Set, change, clear one voice's line; the rest stay.
      expect(s.withVoiceLine('kokoro:af_heart', '  Heart says <x> '), {
        'kokoro:bf_emma': 'Emma here, order <x>',
        'eleven:adam': 'Adam calling {n}',
        'kokoro:af_heart': 'Heart says <x>',
      });
      expect(s.withVoiceLine('eleven:adam', ' '), {'kokoro:bf_emma': 'Emma here, order <x>'});
      expect(const CalloutSettings().withVoiceLine('a', 'x'), {'a': 'x'});
      // An empty object: kept and sent.
      final empty = CalloutSettings.fromJson({
        'voice_lines': <String, dynamic>{},
        'guest_chance': 0,
        'guest_voices': '',
      });
      expect(empty.voiceLines, isEmpty);
      expect(empty.toJson()['voice_lines'], isEmpty);
      expect(empty.guestVoiceIds, isEmpty);
      expect(CalloutSettings.fromJson({'guest_chance': 70}).guestChance, 50);
      // An older Pi.
      final old = CalloutSettings.fromJson({'enabled': true, 'volume': 80});
      expect(old.voiceLines, isNull);
      expect(old.guestChance, isNull);
      expect(old.guestVoices, isNull);
      for (final k in ['voice_lines', 'guest_chance', 'guest_voices']) {
        expect(old.toJson().containsKey(k), isFalse, reason: k);
      }
    });

    test('the hub report: lines, guest, online voices', () {
      final hub = CalloutHubReport.fromJson(calloutJson()['hub'])!;
      expect(hub.lines, isTrue);
      expect(hub.guest, isTrue);
      expect(hub.voices.where((v) => v.online).map((v) => v.id), ['eleven:rachel', 'eleven:adam']);
      expect(hub.voices[2].status, 'Online (ElevenLabs) · made on first use');
      expect(hub.voices[3].status, 'Online (ElevenLabs) · made on first use');
      expect(hub.voices[1].status, 'getting ready 312/999');
      expect(hub.voices[0].status, '');
      final old = CalloutHubReport.fromJson(calloutJson(hubLines: false, hubGuest: false)['hub'])!;
      expect(old.lines, isFalse);
      expect(old.guest, isFalse);
      expect(const CalloutVoice(id: 'x').online, isFalse);
    });

    test('a voice line is checked like the Pi: at most 160 letters', () {
      expect(voiceLineProblem(''), isNull);
      expect(voiceLineProblem('a' * 160), isNull);
      expect(voiceLineProblem('  ${'a' * 160}  '), isNull);
      expect(voiceLineProblem('a' * 161), 'Too long: 161 letters (at most 160).');
    });
  });

  group('settings card', () {
    final wav = Uint8List.fromList([...utf8.encode('RIFF'), 0, 0, 0, 0, ...utf8.encode('WAVE'), 1, 2, 3]);

    /// The callout card answering [json]; PUTs echo, previews answer [wav].
    Future<List<http.Request>> card(WidgetTester tester, Map<String, dynamic> json, {FakePreviewPlayer? player}) async {
      final reqs = <http.Request>[];
      final c = await container(
        floorOf(const []),
        previewPlayer: player,
        handler: (req) async {
          reqs.add(req);
          if (req.url.path.startsWith('/api/callout/preview/')) {
            return http.Response.bytes(wav, 200, headers: {'content-type': 'audio/wav'});
          }
          switch (req.url.path) {
            case '/api/callout':
              return http.Response(jsonEncode(json), 200);
            case '/api/settings/callout':
              final body = utf8.encode(req.body);
              return http.Response.bytes(body, 200, headers: {'content-type': 'application/json; charset=utf-8'});
            case '/api/callout/test':
              return http.Response(jsonEncode({'id': 't1', 'hub_connected': true}), 202);
            case '/api/callout/preview':
              return http.Response(jsonEncode({'id': 'p1', 'status': 'pending'}), 202);
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

    String field(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(const ValueKey('callout-line'))).controller!.text;

    for (final (name, json) in [
      ('an older Pi and hub', calloutJson(piLines: false, hubLines: false, piGuest: false, hubGuest: false)),
      ('an older Pi, a new hub', calloutJson(piLines: false, piGuest: false)),
      ('a new Pi, an older hub', calloutJson(hubLines: false, hubGuest: false)),
    ]) {
      testWidgets('no Voice lines or Guest voices card: $name', (tester) async {
        final reqs = await card(tester, json);
        expect(find.byKey(const ValueKey('callout-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('callout-lines-card')), findsNothing);
        expect(find.byKey(const ValueKey('callout-guest-card')), findsNothing);
        await tap(tester, find.byKey(const ValueKey('callout-chime')));
        final put = lastPut(reqs);
        expect(put['chime'], false);
        if (!(json['settings'] as Map).containsKey('voice_lines')) {
          expect(put.keys, isNot(contains('voice_lines')));
          expect(put.keys, isNot(contains('guest_chance')));
          expect(put.keys, isNot(contains('guest_voices')));
        }
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('only lines on the hub: the Voice lines card without Guest voices', (tester) async {
      await card(tester, calloutJson(hubGuest: false));
      expect(find.byKey(const ValueKey('callout-lines-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('callout-guest-card')), findsNothing);
      expect(find.text('None yet — every voice says the normal phrase.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Line: the chosen voice first, checked like the Pi, SAVE sends the merged object', (tester) async {
      final reqs = await card(tester, calloutJson(voiceLines: {'kokoro:bf_emma': 'Emma here, order <x>'}));
      expect(find.byKey(const ValueKey('callout-lines-card')), findsOneWidget);
      expect(find.text(_hint), findsOneWidget);
      expect(find.text('<x> becomes the ticket number. Empty = the normal phrase.'), findsOneWidget);
      // The editor starts on the chosen voice (the hub's default here).
      final picker = tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('callout-line-voice')));
      expect(picker.initialValue, 'kokoro:af_heart');
      expect(field(tester), '');
      FilledButton save() => tester.widget<FilledButton>(find.byKey(const ValueKey('callout-line-save')));
      expect(save().onPressed, isNull, reason: 'nothing changed yet');

      final line = find.byKey(const ValueKey('callout-line'));
      await tester.ensureVisible(line);
      await tester.enterText(line, 'x' * 161);
      await tester.pump();
      expect(find.text('Too long: 161 letters (at most 160).'), findsOneWidget);
      expect(save().onPressed, isNull);

      await tester.enterText(line, 'Heart says order <x> is up ');
      await tester.pump();
      expect(find.textContaining('Too long'), findsNothing);
      expect(find.text('PREVIEW says the saved line — SAVE first.'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('callout-line-save')));
      final put = lastPut(reqs);
      expect(put['voice_lines'], {
        'kokoro:bf_emma': 'Emma here, order <x>',
        'kokoro:af_heart': 'Heart says order <x> is up',
      });
      expect(put['volume'], 90);
      expect(find.text('Line saved: Heart'), findsOneWidget);
      expect(field(tester), 'Heart says order <x> is up');
      expect(save().onPressed, isNull, reason: 'saved');
      expect(find.byKey(const ValueKey('voice-line-row-kokoro:af_heart')), findsOneWidget);
      expect(find.text('Heart — Heart says order <x> is up'), findsOneWidget);

      // Emptied and saved: that voice is left out of the object.
      await tester.enterText(line, '');
      await tester.pump();
      await tap(tester, find.byKey(const ValueKey('callout-line-save')));
      expect(lastPut(reqs)['voice_lines'], {'kokoro:bf_emma': 'Emma here, order <x>'});
      expect(find.text('Line removed: Heart'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the list: tap loads a voice into the editor, ✕ takes its line off and saves', (tester) async {
      final reqs = await card(
        tester,
        calloutJson(voiceLines: {'kokoro:bf_emma': 'Emma here, order <x>', 'eleven:adam': 'Adam calling <x>'}),
      );
      expect(find.text('Emma — Emma here, order <x>'), findsOneWidget);
      expect(find.text('Adam — Adam calling <x>'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('voice-line-row-eleven:adam')));
      expect(field(tester), 'Adam calling <x>');
      final picker = tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('callout-line-voice')));
      expect(picker.initialValue, 'eleven:adam');

      await tap(tester, find.byKey(const ValueKey('voice-line-remove-eleven:adam')));
      final put = lastPut(reqs);
      expect(put['voice_lines'], {'kokoro:bf_emma': 'Emma here, order <x>'});
      expect(find.text('Line removed: Adam'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-line-row-eleven:adam')), findsNothing);
      expect(field(tester), '', reason: "the editor's voice has no line now");
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('PREVIEW ON THIS TABLET says the editor voice', (tester) async {
      final player = FakePreviewPlayer();
      final reqs = await card(
        tester,
        calloutJson(preview: true, voiceLines: {'kokoro:bf_emma': 'Emma here, order <x>'}),
        player: player,
      );
      await tap(tester, find.byKey(const ValueKey('voice-line-row-kokoro:bf_emma')));
      expect(find.text('PREVIEW ON THIS TABLET'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('callout-line-preview')));
      final post = reqs.firstWhere((r) => r.url.path == '/api/callout/preview');
      expect(jsonDecode(post.body), {'number': 102, 'voice': 'kokoro:bf_emma'});
      expect(player.played.single, wav.toList());
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the voice picker marks a voice that has a line', (tester) async {
      await card(tester, calloutJson(voice: 'kokoro:bf_emma', voiceLines: {'kokoro:bf_emma': 'Emma here, order <x>'}));
      expect(find.byKey(const ValueKey('voice-has-line-kokoro:bf_emma')), findsWidgets);
      await tap(tester, find.byKey(const ValueKey('callout-voice')));
      expect(find.byKey(const ValueKey('voice-has-line-kokoro:bf_emma')), findsWidgets);
      expect(find.byKey(const ValueKey('voice-has-line-kokoro:af_heart')), findsNothing);
      expect(find.byKey(const ValueKey('voice-has-line-eleven:rachel')), findsNothing);
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
      await card(tester, calloutJson(voice: 'eleven:rachel', hubLines: false));
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
