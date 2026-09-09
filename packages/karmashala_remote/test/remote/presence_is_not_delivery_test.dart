/// Presence routes notifications. It never decides whether a row reaches the
/// live stream.
///
/// The axis is worth writing down as a test rather than as a sentence, because
/// its failure mode is silent in both directions and only one of them is
/// visible to the person it happens to: a phone told nothing looks like a
/// desktop with nothing to say. The rule cuts the same way whichever signal is
/// carrying it — a link the host believes is dead, and now a heartbeat
/// carrying device kind, visibility and a focused session. So the tests below
/// drive the *strongest* statement the host can currently make about a phone
/// not being there, and assert that every row is still offered to it.
///
/// The polarity to copy is in `push_fanout.dart`: presence SUPPRESSES a push
/// for a phone that can already hear the news. Nothing anywhere may spell it
/// the other way round.
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/push.dart';

import './host_session_api_test.dart' show Harness;

const _deviceId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

PairedDevice _phone(CompanionPresence presence) => PairedDevice(
  id: _deviceId,
  name: 'OPPO',
  deviceKey: Uint8List.fromList(List.generate(32, (i) => i)),
  capabilities: CapabilitySet.all,
  generation: 1,
  createdAt: DateTime.utc(2026, 9, 9),
  pushToken: 'fcm-token-1',
  pushPlatform: 'android',
  presence: presence,
);

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

  group('a backgrounded phone gets both', () {
    /// The frame the phone sends to say it is connected but out of sight.
    Future<void> register(Harness harness, String visibility) => harness.request(
      FrameType.notificationsRegister,
      payload: {
        'token': 't0k',
        'platform': 'android',
        'deviceKind': 'phone',
        'visibility': visibility,
      },
    );

    test('the stream still carries every row while it says it is hidden',
        () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
      ];
      await register(harness, 'background');
      await harness.watch('s1');
      harness.sent.clear();

      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
        RemoteTranscriptMessage(role: 'agent', text: 'a turn it cannot see'),
      ];
      await harness.api.pollTranscript('s1');

      final appended = harness.sent
          .where((f) => f.type == FrameType.transcriptAppended)
          .toList();
      expect(
        appended,
        hasLength(1),
        reason: 'presence reached the api through nothing; it has no such value',
      );
      final page = RemoteTranscriptPage.fromJson(appended.single.payload);
      expect(page.messages.single.text, 'a turn it cannot see');
    });

    /// The push half, over the fan-out the routing actually lives in.
    Future<List<String>> pushesFor(
      CompanionPresence presence, {
      required bool live,
    }) async {
      final paths = <String>[];
      final fanout = PushFanout(
        devices: () => [_phone(presence)],
        hasLiveLink: (_) => live,
        clientFor: (_) => RelayPushClient(
          relay: Uri.parse('wss://relay.example.com'),
          post: (url, jsonBody) async {
            paths.add(url.path);
            return url.path.endsWith('/register')
                ? (status: 204, body: '')
                : (status: 202, body: 'accepted\n');
          },
        ),
        now: () => DateTime.utc(2026, 9, 9, 12),
      );
      await fanout.notifyAttention(
        sessionId: 's1',
        title: 'Fix the tests',
        kind: 'needs_approval',
      );
      return paths;
    }

    test('and the push it used to be denied now leaves for the relay',
        () async {
      expect(
        await pushesFor(
          const CompanionPresence(
            deviceKind: CompanionDeviceKind.phone,
            visibility: CompanionVisibility.background,
          ),
          live: true,
        ),
        ['/v1/push/register', '/v1/push'],
      );
    });

    test('a phone looking at the very session is still not pushed at',
        () async {
      expect(
        await pushesFor(
          const CompanionPresence(
            visibility: CompanionVisibility.foreground,
            focusedSessionId: 's1',
          ),
          live: true,
        ),
        isEmpty,
      );
    });

    test('a phone looking at another session is', () async {
      expect(
        await pushesFor(
          const CompanionPresence(
            visibility: CompanionVisibility.foreground,
            focusedSessionId: 's2',
          ),
          live: true,
        ),
        ['/v1/push/register', '/v1/push'],
      );
    });

    test('a phone that says nothing behaves exactly as it did before',
        () async {
      // The compatibility half: an old companion sends no presence at all, and
      // a live link suppresses its push the way it always has.
      expect(await pushesFor(CompanionPresence.unknown, live: true), isEmpty);
      expect(
        await pushesFor(CompanionPresence.unknown, live: false),
        ['/v1/push/register', '/v1/push'],
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
