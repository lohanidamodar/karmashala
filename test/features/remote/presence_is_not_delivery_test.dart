/// Presence routes notifications. It never decides whether a row reaches the
/// live stream.
///
/// The axis is worth writing down as a test rather than as a sentence, because
/// its failure mode is silent in both directions and only one of them is
/// visible to the person it happens to: a phone told nothing looks like a
/// desktop with nothing to say. The rule cuts the same way whichever signal is
/// carrying it — a link the host believes is dead today, a heartbeat carrying
/// device type, visibility and a focused session tomorrow. So the tests below
/// drive the *strongest* statement the host can currently make about a phone
/// not being there, and assert that every row is still offered to it.
///
/// The polarity to copy is in `push_fanout.dart`: presence SUPPRESSES a push
/// for a phone that can already hear the news. Nothing anywhere may spell it
/// the other way round.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/domain/remote_payloads.dart';
import 'package:karmashala/src/features/remote/protocol.dart';

import 'host_session_api_test.dart' show Harness;

void main() {
  group('the delivery path consults nothing about who is looking', () {
    test('a device the host believes is gone is still offered every row',
        () async {
      // `delivers: false` is the host's own strongest evidence of absence:
      // the link the phone last used is closed and nothing else could carry
      // the frame. It must change what happens to the frame, never whether the
      // frame is built.
      final harness = Harness();
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
      ];
      await harness.watch('s1');
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
        RemoteTranscriptMessage(role: 'agent', text: 'a turn nobody saw'),
      ];

      harness.delivers = false;
      await harness.api.pollTranscript('s1');

      expect(
        harness.dropped.map((f) => f.type),
        contains(FrameType.transcriptAppended),
        reason: 'the row was offered; the link is what refused it',
      );
    });

    test('and it is offered again, because a refusal is not a delivery',
        () async {
      // The whole scheme rests on this: what the phone has been *told* is what
      // it actually received. A presence signal that moved the cursor on a
      // refused frame would lose the turn outright, and the reader would have
      // no way to know a turn had existed.
      final harness = Harness();
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
      ];
      await harness.watch('s1');
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
        RemoteTranscriptMessage(role: 'agent', text: 'a turn nobody saw'),
      ];

      harness.delivers = false;
      await harness.api.pollTranscript('s1');
      harness.delivers = true;
      harness.sent.clear();
      await harness.api.pollTranscript('s1');

      final page = RemoteTranscriptPage.fromJson(
        harness.sent
            .firstWhere((f) => f.type == FrameType.transcriptAppended)
            .payload,
      );
      expect(page.messages.single.text, 'a turn nobody saw');
    });

    test('an approval reaches a phone in a pocket, subscribed or not',
        () async {
      // Deliberately not gated on subscription — the counter-example the api
      // already states in words, pinned here so a presence gate cannot quietly
      // be added beside it.
      final harness = Harness();
      harness.fake.approvals['s1'] = const RemoteApprovalRequest(
        sessionId: 's1',
        evidence: ['Run tests?'],
        waiting: RemoteWaitKind.approval,
      );

      await harness.api.pushApprovalRequested('s1');

      expect(
        harness.sent.map((f) => f.type),
        contains(FrameType.approvalRequested),
      );
    });
  });

  group('what the stream IS gated on, and why it cannot go stale', () {
    test('a session the phone never opened is not polled', () async {
      // The one focus-shaped gate on the live path. It is the phone's own
      // explicit request — `transcript.get`, which it sends for the session it
      // has open — and never an inference about whether the phone is looking.
      // That distinction is the whole rule: a request cannot go stale, and it
      // is cleared only by another explicit request.
      final harness = Harness();
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
      ];
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      harness.sent.clear();

      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
        RemoteTranscriptMessage(role: 'agent', text: 'growth'),
      ];
      await harness.api.pollTranscript('s1');

      expect(
        harness.sent.where((f) => f.type == FrameType.transcriptAppended),
        isEmpty,
        reason: 'subscription keeps a card live; it is not "this is on screen"',
      );
    });

    test('and one turn of asking is enough for ever after', () async {
      // The recovery from the gate above is one frame the phone sends anyway,
      // which is what keeps it from being a way for rows to disappear.
      final harness = Harness();
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
      ];
      await harness.watch('s1');
      harness.sent.clear();

      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
        RemoteTranscriptMessage(role: 'agent', text: 'growth'),
      ];
      await harness.api.pollTranscript('s1');

      expect(
        harness.sent.where((f) => f.type == FrameType.transcriptAppended),
        hasLength(1),
      );
    });
  });
}
