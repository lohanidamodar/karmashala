/// The host session api, driven directly: the capability matrix, the refusal
/// codes, and the event dedupe — no sockets, no sealing, just envelopes in
/// and frames out.
library;

import 'dart:async';
import 'dart:convert';

import 'package:karmashala/src/features/remote/application/host_bindings.dart';
import 'package:karmashala/src/features/remote/application/host_session_api.dart';
import 'package:karmashala/src/features/remote/domain/remote_payloads.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';

typedef SentFrame = ({
  FrameType type,
  String? id,
  Map<String, Object?> payload,
});

class Harness {
  Harness({CapabilitySet? capabilities}) {
    fake = FakeRemoteBindings()..addSession('s1');
    api = HostSessionApi(
      device: fakeDevice(capabilities: capabilities),
      bindings: fake.bindings,
      send: (type, {id, payload = const {}}) async {
        if (!delivers) {
          dropped.add((type: type, id: id, payload: payload));
          return false;
        }
        sent.add((type: type, id: id, payload: payload));
        return true;
      },
    );
  }

  late final FakeRemoteBindings fake;
  late final HostSessionApi api;
  final List<SentFrame> sent = [];

  /// Whether the transport takes what the api hands it. False is the state
  /// the host really gets into: the link the phone last used is closed and
  /// nothing else could carry the frame.
  bool delivers = true;

  /// What the phone does when it opens a session: subscribe, then ask for the
  /// history. `_reloadTranscript` in the gateway is exactly these two calls in
  /// this order, and it is the second one that makes the session *watched* —
  /// the host reads a transcript for the poll sweep only once it has served
  /// one, because subscription alone means "keep this card live" and the phone
  /// subscribes to every session it lists.
  Future<void> watch(String sessionId) async {
    await request(
      FrameType.sessionSubscribe,
      payload: {'sessionId': sessionId},
    );
    await request(FrameType.transcriptGet, payload: {'sessionId': sessionId});
  }

  /// Frames the transport refused, so a test can name what was lost.
  final List<SentFrame> dropped = [];

  int _seq = 0;

  Future<void> request(
    FrameType type, {
    Map<String, Object?> payload = const {},
    String id = 'q1',
    int? version,
  }) => api.handleEnvelope(
    Envelope.of(
      type,
      seq: _seq++,
      id: id,
      payload: payload,
      version: version ?? kProtocolVersion,
    ),
  );

  SentFrame get last => sent.last;

  String? lastErrorCode() =>
      last.type == FrameType.error ? last.payload['code'] as String? : null;
}

/// A well-formed payload for every companion request type.
const Map<FrameType, Map<String, Object?>> kRequests = {
  FrameType.sessionsList: {},
  FrameType.sessionSubscribe: {'sessionId': 's1'},
  FrameType.sessionUnsubscribe: {'sessionId': 's1'},
  FrameType.transcriptGet: {'sessionId': 's1'},
  FrameType.promptSend: {'sessionId': 's1', 'text': 'carry on'},
  FrameType.approvalAnswer: {'sessionId': 's1', 'decision': 'approve'},
  FrameType.notificationsRegister: {'token': 't0k', 'platform': 'android'},
  FrameType.sessionActivity: {'sessionId': 's1'},
  FrameType.attachmentBegin: {
    'sessionId': 's1',
    'name': 'shot.png',
    'type': 'image/png',
    'bytes': 4,
  },
  FrameType.attachmentChunk: {'uploadId': 'up1', 'seq': 0, 'data': 'AAAA'},
};

