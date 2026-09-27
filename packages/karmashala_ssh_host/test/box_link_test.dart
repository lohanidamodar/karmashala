import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_ssh_host/host.dart';
import 'package:test/test.dart';

final _at = DateTime.utc(2026, 9, 27, 12);

/// A box host answering over a channel, one scripted frame at a time.
class _ScriptedBox implements RemoteChannel {
  _ScriptedBox({this.protocol = kProtocolVersion});

  final int protocol;
  final _out = StreamController<Uint8List>();
  final _parser = FrameParser();
  final received = <HostMessage>[];

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  void say(HostMessage message) => _out.add(message.toFrame().encode());

  @override
  void add(Uint8List bytes) {
    for (final frame in _parser.add(bytes)) {
      final message = decodeMessage(frame);
      received.add(message);
      switch (message) {
        case HelloMessage(:final requestId):
          say(
            WelcomeMessage(
              requestId: requestId,
              protocolVersion: protocol,
              hostVersion: '0.1.0',
              operatingSystem: 'linux',
              architecture: 'x64',
              ptyLibrary: 'libc.so.6',
              pid: 42,
              startedAt: _at,
              observedAt: _at,
            ),
          );
        case AttachMessage(:final requestId, :final sessionId):
          // The answer and the first output in one breath, as a host sends
          // them: the output must not be lost to the attachment's setup.
          say(
            AttachedMessage(
              requestId: requestId,
              sessionRef: 5,
              sessionId: sessionId,
              columns: 80,
              rows: 24,
              replayFromOffset: 0,
              droppedBytes: 0,
              totalBytes: 2,
              holdsWriteToken: true,
              writeHolder: 'karmashala-server',
              observedAt: _at,
            ),
          );
          say(OutputMessage(5, 0, Uint8List.fromList([0x68, 0x69])));
        case ListMessage(:final requestId):
          say(SessionsMessage(requestId, const []));
        default:
          break;
      }
    }
  }

  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }
}

/// The client side of the server's one link to a box's host (slice 5d):
/// greeted, an attachment's frames routed to it by the box's ref from the
/// first byte, a detach told to the box, and a link that drops ending every
/// attachment and failing what waits — never a hang.
void main() {
  test('an attachment gets every frame for its ref, from the first', () async {
    final box = _ScriptedBox();
    final link = await BoxLink.connect(box, hostId: 'h1');
    expect(link.welcome.pid, 42);
    final route = await link.attach(sessionId: 'karmashala_local_p1');
    expect(route.attached.sessionRef, 5);
    final first = await route.frames.first;
    expect((first as OutputMessage).bytes, [0x68, 0x69]);
    await link.close();
  });

  test('typing, resizing and detaching are told to the box by its ref',
      () async {
    final box = _ScriptedBox();
    final link = await BoxLink.connect(box, hostId: 'h1');
    final route = await link.attach(sessionId: 'karmashala_local_p1');
    route
      ..input(Uint8List.fromList([0x61]))
      ..resize(100, 30)
      ..detach();
    await Future<void>.delayed(Duration.zero);
    expect(box.received.whereType<InputMessage>().single.sessionRef, 5);
    expect(box.received.whereType<ResizeMessage>().single.columns, 100);
    expect(box.received.whereType<DetachMessage>().single.sessionRef, 5);
    await link.close();
  });

  test('a host of another protocol is refused in words', () async {
    await expectLater(
      BoxLink.connect(_ScriptedBox(protocol: 1), hostId: 'h1'),
      throwsA(
        isA<BoxLinkException>().having(
          (e) => e.message,
          'message',
          contains('protocol 1'),
        ),
      ),
    );
  });

  test('a link that drops ends every attachment and fails what waits',
      () async {
    final box = _ScriptedBox();
    final link = await BoxLink.connect(box, hostId: 'h1');
    final route = await link.attach(sessionId: 'karmashala_local_p1');
    final ended = route.frames.drain<void>();
    await box.close();
    await ended;
    expect(await link.closed, contains('closed'));
    await expectLater(link.list(), throwsA(isA<BoxLinkException>()));
  });
}
