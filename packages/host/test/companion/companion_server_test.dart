import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// Both ends of one link, so a test can be the phone. A [RemoteTransport] and
/// not a socket: that is the layer `serve` works at, and the layer a
/// `SealedChannel` or a `LanLink` would arrive as.
class _Pipe implements RemoteTransport {
  final _toHost = StreamController<Uint8List>();
  final fromHost = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get frames => _toHost.stream;

  @override
  void send(List<int> frame) => fromHost.add(Uint8List.fromList(frame));

  @override
  Stream<TransportState> get states => const Stream<TransportState>.empty();

  @override
  TransportState get state => TransportState.connected;

  @override
  bool get isConnected => true;

  @override
  Future<void> close() async {
    await _toHost.close();
    await fromHost.close();
  }

  void sendToHost(Envelope envelope) => _toHost.add(envelope.toBytes());

  /// A frame that is not an envelope at all.
  void sendRaw(Uint8List payload) => _toHost.add(payload);
}

void main() {
  late _Pipe pipe;
  late SessionRegistry registry;
  late List<Envelope> answers;
  late StreamSubscription<Uint8List> reader;

  setUp(() {
    pipe = _Pipe();
    registry = SessionRegistry(launcher: FakePtyLauncher());
    answers = [];
    reader = pipe.fromHost.stream.listen(
      (frame) => answers.add(Envelope.fromBytes(frame)),
    );

    unawaited(
      CompanionServer(
        registry: registry,
        hostName: 'do-box',
        clientId: 'ssh-1',
      ).serve(pipe),
    );
  });

  tearDown(() async {
    await reader.cancel();
    await pipe.close();
  });

  /// The phone's half: one request, wait for the frame that carries its id.
  Future<Envelope> ask(
    FrameType type, {
    Map<String, Object?> payload = const {},
  }) async {
    pipe.sendToHost(Envelope.of(type, seq: 1, id: 'r1', payload: payload));
    return Future.doWhile(() async {
          await Future<void>.delayed(Duration.zero);
          return !answers.any((e) => e.id == 'r1');
        })
        .then((_) => answers.firstWhere((e) => e.id == 'r1'))
        .timeout(const Duration(seconds: 5));
  }

  test('a host with no sessions answers an empty list, not silence', () async {
    final answer = await ask(FrameType.sessionsList);

    expect(answer.type, FrameType.result.wire);
    expect(answer.payload['sessions'], isEmpty);
  });

  test('the sessions this machine owns reach the phone', () async {
    registry.open(
      'karmashala_live',
      const PtySpawnRequest(
        argv: ['claude', '--resume'],
        workingDirectory: '/srv/app',
        environment: {},
        columns: 80,
        rows: 24,
      ),
    );

    final answer = await ask(FrameType.sessionsList);

    final sessions = (answer.payload['sessions']! as List)
        .cast<Map<String, Object?>>();
    expect(sessions, hasLength(1));
    expect(sessions.single['sessionId'], 'karmashala_live');
    // The command is the only name this machine has for the session.
    expect(sessions.single['title'], 'claude --resume');
    expect(sessions.single['status'], 'running');
    expect(
      sessions.single['whereabouts'],
      'on do-box',
      reason: 'which box, not which folder',
    );
  });

  test('what a host cannot answer is refused by name, never faked', () async {
    // The session has to exist, or the api refuses with "no such session"
    // before it ever reaches the binding — which is the right order, and worth
    // pinning: a refusal must name the thing the host cannot do, not an absence
    // it invented. An empty transcript would render as a session with nothing
    // in it, a confident false statement about somebody's work (§19).
    registry.open(
      'karmashala_live',
      const PtySpawnRequest(
        argv: ['claude'],
        workingDirectory: '/srv/app',
        environment: {},
        columns: 80,
        rows: 24,
      ),
    );

    final answer = await ask(
      FrameType.transcriptGet,
      payload: {'sessionId': 'karmashala_live'},
    );

    expect(answer.type, FrameType.error.wire);
    expect(answer.payload['code'], ErrorCode.unknownType.wire);
    expect(answer.payload['message'], contains('transcript'));
  });

  test(
    'a session the host does not have is refused before any binding',
    () async {
      final answer = await ask(
        FrameType.transcriptGet,
        payload: {'sessionId': 'never-started'},
      );

      expect(answer.type, FrameType.error.wire);
      expect(answer.payload['message'], contains('no such session'));
    },
  );

  test('a phone paired with less is granted less', () async {
    // The grant travels with the paired device, the same way it does on the
    // desktop — this host is a peer a phone pairs with, not a machine behind
    // one. Pinned rather than assumed, because the default is everything while
    // nothing can pair yet.
    final viewOnly = _Pipe();
    final seen = <Envelope>[];
    final sub = viewOnly.fromHost.stream.listen(
      (frame) => seen.add(Envelope.fromBytes(frame)),
    );
    addTearDown(() async {
      await sub.cancel();
      await viewOnly.close();
    });

    unawaited(
      CompanionServer(
        registry: registry,
        hostName: 'do-box',
        clientId: 'pixel-7',
        capabilities: CapabilitySet.of([Capability.viewSessions]),
      ).serve(viewOnly),
    );

    viewOnly.sendToHost(Envelope.of(FrameType.sessionsList, seq: 1, id: 'a'));
    viewOnly.sendToHost(
      Envelope.of(
        FrameType.transcriptGet,
        seq: 2,
        id: 'b',
        payload: {'sessionId': 'karmashala_live'},
      ),
    );
    await Future.doWhile(() async {
      await Future<void>.delayed(Duration.zero);
      return seen.length < 2;
    }).timeout(const Duration(seconds: 5));

    expect(seen.firstWhere((e) => e.id == 'a').type, FrameType.result.wire);
    final refused = seen.firstWhere((e) => e.id == 'b');
    expect(refused.type, FrameType.error.wire);
    expect(refused.payload['code'], ErrorCode.notPermitted.wire);
  });

  test('a frame this build cannot decode is answered, not dropped', () async {
    pipe.sendRaw(Uint8List.fromList('{not json'.codeUnits));

    await Future.doWhile(() async {
      await Future<void>.delayed(Duration.zero);
      return !answers.any((e) => e.type == FrameType.error.wire);
    }).timeout(const Duration(seconds: 5));

    expect(
      answers.last.payload['code'],
      ErrorCode.badRequest.wire,
      reason: 'silence is indistinguishable from a host that stopped reading',
    );
  });
}
