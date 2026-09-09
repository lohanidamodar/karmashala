/// Gap recovery is paged but **complete**.
///
/// The failure these pin is the quiet one. A phone that came back after a long
/// absence asked for everything after its cursor and the host answered with the
/// whole remainder — one frame, past the envelope cap, that no transport could
/// carry. The request timed out, the turns were never re-offered, and what the
/// reader saw was a session that had gone quiet rather than a delivery that had
/// failed.
///
/// So every page is bounded, at both ends, and a page that could not carry
/// everything says `hasNewer`. Recovery is finished when, and only when, that
/// reads false — never when a page happens to come back short.
library;

import 'package:test/test.dart';
import 'package:karmashala_remote/remote.dart';

import './host_session_api_test.dart' show Harness;

void main() {
  List<RemoteTranscriptMessage> conversation(int count, {int from = 0}) => [
    for (var i = from; i < from + count; i++)
      RemoteTranscriptMessage(role: i.isEven ? 'user' : 'agent', text: 'm$i'),
  ];

  RemoteTranscriptPage pageOf(Harness harness) =>
      RemoteTranscriptPage.fromJson(harness.last.payload);

  group('an explicit `after` is a page, not the remainder', () {
    test('a resume from a cursor a long way back is bounded and says so',
        () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(
        kRemoteTranscriptPageMax * 3,
      );

      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1', 'after': 10},
      );

      final page = pageOf(harness);
      expect(page.messages, hasLength(kRemoteTranscriptPageMax));
      expect(page.messages.first.text, 'm10');
      expect(page.omitted, 10);
      // The window's end, not the whole count — a cursor that claimed the
      // count would say the phone held turns nobody had sent it.
      expect(page.cursor, 10 + kRemoteTranscriptPageMax);
      expect(page.hasNewer, isTrue);
    });

    test('the last page reads false, and only the last page', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(20);

      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1', 'after': 5},
      );

      final page = pageOf(harness);
      expect(page.messages, hasLength(15));
      expect(page.cursor, 20);
      expect(page.hasNewer, isFalse);
    });

    test('a tail read of a long conversation is complete as it stands',
        () async {
      // The opening page is the *end* of the transcript, so there is nothing
      // newer by construction. `omitted` says what is behind it; `hasNewer`
      // would be a different claim and a false one.
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(
        kRemoteTranscriptPageMax * 3,
      );

      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1'},
      );

      final page = pageOf(harness);
      expect(page.omitted, kRemoteTranscriptPageMax * 2);
      expect(page.hasNewer, isFalse);
    });
  });

  group('a reconnect after N missed turns yields exactly N, in order, once',
      () {
    /// Walks the pages the way the phone does — from a cursor, until `hasNewer`
    /// reads false — and answers everything it was given, in the order it
    /// arrived.
    Future<List<String>> drain(Harness harness, {required int from}) async {
      final seen = <String>[];
      var cursor = from;
      var guard = 0;
      while (true) {
        expect(guard++, lessThan(50), reason: 'the walk must terminate');
        await harness.request(
          FrameType.transcriptGet,
          payload: {'sessionId': 's1', 'after': cursor},
        );
        final page = pageOf(harness);
        expect(
          page.omitted,
          cursor,
          reason: 'a page opens where it was asked, or it does not join on',
        );
        seen.addAll(page.messages.map((m) => m.text));
        cursor = page.cursor;
        if (!page.hasNewer) return seen;
      }
    }

    test('a gap of one page comes back in one page', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(40);
      await harness.watch('s1');
      harness.fake.transcripts['s1']!.addAll(conversation(7, from: 40));

      final recovered = await drain(harness, from: 40);

      expect(recovered, ['m40', 'm41', 'm42', 'm43', 'm44', 'm45', 'm46']);
    });

    test('a gap far larger than a page comes back whole, and each turn once',
        () async {
      const missed = kRemoteTranscriptPageMax * 4 + 37;
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(10);
      await harness.watch('s1');
      harness.fake.transcripts['s1']!.addAll(conversation(missed, from: 10));

      final recovered = await drain(harness, from: 10);

      expect(recovered, hasLength(missed));
      expect(recovered.toSet(), hasLength(missed), reason: 'once, not twice');
      expect(recovered, [for (var i = 10; i < 10 + missed; i++) 'm$i']);
    });

    test('and the poll sweep does not re-send what the walk already carried',
        () async {
      // The two paths share one cursor on purpose. A resume that advanced only
      // the phone's would have the sweep repeat the whole gap behind it.
      const missed = kRemoteTranscriptPageMax * 2;
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(10);
      await harness.watch('s1');
      harness.fake.transcripts['s1']!.addAll(conversation(missed, from: 10));

      await drain(harness, from: 10);
      harness.sent.clear();
      await harness.api.pollTranscript('s1');

      expect(
        harness.sent.where((f) => f.type == FrameType.transcriptAppended),
        isEmpty,
        reason: 'the walk left nothing owing',
      );
    });
  });

  group('the live delta is a page too', () {
    test('growth past a page is carried a page at a time, saying hasNewer',
        () async {
      // A resumed agent replaying its history grows a transcript by thousands
      // of messages between two polls. Sent whole it built a frame past the
      // envelope cap; and because the cursor moves only on a delivered frame,
      // the very same frame was rebuilt and refused on every poll after it.
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(5);
      await harness.watch('s1');
      harness.sent.clear();
      harness.fake.transcripts['s1']!.addAll(
        conversation(kRemoteTranscriptPageMax + 20, from: 5),
      );

      await harness.api.pollTranscript('s1');

      final first = pageOf(harness);
      expect(first.messages, hasLength(kRemoteTranscriptPageMax));
      expect(first.messages.first.text, 'm5');
      expect(first.cursor, 5 + kRemoteTranscriptPageMax);
      expect(first.hasNewer, isTrue);

      await harness.api.pollTranscript('s1');

      final second = pageOf(harness);
      expect(second.messages, hasLength(20));
      expect(second.messages.first.text, 'm${5 + kRemoteTranscriptPageMax}');
      expect(second.hasNewer, isFalse);
    });

    test('an ordinary delta says nothing newer is waiting', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(5);
      await harness.watch('s1');
      harness.sent.clear();
      harness.fake.transcripts['s1']!.add(
        const RemoteTranscriptMessage(role: 'agent', text: 'brand new'),
      );

      await harness.api.pollTranscript('s1');

      final page = pageOf(harness);
      expect(page.messages.single.text, 'brand new');
      expect(page.hasNewer, isFalse);
    });

    test('a refused page leaves the cursor where it was', () async {
      // The rule the whole scheme rests on: what the phone was told is what it
      // actually received, so a dropped page is re-offered rather than skipped.
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(5);
      await harness.watch('s1');
      harness.fake.transcripts['s1']!.addAll(
        conversation(kRemoteTranscriptPageMax + 20, from: 5),
      );

      harness.delivers = false;
      await harness.api.pollTranscript('s1');
      harness.delivers = true;
      harness.sent.clear();
      await harness.api.pollTranscript('s1');

      expect(pageOf(harness).messages.first.text, 'm5');
    });
  });

  group('payload compatibility, both directions', () {
    test('a host that never heard of hasNewer decodes as false', () {
      // Which is what it meant: it answered with the whole remainder, so there
      // was never anything newer to ask for.
      final page = RemoteTranscriptPage.fromJson(const {
        'sessionId': 's1',
        'messages': <Object?>[],
        'cursor': 4,
      });

      expect(page.hasNewer, isFalse);
    });

    test('a page with nothing newer puts no key on the wire', () {
      // Additive: an old phone decoding a new host sees the shape it knows.
      const page = RemoteTranscriptPage(
        sessionId: 's1',
        messages: [],
        cursor: 4,
      );

      expect(page.toJson().containsKey('hasNewer'), isFalse);
    });

    test('and one with more to come carries it', () {
      const page = RemoteTranscriptPage(
        sessionId: 's1',
        messages: [],
        cursor: 4,
        hasNewer: true,
      );

      expect(page.toJson()['hasNewer'], isTrue);
      expect(RemoteTranscriptPage.fromJson(page.toJson()).hasNewer, isTrue);
    });
  });
}
