/// The host session api, driven directly: the capability matrix, the refusal
/// codes, and the event dedupe — no sockets, no sealing, just envelopes in
/// and frames out.
library;

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
        sent.add((type: type, id: id, payload: payload));
      },
    );
  }

  late final FakeRemoteBindings fake;
  late final HostSessionApi api;
  final List<SentFrame> sent = [];

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
      await harness.request(
        FrameType.sessionSubscribe,
        payload: const {'sessionId': 's1'},
      );

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
}
