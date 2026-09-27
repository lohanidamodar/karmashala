import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

import '../../serve/pipe_connection.dart';
import '../support/box_world.dart';

/// A client of this server, speaking the host protocol over a pipe.
class _Client {
  _Client(HostServer server, this.id) {
    final (client, served) = PipeEnd.pair();
    _end = client;
    unawaited(server.serveConnection(served));
    _end.incoming.listen(
      (chunk) => messages.addAll(_parser.add(chunk).map(decodeMessage)),
      onDone: () => hungUp = true,
    );
  }

  final String id;
  late final PipeEnd _end;
  final _parser = FrameParser();
  final messages = <HostMessage>[];
  var hungUp = false;
  var _requests = 0;

  void send(HostMessage message) => _end.add(message.toFrame().encode());

  Future<T> ask<T extends HostMessage>(
    HostMessage Function(int id) build,
  ) async {
    final id = ++_requests;
    send(build(id));
    T? found;
    await until(() {
      for (final m in messages) {
        final answered = switch (m) {
          ErrorMessage(:final requestId) => requestId == id,
          AttachedMessage(:final requestId) => requestId == id,
          ClosedMessage(:final requestId) => requestId == id,
          WelcomeMessage(:final requestId) => requestId == id,
          ClaimedMessage(:final requestId) => requestId == id,
          _ => false,
        };
        if (answered) {
          if (m is ErrorMessage) throw StateError(m.message);
          found = m as T;
          return true;
        }
      }
      return false;
    });
    return found ?? (throw StateError('no answer to request $id'));
  }

  Future<void> hello() => ask<WelcomeMessage>(
    (id) => HelloMessage(requestId: id, clientId: this.id),
  );

  String textOf(int ref) => utf8.decode([
    for (final m in messages)
      if (m is OutputMessage && m.sessionRef == ref) ...m.bytes,
  ], allowMalformed: true);

  Future<void> close() => _end.close();
}

