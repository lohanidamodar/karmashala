import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:test/test.dart';

/// A host that answers from a script, frame by frame.
class _Channel implements RemoteChannel {
  _Channel(this.answer);

  final List<HostMessage> Function(HostMessage message) answer;
  final _out = StreamController<Uint8List>();
  final _parser = FrameParser();
  final sent = <HostMessage>[];

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void add(Uint8List bytes) {
    for (final frame in _parser.add(bytes)) {
      final message = decodeMessage(frame);
      sent.add(message);
      // All of one reply in one chunk, as a socket may deliver it.
      final reply = BytesBuilder();
      for (final m in answer(message)) {
        reply.add(m.toFrame().encode());
      }
      if (reply.isNotEmpty) _out.add(reply.takeBytes());
    }
  }

  void push(HostMessage message) => _out.add(message.toFrame().encode());

  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }
}

WelcomeMessage _welcome(int id, {int version = kProtocolVersion}) =>
    WelcomeMessage(
      requestId: id,
      protocolVersion: version,
      hostVersion: '1',
      operatingSystem: 'linux',
      architecture: 'x64',
      ptyLibrary: 'libc',
      pid: 1,
      startedAt: DateTime.utc(2026),
      observedAt: DateTime.utc(2026),
    );

void main() {
  var nextRef = 0;
  List<HostMessage> host(HostMessage message) => switch (message) {
    HelloMessage(:final requestId) => [_welcome(requestId)],
    AttachMessage(:final requestId, :final sessionId) => () {
      final ref = ++nextRef;
      return [
        AttachedMessage(
          requestId: requestId,
          sessionRef: ref,
          sessionId: sessionId,
          columns: 80,
          rows: 24,
          replayFromOffset: 0,
          droppedBytes: 0,
          totalBytes: 2,
          holdsWriteToken: true,
          writeHolder: 'me',
          observedAt: DateTime.utc(2026),
        ),
        // In the same chunk as the answer: the ref must already be open.
        OutputMessage(ref, 0, Uint8List.fromList(sessionId.codeUnits)),
      ];
    }(),
    _ => const [],
  };

  setUp(() => nextRef = 0);

  test('one hello, then each attachment\'s frames by its own ref — output '
      'in the answer\'s chunk included', () async {
    final channel = _Channel(host);
    final link = await HostClientLink.open(channel, clientId: 'me');
    expect(channel.sent.whereType<HelloMessage>().single.ackingOutput, isTrue);

    Future<AttachedMessage> attach(String id) => link.request(
      (rid) => AttachMessage(
        requestId: rid,
        sessionId: id,
        sinceOffset: 0,
        claimWrite: true,
      ),
      const Duration(seconds: 5),
    );
    final a = await attach('aa');
    final b = await attach('bb');
    final fromA = await link.framesFor(a.sessionRef).first as OutputMessage;
    final onB = StreamIterator(link.framesFor(b.sessionRef));
    expect(await onB.moveNext(), isTrue);
    expect(String.fromCharCodes(fromA.bytes), 'aa');
    expect(String.fromCharCodes((onB.current as OutputMessage).bytes), 'bb');

    // A refusal on one ref reaches that ref alone.
    channel.push(
      ErrorMessage(
        0,
        ProtocolErrorCode.writeRefused,
        'held by laptop',
        sessionRef: b.sessionRef,
      ),
    );
    expect(await onB.moveNext(), isTrue);
    expect((onB.current as ErrorMessage).message, 'held by laptop');
    await onB.cancel();
    await link.close();
  });

  test('frames for no request and no ref are on messages; a detached ref '
      'is let go at the host', () async {
    final channel = _Channel(host);
    final link = await HostClientLink.open(channel, clientId: 'me');
    final seen = <HostMessage>[];
    link.messages.listen(seen.add);
    channel.push(
      const DataChangesMessage({'revision': 1, 'changes': <Object?>[]}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(seen.single, isA<DataChangesMessage>());

    final a = await link.request<AttachedMessage>(
      (rid) => AttachMessage(
        requestId: rid,
        sessionId: 'x',
        sinceOffset: 0,
        claimWrite: false,
      ),
      null,
    );
    link.detach(a.sessionRef);
    expect(channel.sent.whereType<DetachMessage>().single.sessionRef, 1);
    await link.close();
  });

  test('another protocol is refused, and the channel closes', () async {
    final channel = _Channel(
      (m) => m is HelloMessage ? [_welcome(m.requestId, version: 3)] : [],
    );
    await expectLater(
      HostClientLink.open(channel, clientId: 'me'),
      throwsA(
        isA<HostLinkException>().having(
          (e) => e.code,
          'code',
          ProtocolErrorCode.protocolMismatch,
        ),
      ),
    );
  });

  test('the channel closing fails what is waiting and ends every ref',
      () async {
    final channel = _Channel(
      (m) => m is HelloMessage ? [_welcome(m.requestId)] : const [],
    );
    final link = await HostClientLink.open(channel, clientId: 'me');
    final waiting = link.request<SessionsMessage>(ListMessage.new, null);
    await channel.close();
    await expectLater(waiting, throwsA(isA<HostLinkException>()));
    await link.done;
    expect(link.isClosed, isTrue);
  });
}
