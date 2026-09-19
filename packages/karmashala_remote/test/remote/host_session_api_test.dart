/// The host session api driven directly: the capability matrix, the refusal
/// codes and the event dedupe — envelopes in, frames out.
library;

import 'dart:async';
import 'dart:convert';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';
import 'package:test/test.dart';

import './fake_bindings.dart';

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

  /// Whether the transport takes what the api hands it. False is the state the
  /// host really gets into: the phone's last link is closed and nothing else can
  /// carry the frame.
  bool delivers = true;

  /// What the phone does on opening a session: subscribe, then ask for the
  /// history. The second call is what makes the session *watched* — subscription
  /// alone only means "keep this card live".
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
  FrameType.menuAnswer: {'sessionId': 's1', 'menuId': 'm1', 'option': 0},
  FrameType.usageGet: {},
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

    test('a repeated prompt.send with one key is typed once', () async {
      final harness = Harness();
      const payload = {
        'sessionId': 's1',
        'text': 'run the tests',
        'requestId': 'p-1',
      };

      await harness.request(FrameType.promptSend, payload: payload);
      await harness.request(FrameType.promptSend, payload: payload);

      // The phone could not tell whether the first answer was lost, so it
      // asked again with the same key; the agent must not be typed at twice.
      expect(harness.fake.prompts, [(sessionId: 's1', text: 'run the tests')]);
      expect(harness.last.type, FrameType.result);
      expect(harness.last.payload['replayed'], isTrue);
    });

    test('a different key is a different message', () async {
      final harness = Harness();

      await harness.request(
        FrameType.promptSend,
        payload: const {'sessionId': 's1', 'text': 'again', 'requestId': 'p-1'},
      );
      await harness.request(
        FrameType.promptSend,
        payload: const {'sessionId': 's1', 'text': 'again', 'requestId': 'p-2'},
      );

      expect(harness.fake.prompts, hasLength(2));
      expect(harness.last.payload['replayed'], isNull);
    });

    test('a send that failed leaves its key free to try again', () async {
      final harness = Harness();
      harness.fake.promptError = const RemoteApiRefusal(
        ErrorCode.badRequest,
        'no',
      );

      await harness.request(
        FrameType.promptSend,
        payload: const {'sessionId': 's1', 'text': 'hi', 'requestId': 'p-1'},
      );
      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);

      harness.fake.promptError = null;
      await harness.request(
        FrameType.promptSend,
        payload: const {'sessionId': 's1', 'text': 'hi', 'requestId': 'p-1'},
      );

      expect(harness.fake.prompts, [(sessionId: 's1', text: 'hi')]);
      expect(harness.last.type, FrameType.result);
    });

    test('a key longer than the bound is refused', () async {
      final harness = Harness();

      await harness.request(
        FrameType.promptSend,
        payload: {
          'sessionId': 's1',
          'text': 'hi',
          'requestId': 'k' * (kMaxSessionStartKeyLength + 1),
        },
      );

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(harness.fake.prompts, isEmpty);
    });

    test('a phone that sends no key is typed for every time', () async {
      final harness = Harness();
      const payload = {'sessionId': 's1', 'text': 'twice'};

      await harness.request(FrameType.promptSend, payload: payload);
      await harness.request(FrameType.promptSend, payload: payload);

      expect(harness.fake.prompts, hasLength(2));
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

      final push = harness.fake.pushes.single;
      expect(push.deviceId, fakeDevice().id);
      expect(push.token, 't0k');
      expect(push.platform, 'android');
      // A companion that says nothing about itself: every presence field its
      // own unknown, and nothing invented for it.
      expect(push.presence.visibility, CompanionVisibility.unknown);
      expect(push.presence.deviceKind, CompanionDeviceKind.unknown);
      expect(push.presence.focusedSessionId, isNull);
    });

    test('notifications.register carries the presence beside the token',
        () async {
      final harness = Harness();

      await harness.request(
        FrameType.notificationsRegister,
        payload: const {
          'token': 't0k',
          'platform': 'android',
          'deviceKind': 'phone',
          'visibility': 'background',
          'focusedSessionId': 's1',
        },
      );

      final presence = harness.fake.pushes.single.presence;
      expect(presence.deviceKind, CompanionDeviceKind.phone);
      expect(presence.visibility, CompanionVisibility.background);
      expect(presence.focusedSessionId, 's1');
    });

    test('a presence word this build has never heard reads as unknown',
        () async {
      final harness = Harness();

      await harness.request(
        FrameType.notificationsRegister,
        payload: const {
          'token': 't0k',
          'platform': 'android',
          'visibility': 'hibernating',
          'deviceKind': 7,
        },
      );

      final presence = harness.fake.pushes.single.presence;
      expect(presence.visibility, CompanionVisibility.unknown);
      expect(presence.deviceKind, CompanionDeviceKind.unknown);
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

    // Found on the Oppo, 2026-09-19: a session started on the desktop never
    // reached the phone's list until the app was restarted. `session.changed`
    // went only to subscribed sessions, and a phone subscribes to what it
    // listed — so a session born after the list was never announced.
    test('a session started after the phone listed is announced', () async {
      final harness = Harness();
      await harness.request(FrameType.sessionsList);
      harness.fake.addSession('s2', title: 'Born later');
      final before = harness.sent.length;

      await harness.api.pushNewSessions();

      expect(harness.sent.length, before + 1);
      expect(harness.last.type, FrameType.sessionChanged);
      expect(harness.last.payload['sessionId'], 's2');

      await harness.api.pushNewSessions();
      expect(harness.sent.length, before + 1, reason: 'announced once');
    });

    test('nothing is announced to a phone that has not listed', () async {
      final harness = Harness();
      harness.fake.addSession('s2');

      await harness.api.pushNewSessions();

      expect(
        harness.sent,
        isEmpty,
        reason: 'its first list will carry everything anyway',
      );
    });

    test('a session is not announced to a phone without view_sessions',
        () async {
      final harness = Harness(
        capabilities: CapabilitySet.of(const [Capability.startSession]),
      );
      await harness.request(FrameType.sessionsList);
      harness.fake.addSession('s2');
      final before = harness.sent.length;

      await harness.api.pushNewSessions();

      expect(harness.sent.length, before);
    });

    test('an announcement the link dropped is tried again', () async {
      final harness = Harness();
      await harness.request(FrameType.sessionsList);
      harness.fake.addSession('s2');

      harness.delivers = false;
      await harness.api.pushNewSessions();
      harness.delivers = true;
      await harness.api.pushNewSessions();

      expect(harness.last.payload['sessionId'], 's2');
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

        // A real one: the longest unanswered tool window in the owner's store
        // is 514.8 minutes.
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

      // A call *finishing* appends nothing, so a cursor check in the poll would
      // swallow the one change the phone is waiting to see.
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

  // A frame the transport refuses is gone: an accepted LAN link stays CLOSED
  // until an inbound frame reattaches, so delivery is recorded after the send.
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
    // Subscribe used to parse the whole transcript to learn a *count* before
    // replying, and every request queued behind it on the device's one serial
    // chain timed out with it.

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
      // A read that never completes is the limit of one merely far too slow.
      harness.fake.transcriptGate = Completer<void>();
      addTearDown(() => harness.fake.transcriptGate!.complete());

      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      ).timeout(const Duration(seconds: 5));

      expect(harness.sent.any((f) => f.type == FrameType.result), isTrue);
    });

    test('a subscribed session nobody is reading is never polled', () async {
      // The phone subscribes to *every* session it lists, so polling on
      // subscription alone meant a transcript parse per session per tick.
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
    // Opening this repo's own session returned every message in one sealed
    // frame; the phone gave up and redialled before it was built.

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
      // The device case: a 53 MB transcript read on every two-second sweep, on
      // the one chain the phone's own requests queue behind.
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
    // whose text was the raw payload, and it was most of the screen.
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
      // Counted, not timed, and pinned with one worst-case envelope.
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
      // A transcript line's own content can carry \r\n, and a trailing \r would
      // otherwise leave the envelope unrecognised.
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

      // The subagent finished while the phone was already watching, so the
      // envelope came through `transcript.appended` rather than the opening read.
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
      // The escaping is the agent CLI's: nothing here escapes and nothing here
      // unescapes, because a message may genuinely be quoting an entity.
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
    // Seen on the phone, 2026-09-02: a card still offering approve and deny for
    // a decision the desktop had already made.

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

  // Seen on the phone, 2026-09-19: a session reading "Needs you" with nothing
  // under it. `approval.requested` goes out once, as the session starts
  // waiting — and a phone that was asleep then, or on a link that has since
  // been replaced, opened the session and was never told what it was for.
  group('a phone that opens a session already waiting is told what for', () {
    List<SentFrame> requests(Harness harness) => [
      for (final frame in harness.sent)
        if (frame.type == FrameType.approvalRequested) frame,
    ];

    test('on subscribe, with the evidence of now', () async {
      final harness = Harness();
      harness.fake.setAwaitingApproval('s1');
      harness.fake.approvals['s1'] = const RemoteApprovalRequest(
        sessionId: 's1',
        evidence: ['Allow Bash? (y/n)'],
        approveLabel: 'Yes',
      );

      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );

      final sent = RemoteApprovalRequest.fromJson(
        requests(harness).single.payload,
      );
      expect(sent.evidence, ['Allow Bash? (y/n)']);
    });

    test('once per link, not on every subscribe', () async {
      final harness = Harness();
      harness.fake.setAwaitingApproval('s1');
      await harness.api.pushApprovalRequested('s1');
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
        id: 'q2',
      );
      expect(requests(harness), hasLength(1));
    });

    test('and not at all to a device that cannot answer it', () async {
      final viewer = Harness(
        capabilities: CapabilitySet.of(const [Capability.viewSessions]),
      );
      viewer.fake.setAwaitingApproval('s1');
      await viewer.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      expect(requests(viewer), isEmpty);
    });

    test('nor for a session that is not waiting', () async {
      final harness = Harness();
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );
      expect(requests(harness), isEmpty);
    });
  });
}