void main() {
  group('the capability matrix', () {
    for (final entry in kRequests.entries) {
      final type = entry.key;
      final needed = type.capability!;

      test('${type.wire} is refused without ${needed.wire}', () async {
        final harness = Harness(
          capabilities: CapabilitySet(CapabilitySet.all.bits & ~needed.bit),
        );

        await harness.request(type, payload: entry.value);

        expect(harness.sent, hasLength(1));
        expect(harness.lastErrorCode(), ErrorCode.notPermitted.wire);
        expect(
          harness.last.id,
          'q1',
          reason: 'the refusal answers the request',
        );
      });

      test('${type.wire} is answered with ${needed.wire} granted', () async {
        final harness = Harness(capabilities: CapabilitySet.of([needed]));

        await harness.request(type, payload: entry.value);

        expect(harness.sent, isNotEmpty);
        expect(
          harness.lastErrorCode(),
          isNot(ErrorCode.notPermitted.wire),
          reason: 'the granted capability must open exactly this request',
        );
      });
    }
  });

  group('refusals', () {
    test('an unknown frame type is an error, never a crash', () async {
      final harness = Harness();

      await harness.api.handleEnvelope(
        Envelope(seq: 0, type: 'future.frame', id: 'q9'),
      );

      expect(harness.lastErrorCode(), ErrorCode.unknownType.wire);
      expect(harness.last.id, 'q9');
    });

    test('a host-only frame from the companion is refused', () async {
      final harness = Harness();

      await harness.request(FrameType.sessionChanged);

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
    });

    test(
      'a version outside the range gets unsupported_version + status',
      () async {
        final harness = Harness();

        await harness.request(FrameType.sessionsList, version: 999);

        expect(
          harness.sent.first.payload['code'],
          ErrorCode.unsupportedVersion.wire,
        );
        expect(
          harness.sent.last.type,
          FrameType.hostStatus,
          reason: 'the peer is told what to update to',
        );
      },
    );

    test('a missing session is not_found', () async {
      final harness = Harness();

      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 'nope'},
      );

      expect(harness.lastErrorCode(), ErrorCode.notFound.wire);
    });

    test('a malformed payload is bad_request', () async {
      final harness = Harness();

      await harness.request(
        FrameType.promptSend,
        payload: const {'sessionId': 's1'},
      );

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
    });

    test('an invalid decision is bad_request', () async {
      final harness = Harness();

      await harness.request(
        FrameType.approvalAnswer,
        payload: const {'sessionId': 's1', 'decision': 'maybe'},
      );

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
    });

    test('a handler that throws refuses one request and survives', () async {
      final harness = Harness();
      harness.fake.promptError = StateError('the engine is on fire');

      await harness.request(
        FrameType.promptSend,
        payload: const {'sessionId': 's1', 'text': 'hello'},
      );
      expect(harness.lastErrorCode(), ErrorCode.internal.wire);

      harness.fake.promptError = null;
      await harness.request(
        FrameType.promptSend,
        payload: const {'sessionId': 's1', 'text': 'hello'},
        id: 'q2',
      );
      expect(harness.last.type, FrameType.result);
    });

    test('a bindings refusal carries its own code', () async {
      final harness = Harness();
      harness.fake.setAwaitingApproval('s1');
      harness.fake.approvalRefusal = const RemoteApiRefusal(
        ErrorCode.notFound,
        'no live terminal',
      );

      await harness.request(
        FrameType.approvalAnswer,
        payload: const {'sessionId': 's1', 'decision': 'deny'},
      );

      expect(harness.lastErrorCode(), ErrorCode.notFound.wire);
    });
  });

  group('requests', () {
    test('sessions.list answers with every snapshot', () async {
      final harness = Harness();
      harness.fake.addSession('s2', title: 'Another');

      await harness.request(FrameType.sessionsList);

      final sessions = harness.last.payload['sessions']! as List;
      expect(sessions, hasLength(2));
      expect(harness.last.type, FrameType.result);
    });

    test('prompt.send routes into the bindings send path', () async {
      final harness = Harness();

      await harness.request(
        FrameType.promptSend,
        payload: const {'sessionId': 's1', 'text': 'run the tests'},
      );

      expect(harness.fake.prompts, [(sessionId: 's1', text: 'run the tests')]);
      expect(harness.last.type, FrameType.result);
    });

    test('approval.answer reports the key that was pressed', () async {
      final harness = Harness();
      harness.fake.setAwaitingApproval('s1');

      await harness.request(
        FrameType.approvalAnswer,
        payload: const {'sessionId': 's1', 'decision': 'approve'},
      );

      expect(harness.last.payload['pressed'], 'Yes (enter)');
    });

    test('notifications.register persists token and platform', () async {
      final harness = Harness();

      await harness.request(
        FrameType.notificationsRegister,
        payload: const {'token': 't0k', 'platform': 'android'},
      );

      expect(harness.fake.pushes, [
        (deviceId: fakeDevice().id, token: 't0k', platform: 'android'),
      ]);
    });

    test('transcript.get slices by the after cursor', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'one'),
        RemoteTranscriptMessage(role: 'agent', text: 'two'),
        RemoteTranscriptMessage(role: 'agent', text: 'three'),
      ];

      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1', 'after': 2},
      );

      final page = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect([for (final m in page.messages) m.text], ['three']);
      expect(page.cursor, 3);
    });
  });

  group('events', () {
    test('subscribe pushes the first snapshot at once', () async {
      final harness = Harness();
      harness.fake.stages['s1'] = 'prOpen';

      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );

      expect(harness.last.type, FrameType.sessionChanged);
      expect(harness.last.payload['stage'], 'prOpen');
    });

    test('an unchanged snapshot is not resent', () async {
      final harness = Harness();
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      final before = harness.sent.length;

      await harness.api.pushSessionsChanged();
      expect(harness.sent.length, before, reason: 'nothing moved');

      harness.fake.sessions['s1'] = harness.fake.sessions['s1']!.copyWith(
        attention: 'needs_approval',
      );
      await harness.api.pushSessionsChanged();
      expect(harness.sent.length, before + 1);
      expect(harness.last.payload['attention'], 'needs_approval');
    });

    test('transcript.appended carries only the delta', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = [
        const RemoteTranscriptMessage(role: 'user', text: 'one'),
      ];
      await harness.watch('s1');

      await harness.api.pollTranscripts();
      final before = harness.sent.length;

      harness.fake.transcripts['s1']!.add(
        const RemoteTranscriptMessage(role: 'agent', text: 'two'),
      );
      await harness.api.pollTranscripts();

      final page = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect(harness.sent.length, before + 1);
      expect([for (final m in page.messages) m.text], ['two']);
      expect(page.cursor, 2);
    });

    test(
      'a device without read_transcript gets no transcript events',
      () async {
        final harness = Harness(
          capabilities: CapabilitySet.of(const [Capability.viewSessions]),
        );
        harness.fake.transcripts['s1'] = [
          const RemoteTranscriptMessage(role: 'user', text: 'one'),
        ];
        await harness.request(
          FrameType.sessionSubscribe,
          payload: const {'sessionId': 's1'},
        );
        final before = harness.sent.length;

        harness.fake.transcripts['s1']!.add(
          const RemoteTranscriptMessage(role: 'agent', text: 'two'),
        );
        await harness.api.pollTranscripts();

        expect(harness.sent.length, before);
      },
    );

    // **What the owner could not see from a pocket.** The desktop strip has
    // answered "what is it doing right now" for a while; the wire carried
    // nothing about it, so a phone had a card reading "working" and a
    // transcript that had not moved.
    group('session.activity', () {
      RemoteSessionActivity running(
        String sessionId, {
        String summary = 'Bash(flutter test)',
        String tool = 'Bash',
        bool subagent = false,
        Duration elapsed = const Duration(minutes: 76),
      }) => RemoteSessionActivity(
        sessionId: sessionId,
        observedAt: DateTime.utc(2026, 9, 7, 12),
        calls: [
          RemoteActivityCall(
            summary: summary,
            toolName: tool,
            subagent: subagent,
            startedAt: DateTime.utc(2026, 9, 7, 12).subtract(elapsed),
          ),
        ],
      );

      test('is stated when a session starts running something', () async {
        final harness = Harness();
        await harness.watch('s1');
        final before = harness.sent.length;

        // A real one: the two subagents launched from this repo on 2026-09-07
        // reported 4,549,121 ms and 4,798,063 ms of runtime, and the longest
        // unanswered tool window in the owner's store is 514.8 minutes.
        harness.fake.activities['s1'] = running(
          's1',
          summary: 'Agent(review the diff)',
          tool: 'Agent',
          subagent: true,
        );
        await harness.api.pollTranscripts();

        expect(harness.sent.length, before + 1);
        expect(harness.last.type, FrameType.sessionActivity);
        final activity = RemoteSessionActivity.fromJson(harness.last.payload);
        expect(activity.calls.single.summary, 'Agent(review the diff)');
        expect(activity.calls.single.subagent, isTrue);
        expect(
          activity.observedAt.difference(activity.calls.single.startedAt),
          const Duration(minutes: 76),
          reason: 'both instants are the host clock, so the phone need not '
              'subtract one machine from another',
        );
      });

      // A call *finishing* appends nothing — the reader attaches the result to
      // the row already there — so every cursor check in the poll would have
      // swallowed the one change the phone is waiting to see.
      test('...and again when it stops, though nothing was appended', () async {
        final harness = Harness();
        harness.fake.transcripts['s1'] = [
          const RemoteTranscriptMessage(role: 'user', text: 'go'),
        ];
        harness.fake.activities['s1'] = running('s1');
        await harness.watch('s1');
        await harness.api.pollTranscripts();
        final before = harness.sent.length;

        harness.fake.activities['s1'] = RemoteSessionActivity(
          sessionId: 's1',
          observedAt: DateTime.utc(2026, 9, 7, 13),
        );
        await harness.api.pollTranscripts();

        expect(harness.sent.length, before + 1);
        expect(harness.last.type, FrameType.sessionActivity);
        expect(
          RemoteSessionActivity.fromJson(harness.last.payload).calls,
          isEmpty,
        );
      });

      // `observedAt` moves on every read by construction, so comparing whole
      // payloads would wake the phone once a poll to say "still the same".
      test('says nothing while the answer has not changed', () async {
        final harness = Harness();
        harness.fake.activities['s1'] = running('s1');
        await harness.watch('s1');
        await harness.api.pollTranscripts();
        final before = harness.sent.length;

        harness.fake.observedAt = DateTime.utc(2026, 9, 7, 14);
        harness.fake.activities['s1'] = RemoteSessionActivity(
          sessionId: 's1',
          observedAt: DateTime.utc(2026, 9, 7, 14),
          calls: running('s1').calls,
        );
        await harness.api.pollTranscripts();

        expect(harness.sent.length, before);
      });

      // §19 on the wire: a session we cannot look into must not report an
      // empty list, which reads as "nothing is running".
      test('carries which nothing it is', () async {
        final harness = Harness();
        harness.fake.activities['s1'] = RemoteSessionActivity(
          sessionId: 's1',
          observedAt: DateTime.utc(2026, 9, 7, 12),
          absence: RemoteActivityAbsence.noRecord,
        );
        await harness.watch('s1');
        await harness.api.pollTranscripts();

        final stated = harness.sent.lastWhere(
          (f) => f.type == FrameType.sessionActivity,
        );
        expect(
          RemoteSessionActivity.fromJson(stated.payload).absence,
          RemoteActivityAbsence.noRecord,
        );
      });

      test('a pairing without the bit is refused in words', () async {
        final harness = Harness(
          capabilities: CapabilitySet(
            CapabilitySet.all.bits & ~Capability.viewActivity.bit,
          ),
        );
        harness.fake.activities['s1'] = running('s1');
        await harness.watch('s1');
        final before = harness.sent.length;

        await harness.api.pollTranscripts();
        await harness.request(
          FrameType.sessionActivity,
          payload: const {'sessionId': 's1'},
        );

        expect(
          harness.sent
              .skip(before)
              .where((f) => f.type == FrameType.sessionActivity),
          isEmpty,
          reason: 'nothing unprompted may grow into a power never granted',
        );
        expect(harness.lastErrorCode(), ErrorCode.notPermitted.wire);
        expect(
          harness.last.payload['message'],
          contains(Capability.viewActivity.wire),
          reason: 'refused with a sentence, never silently degraded',
        );
      });

      // The phone asking outright, which is what it does on opening a session
      // and after a reconnect — the frames it missed cannot be replayed.
      test('answers the phone asking for itself', () async {
        final harness = Harness();
        harness.fake.activities['s1'] = running('s1');

        await harness.request(
          FrameType.sessionActivity,
          payload: const {'sessionId': 's1'},
        );

        expect(harness.last.type, FrameType.result);
        expect(harness.last.id, 'q1');
        final activity = RemoteSessionActivity.fromJson(harness.last.payload);
        expect(activity.calls.single.summary, 'Bash(flutter test)');
      });
    });

    test(
      'approval.requested goes only to devices that can act on it',
      () async {
        final viewer = Harness(
          capabilities: CapabilitySet.of(const [Capability.viewSessions]),
        );
        await viewer.api.pushApprovalRequested('s1');
        expect(
          viewer.sent.where((f) => f.type == FrameType.approvalRequested),
          isEmpty,
        );

        final approver = Harness();
        approver.fake.approvals['s1'] = const RemoteApprovalRequest(
          sessionId: 's1',
          evidence: ['Allow Bash? (y/n)'],
          approveLabel: 'Yes',
        );
        await approver.api.pushApprovalRequested('s1');
        final frame = approver.sent.single;
        expect(frame.type, FrameType.approvalRequested);
        final request = RemoteApprovalRequest.fromJson(frame.payload);
        expect(request.evidence, ['Allow Bash? (y/n)']);
        expect(request.approveLabel, 'Yes');
        expect(request.denyLabel, isNull);
      },
    );
  });

  // --- News the transport could not carry ----------------------------------
  //
  // `no transport could carry a frame` in the owner's log, ten times in five
  // minutes, while the phone "showed retry time and again". A frame the
  // transport refuses is gone: `RemoteTransport.send` only throws once it is
  // CLOSED, which an accepted LAN link becomes for good the moment the phone
  // hangs up — the host keeps it as the active transport until the next
  // inbound frame reattaches, and drops everything sent in between.
  //
  // What made that unrecoverable rather than merely late is here: the api used
  // to record what it had told the phone BEFORE handing the frame over, so a
  // dropped update was never sent again. The phone reconnects and the desktop
  // believes it is already up to date.
  group('a frame the transport could not carry', () {
    test('is sent again, not written off as delivered', () async {
      final harness = Harness();
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      harness.fake.sessions['s1'] = harness.fake.sessions['s1']!.copyWith(
        attention: 'needs_approval',
      );

      harness.delivers = false;
      await harness.api.pushSessionsChanged();
      expect(harness.dropped, hasLength(1));

      // The link is back and nothing about the session has changed since. The
      // phone still has not heard, so the host must say it again.
      harness.delivers = true;
      final before = harness.sent.length;
      await harness.api.pushSessionsChanged();

      expect(harness.sent.length, before + 1);
      expect(harness.last.payload['attention'], 'needs_approval');
    });

    test('does not advance the transcript cursor past the phone', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = [
        const RemoteTranscriptMessage(role: 'user', text: 'one'),
      ];
      await harness.watch('s1');
      await harness.api.pollTranscripts();

      harness.fake.transcripts['s1']!.add(
        const RemoteTranscriptMessage(role: 'agent', text: 'two'),
      );
      harness.delivers = false;
      await harness.api.pollTranscripts();
      expect(harness.dropped.last.type, FrameType.transcriptAppended);

      // The agent says one more thing and the link comes back. Both messages
      // are owed — the phone never saw either — so both go out.
      harness.fake.transcripts['s1']!.add(
        const RemoteTranscriptMessage(role: 'agent', text: 'three'),
      );
      harness.delivers = true;
      await harness.api.pollTranscripts();

      final page = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect([for (final m in page.messages) m.text], ['two', 'three']);
      expect(page.cursor, 3);
    });
  });

  group('subscribing does not wait on the transcript', () {
    // The owner's report, reproduced on a real phone: "connection is fine,
    // sessions are listed, but opening a session fails". The link was up and
    // `sessions.list` answered; `session.subscribe` timed out every time, and
    // the desktop later logged a result frame it could no longer deliver.
    //
    // The cause was here: subscribe parsed the whole transcript to learn a
    // *count* before replying. On a 115 MB store that is far past the phone's
    // request timeout — and because a device's frames are handled on one
    // serial chain, every request queued behind it timed out too.

    test('the result arrives without reading the transcript at all', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = [
        for (var i = 0; i < 50; i++)
          RemoteTranscriptMessage(role: 'user', text: 'line $i'),
      ];

      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );

      expect(
        harness.fake.transcriptReads,
        0,
        reason: 'a subscribe is bookkeeping; the phone asks for history itself',
      );
      expect(
        harness.sent.any((f) => f.type == FrameType.result),
        isTrue,
      );
    });

    test('and answers even while a transcript read would never finish', () async {
      final harness = Harness();
      // A read that never completes is the limit of a read that is merely far
      // too slow, and it is the honest shape of the bug: the phone gave up
      // first every time.
      harness.fake.transcriptGate = Completer<void>();
      addTearDown(() => harness.fake.transcriptGate!.complete());

      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      ).timeout(const Duration(seconds: 5));

      expect(harness.sent.any((f) => f.type == FrameType.result), isTrue);
    });

    test('a subscribed session nobody is reading is never polled', () async {
      // The other half of the same bug, and the larger one. The phone
      // subscribes to *every* session it lists, because subscription is what
      // keeps the cards live — so polling on subscription alone meant a full
      // transcript parse per listed session, every tick.
      final harness = Harness()..fake.addSession('s2');
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's2'},
      );
      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1'},
      );
      final afterHistory = harness.fake.transcriptReads;

      await harness.api.pollTranscripts();

      expect(
        harness.fake.transcriptReads - afterHistory,
        1,
        reason: 'only the session whose history was asked for',
      );
    });

    test('and the one being read still gets its delta', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = [
        const RemoteTranscriptMessage(role: 'user', text: 'before'),
      ];
      await harness.watch('s1');
      harness.sent.clear();

      harness.fake.transcripts['s1']!.add(
        const RemoteTranscriptMessage(role: 'assistant', text: 'after'),
      );
      await harness.api.pollTranscript('s1');

      final appended = harness.sent.firstWhere(
        (f) => f.type == FrameType.transcriptAppended,
      );
      final messages = appended.payload['messages']! as List;
      expect(messages, hasLength(1));
      expect((messages.single as Map)['text'], 'after');
    });
  });

  group('a long transcript is sent as its tail', () {
    // Reproduced on the device: opening this repo's own session — 53 MB of
    // JSONL, 25,421 lines — returned every message in one sealed frame. The
    // phone sat on a spinner and the desktop logged "no transport could carry
    // a result frame" three times, because by the time the frame was built the
    // phone had given up and redialled.

    List<RemoteTranscriptMessage> conversation(int count) => [
      for (var i = 0; i < count; i++)
        RemoteTranscriptMessage(role: i.isEven ? 'user' : 'agent', text: 'm$i'),
    ];

    test('a short one is sent whole, and says nothing was held back', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(12);

      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1'},
      );

      final page = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect(page.messages, hasLength(12));
      expect(page.omitted, 0);
      expect(page.cursor, 12);
    });

    test('a long one is cut to the end, and says how much', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(kRemoteTranscriptPageMax * 3);

      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1'},
      );

      final page = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect(page.messages, hasLength(kRemoteTranscriptPageMax));
      expect(page.omitted, kRemoteTranscriptPageMax * 2);
      // The end, not the beginning: a conversation is opened where it is now.
      expect(page.messages.last.text, 'm${kRemoteTranscriptPageMax * 3 - 1}');
      // And the cursor still counts the whole thing, so the appended stream
      // lines up with what the phone was actually given.
      expect(page.cursor, kRemoteTranscriptPageMax * 3);
    });

    test('an explicit `after` still pages from where it says', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(20);

      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1', 'after': 5},
      );

      final page = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect(page.messages.first.text, 'm5');
      expect(page.omitted, 5);
    });

    test('and the delta after a cut page is still only the new messages',
        () async {
      // The cursor is the whole count, not the page length, so growth after a
      // truncated read must not resend the tail it already sent.
      final harness = Harness();
      harness.fake.transcripts['s1'] = conversation(kRemoteTranscriptPageMax * 2);
      await harness.watch('s1');
      harness.sent.clear();

      harness.fake.transcripts['s1']!.add(
        const RemoteTranscriptMessage(role: 'agent', text: 'brand new'),
      );
      await harness.api.pollTranscript('s1');

      final appended = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect(appended.messages, hasLength(1));
      expect(appended.messages.single.text, 'brand new');
    });
  });

  group('an expensive transcript is polled less often', () {
    test('a cheap one is polled every time it is asked', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
      ];
      await harness.watch('s1');
      final before = harness.fake.transcriptReads;

      await harness.api.pollTranscript('s1');
      await harness.api.pollTranscript('s1');
      await harness.api.pollTranscript('s1');

      expect(harness.fake.transcriptReads - before, 3);
    });

    test('but one that takes real time is not read again immediately',
        () async {
      // The device case: a 53 MB transcript read on every two-second sweep,
      // on the one chain the phone's own requests are queued behind. The read
      // has to happen; happening *continuously* is what left nothing for the
      // link.
      final harness = Harness();
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
      ];
      await harness.watch('s1');
      harness.fake.transcriptCost = const Duration(milliseconds: 40);
      final before = harness.fake.transcriptReads;

      await harness.api.pollTranscript('s1');
      // Straight after: inside the backoff the last read earned.
      await harness.api.pollTranscript('s1');
      await harness.api.pollTranscript('s1');

      expect(
        harness.fake.transcriptReads - before,
        1,
        reason: 'one read, then a wait proportional to what it cost',
      );
    });

    test('and unsubscribing forgets the backoff with everything else',
        () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = const [
        RemoteTranscriptMessage(role: 'user', text: 'hello'),
      ];
      await harness.watch('s1');
      harness.fake.transcriptCost = const Duration(milliseconds: 40);
      await harness.api.pollTranscript('s1');

      await harness.request(
        FrameType.sessionUnsubscribe,
        payload: const {'sessionId': 's1'},
      );
      harness.fake.transcriptCost = Duration.zero;
      await harness.watch('s1');
      final before = harness.fake.transcriptReads;

      await harness.api.pollTranscript('s1');

      expect(harness.fake.transcriptReads - before, 1);
    });
  });

  group('a task-notification envelope is folded down before it crosses', () {
    // Seen on the phone, 2026-09-02: a subagent completion landed as a turn
    // whose text was the raw payload, so the chat read
    // `</result><usage><subagent_tokens>295802</subagent_tokens>…` as
    // conversation and it was most of the screen. This session's own store
    // holds 199 of them.
    String envelope({
      String? summary,
      String status = 'completed',
      String body = 'Done.\n\nThe gate is green.',
    }) =>
        '<task-notification>\n'
        '<task-id>afe13d031b3d72daa</task-id>\n'
        '<tool-use-id>toolu_01ARtzQPvBn3KUMhfkUE2AoL</tool-use-id>\n'
        '<status>$status</status>\n'
        '${summary == null ? '' : '<summary>$summary</summary>\n'}'
        '<result>$body</result>\n'
        '<usage><subagent_tokens>295802</subagent_tokens>'
        '<tool_uses>165</tool_uses><duration_ms>2614397</duration_ms></usage>\n'
        '</task-notification>';

    Future<RemoteTranscriptPage> pageOf(List<RemoteTranscriptMessage> stored) async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = stored;
      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1'},
      );
      return RemoteTranscriptPage.fromJson(harness.last.payload);
    }

    test('it becomes the one line it already carries', () async {
      final page = await pageOf([
        const RemoteTranscriptMessage(role: 'user', text: 'go on then'),
        RemoteTranscriptMessage(
          role: 'user',
          text: envelope(summary: 'Agent "Mobile chat scroll to latest" finished'),
        ),
      ]);

      expect(page.messages, hasLength(2));
      expect(page.messages.first.text, 'go on then');
      // The envelope's own words, not ours — and a `tool` row, so nobody
      // reads it as something a person said.
      expect(
        page.messages.last,
        const RemoteTranscriptMessage(
          role: 'tool',
          text: 'Agent "Mobile chat scroll to latest" finished',
        ),
      );
    });

    test('and the frame it sends is a fraction of the bytes', () async {
      // Counted, not timed. Measured against this session's own store: 199
      // envelopes, 691,852 bytes of them, folding to 27,305 — and the real
      // 300-message tail page holds five, which is 189,609 bytes before and
      // 128,805 after. This pins the shape of that with one worst-case
      // envelope (the largest real one is 32,708 bytes, folding to 75).
      final raw = envelope(
        summary: 'Agent "Mobile chat scroll to latest" finished',
        body: List.filled(1200, 'a paragraph of the report').join('\n'),
      );
      final stored = [
        const RemoteTranscriptMessage(role: 'user', text: 'go on then'),
        RemoteTranscriptMessage(role: 'user', text: raw),
      ];
      final before = jsonEncode(
        RemoteTranscriptPage(
          sessionId: 's1',
          messages: stored,
          cursor: stored.length,
        ).toJson(),
      ).length;

      final harness = Harness();
      harness.fake.transcripts['s1'] = stored;
      await harness.request(
        FrameType.transcriptGet,
        payload: const {'sessionId': 's1'},
      );
      final after = jsonEncode(harness.last.payload).length;

      expect(after * 20, lessThan(before));
    });

    test('and a store written with CRLF folds the same way', () async {
      // The host runs on Windows, macOS and Linux. A transcript line's own
      // content can carry \r\n, and a trailing \r would otherwise leave the
      // envelope unrecognised — and the summary carrying one.
      final page = await pageOf([
        RemoteTranscriptMessage(
          role: 'user',
          text:
              '${envelope(summary: 'Agent "Windows host" finished').replaceAll('\n', '\r\n')}\r\n',
        ),
      ]);

      expect(
        page.messages.single,
        const RemoteTranscriptMessage(
          role: 'tool',
          text: 'Agent "Windows host" finished',
        ),
      );
    });

    test('an envelope that names no summary claims no outcome', () async {
      final page = await pageOf([
        RemoteTranscriptMessage(role: 'user', text: envelope(status: 'failed')),
      ]);

      expect(
        page.messages.single,
        const RemoteTranscriptMessage(
          role: 'tool',
          text: 'A background task reported back.',
        ),
      );
    });

    test('a person who quotes the tag keeps their whole message', () async {
      const quoted =
          'the phone showed me `</task-notification>` as a message — see '
          '<task-notification> in the backlog for what that is';
      final page = await pageOf(const [
        RemoteTranscriptMessage(role: 'user', text: quoted),
      ]);

      // Not folded, not re-roled, not shortened: it is theirs.
      expect(
        page.messages.single,
        const RemoteTranscriptMessage(role: 'user', text: quoted),
      );
    });

    test('a live one is folded too, on the way through the poll', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = [
        const RemoteTranscriptMessage(role: 'user', text: 'go on then'),
      ];
      await harness.watch('s1');
      harness.sent.clear();

      // What the owner actually hit: the subagent finished while the phone
      // was already watching, so the envelope came through `transcript
      // .appended` rather than the opening read.
      harness.fake.transcripts['s1']!.add(
        RemoteTranscriptMessage(
          role: 'user',
          text: envelope(summary: 'Agent "Host transcript hygiene" finished'),
        ),
      );
      await harness.api.pollTranscript('s1');

      final page = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect(
        page.messages.single,
        const RemoteTranscriptMessage(
          role: 'tool',
          text: 'Agent "Host transcript hygiene" finished',
        ),
      );
    });

    test('one turn in, one turn out, so the cursor still lines up', () async {
      final harness = Harness();
      harness.fake.transcripts['s1'] = [
        RemoteTranscriptMessage(role: 'user', text: envelope(summary: 'one')),
        RemoteTranscriptMessage(role: 'user', text: envelope(summary: 'two')),
        const RemoteTranscriptMessage(role: 'agent', text: 'and on we go'),
      ];
      await harness.watch('s1');
      final opened = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect(opened.messages, hasLength(3));
      expect(opened.cursor, 3);
      harness.sent.clear();

      harness.fake.transcripts['s1']!.add(
        const RemoteTranscriptMessage(role: 'agent', text: 'brand new'),
      );
      await harness.api.pollTranscript('s1');

      // A dropped turn here would have shifted the delta and resent history.
      final appended = RemoteTranscriptPage.fromJson(harness.last.payload);
      expect(appended.messages, hasLength(1));
      expect(appended.messages.single.text, 'brand new');
    });

    test('the wire carries the store\'s own bytes, entities and all', () async {
      // The phone's `&lt;explicit paths&gt;` was written that way by the agent
      // CLI, inside a task-notification body — nothing here escapes, and
      // nothing here unescapes either, because a message may genuinely be
      // quoting an entity.
      const literal = 'a README badge with `?style=flat&amp;color=08C` in it';
      const angled = 'git commit -F msg -- <explicit paths>';
      final page = await pageOf(const [
        RemoteTranscriptMessage(role: 'user', text: literal),
        RemoteTranscriptMessage(role: 'agent', text: angled),
      ]);

      expect(page.messages.first.text, literal);
      expect(page.messages.last.text, angled);
    });
  });

  group('an approval that stops waiting is said so', () {
    // Seen on the phone, 2026-09-02: a card below the chat still offering
    // approve and deny for a decision the desktop had already made. The
    // protocol told the phone when a request appeared and never when it went
    // away, so answering it anywhere else left the card orphaned.

    Future<Harness> waiting() async {
      final harness = Harness();
      harness.fake.setAwaitingApproval('s1');
      harness.fake.approvals['s1'] = const RemoteApprovalRequest(
        sessionId: 's1',
        evidence: ['Allow Bash? (y/n)'],
        approveLabel: 'Yes',
      );
      await harness.api.pushApprovalRequested('s1');
      return harness;
    }

    List<SentFrame> resolutions(Harness harness) => [
      for (final frame in harness.sent)
        if (frame.type == FrameType.approvalResolved) frame,
    ];

    test('answered on the desktop, the phone is told on the next sweep',
        () async {
      final harness = await waiting();
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      expect(resolutions(harness), isEmpty, reason: 'still waiting');

      // The desktop's own card was pressed: the session stops asking. That is
      // the whole signal — the host cannot see which button, and does not say.
      harness.fake.setAwaitingApproval('s1', waiting: false);
      await harness.api.pushSessionsChanged();

      final resolved = RemoteApprovalResolved.fromJson(
        resolutions(harness).single.payload,
      );
      expect(resolved.sessionId, 's1');
      expect(resolved.outcome, RemoteApprovalOutcome.elsewhere);
    });

    test('and said once, not on every sweep after it', () async {
      final harness = await waiting();
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      harness.fake.setAwaitingApproval('s1', waiting: false);

      await harness.api.pushSessionsChanged();
      await harness.api.pushSessionsChanged();
      await harness.api.pushSessionsChanged();

      expect(resolutions(harness), hasLength(1));
    });

    test('a phone that was away is told when it subscribes again', () async {
      final harness = await waiting();
      // Off the link for the whole of it: the answer happens, and the frame
      // that would have carried it has nowhere to go.
      harness.delivers = false;
      harness.fake.setAwaitingApproval('s1', waiting: false);
      await harness.api.pushSessionsChanged();
      expect(resolutions(harness), isEmpty);

      harness.delivers = true;
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );

      expect(resolutions(harness), hasLength(1));
    });

    test('a dropped resolution is repeated, never written off', () async {
      final harness = await waiting();
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      harness.fake.setAwaitingApproval('s1', waiting: false);

      harness.delivers = false;
      await harness.api.pushSessionsChanged();
      expect(
        harness.dropped.where((f) => f.type == FrameType.approvalResolved),
        hasLength(1),
      );

      harness.delivers = true;
      await harness.api.pushSessionsChanged();
      expect(resolutions(harness), hasLength(1));
    });

    test('the phone that answers is told which way it went', () async {
      final harness = await waiting();

      await harness.request(
        FrameType.approvalAnswer,
        payload: const {'sessionId': 's1', 'decision': 'deny'},
      );

      final resolved = RemoteApprovalResolved.fromJson(
        resolutions(harness).single.payload,
      );
      // Stated, because this host pressed the key and knows.
      expect(resolved.outcome, RemoteApprovalOutcome.denied);
      expect(harness.last.type, FrameType.result);
    });

    test('a second answer to a settled approval is refused, not applied',
        () async {
      final harness = await waiting();
      harness.fake.setAwaitingApproval('s1', waiting: false);

      await harness.request(
        FrameType.approvalAnswer,
        payload: const {'sessionId': 's1', 'decision': 'approve'},
      );

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(
        harness.last.payload['message'],
        'this approval has already been answered',
      );
      // The point of refusing: nothing was typed into whatever prompt is
      // there now.
      expect(harness.fake.approvalAnswers, isEmpty);
    });

    test('a device that cannot approve hears neither half', () async {
      final viewer = Harness(
        capabilities: CapabilitySet.of(const [Capability.viewSessions]),
      );
      viewer.fake.setAwaitingApproval('s1');
      await viewer.api.pushApprovalRequested('s1');
      await viewer.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      viewer.fake.setAwaitingApproval('s1', waiting: false);
      await viewer.api.pushSessionsChanged();

      expect(
        viewer.sent.where(
          (f) =>
              f.type == FrameType.approvalRequested ||
              f.type == FrameType.approvalResolved,
        ),
        isEmpty,
      );
    });

    test('a session that was never asking says nothing', () async {
      final harness = Harness();
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      await harness.api.pushSessionsChanged();

      expect(resolutions(harness), isEmpty);
    });
  });
}