/// **The frame relay** (slice 5d): a client attaches to a box's session at
/// its own server — `ssh:<hostId>/<id>`, or the session's own id — and is
/// relayed the box host's frames under its own ref; what it types reaches
/// the box; the one-writer rule is the server's; a close ends the session at
/// the box; a detach stops only that stream; and a link to the box that
/// drops hangs the client up so its pane dials again.
void main() {
  late BoxWorld world;
  late HostServer local;

  setUp(() async {
    world = BoxWorld();
    local = HostServer(
      registry: SessionRegistry(launcher: FakePtyLauncher()),
      ptyLibrary: 'fake',
    )..boxes = world.ssh.relay;
    await world.ssh.remote.open(
      world.environment,
      sessionId: 'karmashala_local_p1',
      columns: 80,
      rows: 24,
    );
  });
  tearDown(() => world.close());

  test('the box\'s output reaches the client under its own ref, and what '
      'it types reaches the box', () async {
    final client = _Client(local, 'window-a');
    addTearDown(client.close);
    await client.hello();
    final attached = await client.ask<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: 'ssh:h1/karmashala_local_p1',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    expect(attached.sessionId, 'ssh:h1/karmashala_local_p1');
    expect(attached.holdsWriteToken, isTrue);

    final pty = world.box.ptys.single;
    pty.emit(utf8.encode('from the box\r\n'));
    await until(
      () => client.textOf(attached.sessionRef).contains('from the box'),
    );
    expect(client.textOf(attached.sessionRef), contains('from the box'));

    client.send(
      InputMessage(attached.sessionRef, Uint8List.fromList([0x6c, 0x73])),
    );
    await until(() => pty.writes.isNotEmpty);
    expect(utf8.decode(pty.writes.expand((w) => w).toList()), 'ls');

    client.send(ResizeMessage(attached.sessionRef, 120, 40));
    await until(() => pty.resizes.contains((120, 40)));
    expect(pty.resizes, contains((120, 40)));
  });

  test('a session the server started under its own id is found by that id '
      'too', () async {
    final client = _Client(local, 'window-a');
    addTearDown(client.close);
    await client.hello();
    final attached = await client.ask<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: 'karmashala_local_p1',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    expect(attached.sessionId, 'karmashala_local_p1');
  });

  test('the exit is the box\'s, relayed with its code', () async {
    final client = _Client(local, 'window-a');
    addTearDown(client.close);
    await client.hello();
    final attached = await client.ask<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: 'ssh:h1/karmashala_local_p1',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    world.box.ptys.single.finish(7);
    await until(() => client.messages.any((m) => m is ExitedMessage));
    final exited = client.messages.whereType<ExitedMessage>().single;
    expect(exited.sessionRef, attached.sessionRef);
    expect(exited.sessionId, 'ssh:h1/karmashala_local_p1');
    expect(exited.exitCode, 7);
  });

  test('one window drives; another is refused until it claims', () async {
    final a = _Client(local, 'window-a');
    final b = _Client(local, 'window-b');
    addTearDown(a.close);
    addTearDown(b.close);
    await a.hello();
    await b.hello();
    await a.ask<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: 'ssh:h1/karmashala_local_p1',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    final second = await b.ask<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: 'ssh:h1/karmashala_local_p1',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    expect(second.holdsWriteToken, isFalse);
    expect(second.writeHolder, 'window-a');
    b.send(InputMessage(second.sessionRef, Uint8List.fromList([0x78])));
    await until(
      () => b.messages.any(
        (m) => m is ErrorMessage && m.code == ProtocolErrorCode.writeRefused,
      ),
    );
    expect(world.box.ptys.single.writes, isEmpty);
    // Window A goes: its write right goes with it.
    await a.close();
    await settle();
    final claimed = await b.ask<ClaimedMessage>(
      (id) => ClaimMessage(id, second.sessionRef),
    );
    expect(claimed.holdsWriteToken, isTrue);
  });

  test('a close ends the session at the box', () async {
    final client = _Client(local, 'window-a');
    addTearDown(client.close);
    await client.hello();
    final pty = world.box.ptys.single;
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 20),
        () => pty.finish(143),
      ),
    );
    final closed = await client.ask<ClosedMessage>(
      (id) => CloseMessage(id, 'ssh:h1/karmashala_local_p1'),
    );
    expect(closed.sessionId, 'ssh:h1/karmashala_local_p1');
    expect(pty.signals, contains(15));
  });

  test('a detach stops that stream only; the session goes on', () async {
    final client = _Client(local, 'window-a');
    addTearDown(client.close);
    await client.hello();
    final attached = await client.ask<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: 'ssh:h1/karmashala_local_p1',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    client.send(DetachMessage(attached.sessionRef));
    await settle();
    world.box.ptys.single.emit(utf8.encode('after the detach\r\n'));
    await settle(40);
    expect(client.textOf(attached.sessionRef), isNot(contains('after')));
    expect(client.hungUp, isFalse);
    expect(
      world.box.registry.find('karmashala_local_p1')!.lifecycle.hasEnded,
      isFalse,
    );
  });

  test('the link to the box dropping hangs the client up, so its pane dials '
      'again', () async {
    final client = _Client(local, 'window-a');
    await client.hello();
    await client.ask<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: 'ssh:h1/karmashala_local_p1',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    await world.box.dropLinks();
    await until(() => client.hungUp);
    expect(client.hungUp, isTrue);
  });

  test('a session no box holds is unknown, in the host\'s own code', () async {
    final client = _Client(local, 'window-a');
    addTearDown(client.close);
    await client.hello();
    await expectLater(
      client.ask<AttachedMessage>(
        (id) => AttachMessage(
          requestId: id,
          sessionId: 'ssh:h1/karmashala_local_nobody',
          sinceOffset: 0,
          claimWrite: true,
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
