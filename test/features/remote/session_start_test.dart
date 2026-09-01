/// Starting a session from the phone, driven through the protocol: the
/// capability gate, the workspace listing, and the idempotency key that makes
/// a retry after a dropped link cost one session rather than two.
library;

import 'dart:async';

import 'package:karmashala/src/features/remote/application/host_bindings.dart';
import 'package:karmashala/src/features/remote/application/host_session_api.dart';
import 'package:karmashala/src/features/remote/application/session_start_ledger.dart';
import 'package:karmashala/src/features/remote/domain/remote_payloads.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';

typedef Frame = ({FrameType type, String? id, Map<String, Object?> payload});

/// One phone talking to one desktop. [reconnect] rebuilds the api the way a
/// redial does — new generation, same device, same ledger.
class StartHarness {
  StartHarness({CapabilitySet? capabilities})
    : _capabilities = capabilities ?? CapabilitySet.all {
    fake = FakeRemoteBindings()..addWorkspace();
    api = _newApi();
  }

  final CapabilitySet _capabilities;
  late final FakeRemoteBindings fake;
  late HostSessionApi api;
  final List<Frame> sent = [];
  final SessionStartLedger ledger = SessionStartLedger();
  int _seq = 0;

  HostSessionApi _newApi() => HostSessionApi(
    device: fakeDevice(capabilities: _capabilities),
    bindings: fake.bindings,
    startLedger: ledger,
    send: (type, {id, payload = const {}}) async {
      sent.add((type: type, id: id, payload: payload));
    },
  );

  /// The phone came back on a fresh rendezvous generation, so the host built
  /// a new api for it — everything a redial actually changes.
  void reconnect() => api = _newApi();

  Future<void> request(
    FrameType type, {
    Map<String, Object?> payload = const {},
    String id = 'q1',
  }) => api.handleEnvelope(
    Envelope.of(type, seq: _seq++, id: id, payload: payload),
  );

  Future<void> start({
    String requestId = 'k1',
    String repositoryId = 'r1',
    String installationId = 'i1',
    String permissionMode = 'ask',
    String? title,
    String? message,
    String id = 'q1',
  }) => request(
    FrameType.sessionStart,
    id: id,
    payload: {
      'requestId': requestId,
      'repositoryId': repositoryId,
      'installationId': installationId,
      'permissionMode': permissionMode,
      'title': ?title,
      'message': ?message,
    },
  );

  Frame get last => sent.last;

  String? lastErrorCode() =>
      last.type == FrameType.error ? last.payload['code'] as String? : null;

  String? lastErrorMessage() =>
      last.type == FrameType.error ? last.payload['message'] as String? : null;
}

void main() {
  group('the capability gate', () {
    for (final type in [FrameType.workspaceList, FrameType.sessionStart]) {
      test('${type.wire} needs start_session', () {
        expect(type.capability, Capability.startSession);
      });

      test('${type.wire} is refused in words without it', () async {
        final harness = StartHarness(
          capabilities: CapabilitySet(
            CapabilitySet.all.bits & ~Capability.startSession.bit,
          ),
        );

        await harness.request(type, payload: {
          'requestId': 'k1',
          'repositoryId': 'r1',
          'installationId': 'i1',
          'permissionMode': 'ask',
        });

        expect(harness.lastErrorCode(), ErrorCode.notPermitted.wire);
        expect(harness.lastErrorMessage(), contains('start_session'));
        expect(harness.fake.starts, isEmpty);
      });
    }

    test('a phone paired before this existed holds no start bit', () {
      // The five v1 capabilities, exactly as a pre-Loop-84 pairing stored them.
      const beforeThisLoop = CapabilitySet(0x1f);

      expect(beforeThisLoop.has(Capability.startSession), isFalse);
      expect(beforeThisLoop.allows(FrameType.sessionStart), isFalse);
      expect(beforeThisLoop.allows(FrameType.workspaceList), isFalse);
      expect(
        beforeThisLoop.allows(FrameType.promptSend),
        isTrue,
        reason: 'and keeps everything it was actually granted',
      );
    });
  });

  group('workspace.list', () {
    test('answers with the projects, checkouts and agents on offer', () async {
      final harness = StartHarness();

      await harness.request(FrameType.workspaceList);

      expect(harness.last.type, FrameType.result);
      final projects = harness.last.payload['projects']! as List;
      final project = RemoteWorkspaceProject.fromJson(
        projects.single as Map<String, Object?>,
      );
      expect(project.projectId, 'p1');
      expect(project.checkouts.single.repositoryId, 'r1');
      final agent = project.checkouts.single.agents.single;
      expect(agent.installationId, 'i1');
      expect(agent.defaultMode, 'ask');
      expect(agent.acceptsOpeningMessage, isTrue);
      expect(
        agent.permissionModes.map((m) => m.mode),
        ['ask', 'bypass'],
        reason: 'the phone offers the modes the desktop says exist',
      );
    });

    test('an empty workspace is an empty list, never an error', () async {
      final harness = StartHarness()..fake.workspace.clear();

      await harness.request(FrameType.workspaceList);

      expect(harness.last.type, FrameType.result);
      expect(harness.last.payload['projects'], isEmpty);
    });
  });

  group('session.start', () {
    test('starts one session and answers with it', () async {
      final harness = StartHarness();

      await harness.start(title: 'Fix the tests', message: 'go');

      expect(harness.last.type, FrameType.result);
      final started = RemoteSessionStarted.fromJson(harness.last.payload);
      expect(started.sessionId, 'new1');
      expect(started.title, 'Fix the tests');
      expect(started.permissionMode, 'ask');
      expect(started.replayed, isFalse);
      expect(harness.fake.starts, hasLength(1));
      expect(harness.fake.starts.single.repositoryId, 'r1');
      expect(harness.fake.starts.single.installationId, 'i1');
      expect(harness.fake.starts.single.message, 'go');
    });

    test('carries the mode the user picked, never one of its own', () async {
      final harness = StartHarness();

      await harness.start(permissionMode: 'bypass');

      expect(harness.fake.starts.single.permissionMode, 'bypass');
    });

    test('a blank title or message reaches the launcher as nothing', () async {
      final harness = StartHarness();

      await harness.start(title: '   ', message: '');

      expect(harness.fake.starts.single.title, isNull);
      expect(harness.fake.starts.single.message, isNull);
    });

    test('a request with no idempotency key is refused', () async {
      final harness = StartHarness();

      await harness.request(FrameType.sessionStart, payload: const {
        'repositoryId': 'r1',
        'installationId': 'i1',
        'permissionMode': 'ask',
      });

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(harness.lastErrorMessage(), contains('requestId'));
      expect(harness.fake.starts, isEmpty);
    });

    test('an oversized idempotency key is refused', () async {
      final harness = StartHarness();

      await harness.start(requestId: 'k' * (kMaxSessionStartKeyLength + 1));

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(harness.fake.starts, isEmpty);
    });

    for (final missing in const ['repositoryId', 'installationId', 'permissionMode']) {
      test('a request with no $missing is refused', () async {
        final harness = StartHarness();
        final payload = <String, Object?>{
          'requestId': 'k1',
          'repositoryId': 'r1',
          'installationId': 'i1',
          'permissionMode': 'ask',
        }..remove(missing);

        await harness.request(FrameType.sessionStart, payload: payload);

        expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
        expect(harness.lastErrorMessage(), contains(missing));
        expect(harness.fake.starts, isEmpty);
      });
    }

    test('says why in the desktop own words when it refuses', () async {
      final harness = StartHarness()
        ..fake.startError = const RemoteApiRefusal(
          ErrorCode.badRequest,
          'Antigravity takes no opening message on its command line',
        );

      await harness.start();

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(
        harness.lastErrorMessage(),
        'Antigravity takes no opening message on its command line',
      );
    });
  });

  group('the idempotency key', () {
    test('the same key twice starts one session', () async {
      final harness = StartHarness();

      await harness.start(id: 'q1');
      await harness.start(id: 'q2');

      expect(harness.fake.starts, hasLength(1));
      expect(harness.sent.map((f) => f.type), everyElement(FrameType.result));
      final second = RemoteSessionStarted.fromJson(harness.last.payload);
      expect(second.sessionId, 'new1', reason: 'the same session comes back');
      expect(second.replayed, isTrue, reason: 'and it says nothing was done');
    });

    test('a retry after the link dropped still starts one session', () async {
      final harness = StartHarness();

      await harness.start(id: 'q1');
      // The answer never reached the phone; it redialled, which lands the host
      // on a fresh generation and therefore a fresh api.
      harness.reconnect();
      await harness.start(id: 'q1');

      expect(harness.fake.starts, hasLength(1));
      expect(
        RemoteSessionStarted.fromJson(harness.last.payload).sessionId,
        'new1',
      );
    });

    test('a different key is a different intention', () async {
      final harness = StartHarness();

      await harness.start(requestId: 'k1');
      await harness.start(requestId: 'k2', id: 'q2');

      expect(harness.fake.starts, hasLength(2));
    });

    test('a start that failed leaves the key free to retry', () async {
      final harness = StartHarness()
        ..fake.startError = const RemoteApiRefusal(
          ErrorCode.badRequest,
          'that folder is gone',
        );

      await harness.start();
      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);

      await harness.start(id: 'q2');

      expect(harness.last.type, FrameType.result);
      expect(harness.fake.starts, hasLength(1));
    });

    test('two frames racing on one key join the same launch', () async {
      final harness = StartHarness();
      final gate = Completer<void>();
      harness.fake.startGate = gate;

      final first = harness.start(id: 'q1');
      final second = harness.start(id: 'q2');
      harness.fake.startGate = null;
      gate.complete();
      await Future.wait([first, second]);

      expect(harness.fake.starts, hasLength(1));
      expect(harness.sent, hasLength(2));
      expect(harness.sent.map((f) => f.type), everyElement(FrameType.result));
    });

    test('the ledger forgets its oldest answers rather than growing', () async {
      final ledger = SessionStartLedger(capacity: 2);
      Future<RemoteSessionStarted> started(String id) async =>
          RemoteSessionStarted(sessionId: id, title: id);

      await ledger.once('a', () => started('a'));
      await ledger.once('b', () => started('b'));
      await ledger.once('c', () => started('c'));

      expect(ledger.holds('a'), isFalse);
      expect(ledger.holds('b'), isTrue);
      expect(ledger.holds('c'), isTrue);
    });
  });
}
