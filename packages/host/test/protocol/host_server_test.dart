import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// A connection with no operating system behind it, carrying bytes exactly as a
/// socket would.
class PipeConnection implements HostConnection {
  PipeConnection([this.description = 'test-client']);

  @override
  final String description;

  final _toServer = StreamController<Uint8List>();
  final _fromServer = <Frame>[];
  final _parser = FrameParser();
  final _closed = Completer<void>();
  var flushes = 0;

  /// Flushes wait for [releaseFlush], and `add` refuses meanwhile exactly as
  /// dart:io's sink does while it is bound to a flush.
  var holdFlushes = false;
  var failFlushes = false;
  Completer<void>? _flush;

  @override
  Stream<Uint8List> get incoming => _toServer.stream;

  @override
  void add(Uint8List bytes) {
    if (_flush != null) throw StateError('StreamSink is bound to a stream');
    _fromServer.addAll(_parser.add(bytes));
  }

  @override
  Future<void> flush() {
    flushes++;
    if (failFlushes) return Future.error(const SocketException('write failed'));
    if (!holdFlushes) return Future.value();
    return (_flush ??= Completer<void>()).future;
  }

  void releaseFlush() {
    final pending = _flush;
    _flush = null;
    pending?.complete();
  }

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> get done => _closed.future;

  /// Sends a message and lets the server work through it.
  Future<void> send(HostMessage message) async {
    _toServer.add(message.toFrame().encode());
    await pump();
  }

  Future<void> hangUp() async {
    await _toServer.close();
    await pump();
  }

  Future<void> pump() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<Frame> get received => _fromServer;
  List<HostMessage> get messages => _fromServer.map(decodeMessage).toList();
  T only<T extends HostMessage>() => messages.whereType<T>().single;
  T last<T extends HostMessage>() => messages.whereType<T>().last;
  Iterable<T> all<T extends HostMessage>() => messages.whereType<T>();
  void clear() => _fromServer.clear();
}

({HostServer server, SessionRegistry registry, FakePtyLauncher launcher})
build() {
  final launcher = FakePtyLauncher();
  final registry = SessionRegistry(
    launcher: launcher,
    backlogCapacityBytes: 4096,
    clock: () => DateTime.utc(2026, 9, 8, 14, 0),
  );
  return (
    server: HostServer(
      registry: registry,
      ptyLibrary: 'libc.so.6',
      clock: () => DateTime.utc(2026, 9, 8, 14, 0),
    ),
    registry: registry,
    launcher: launcher,
  );
}

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

const _open = OpenMessage(
  requestId: 2,
  sessionId: 'pane-a',
  argv: ['/bin/sh'],
  environment: {},
  columns: 80,
  rows: 24,
);

void main() {
  test('a client must say hello before anything else', () async {
    final env = build();
    final client = PipeConnection();
    unawaited(env.server.serveConnection(client));
    await client.send(const ListMessage(1));

    expect(client.only<ErrorMessage>().code, ProtocolErrorCode.helloRequired);
    expect(client.only<ErrorMessage>().message, contains('list'));
  });

  test(
    'a protocol mismatch is refused loudly and the connection ends',
    () async {
      final env = build();
      final client = PipeConnection();
      final serving = env.server.serveConnection(client);
      await client.send(
        const HelloMessage(requestId: 1, clientId: 'p', protocolVersion: 99),
      );

      final error = client.only<ErrorMessage>();
      expect(error.code, ProtocolErrorCode.protocolMismatch);
      expect(error.message, contains('host speaks protocol $kProtocolVersion'));
      expect(
        error.requestId,
        1,
        reason: 'the refusal answers the request that caused it',
      );
      await serving;
    },
  );

  test(
    'welcome reports the host, its pty library and when it looked',
    () async {
      final env = build();
      final client = PipeConnection();
      unawaited(env.server.serveConnection(client));
      await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));

      final welcome = client.only<WelcomeMessage>();
      expect(welcome.protocolVersion, kProtocolVersion);
      expect(welcome.hostVersion, kHostVersion);
      expect(welcome.ptyLibrary, 'libc.so.6');
      expect(welcome.observedAt, DateTime.utc(2026, 9, 8, 14, 0));
    },
  );

  test(
    'open starts a session, attaches it and hands over the write token',
    () async {
      final env = build();
      final client = PipeConnection();
      unawaited(env.server.serveConnection(client));
      await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await client.send(_open);

      expect(env.launcher.started.single.argv, ['/bin/sh']);
      final attached = client.only<AttachedMessage>();
      expect(attached.sessionId, 'pane-a');
      expect(attached.holdsWriteToken, isTrue);
      expect(attached.writeHolder, 'pane-1');
      expect(attached.replayFromOffset, 0);
    },
  );

  test('output arrives with absolute offsets that follow on', () async {
    final env = build();
    final client = PipeConnection();
    unawaited(env.server.serveConnection(client));
    await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
    await client.send(_open);
    final ref = client.only<AttachedMessage>().sessionRef;
    client.clear();

    env.launcher.handles.single.emit(ascii('hello '));
    env.launcher.handles.single.emit(ascii('world'));
    await client.pump();

    final chunks = client.all<OutputMessage>().toList();
    expect(chunks.map((c) => c.sessionRef).toSet(), {ref});
    expect(
      chunks.map((c) => String.fromCharCodes(c.bytes)).join(),
      'hello world',
    );
    expect(chunks.first.offset, 0);
    expect(chunks.last.nextOffset, 11);
  });

  test(
    'input reaches the pty; a client without the token is refused by name',
    () async {
      final env = build();
      final driver = PipeConnection('driver');
      final watcher = PipeConnection('watcher');
      unawaited(env.server.serveConnection(driver));
      unawaited(env.server.serveConnection(watcher));

      await driver.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await driver.send(_open);
      final driverRef = driver.only<AttachedMessage>().sessionRef;

      await watcher.send(const HelloMessage(requestId: 1, clientId: 'pane-2'));
      await watcher.send(
        const AttachMessage(
          requestId: 2,
          sessionId: 'pane-a',
          sinceOffset: 0,
          claimWrite: false,
        ),
      );
      final watcherRef = watcher.only<AttachedMessage>().sessionRef;

      await driver.send(InputMessage(driverRef, ascii('ls\n')));
      await watcher.send(InputMessage(watcherRef, ascii('rm -rf /\n')));

      expect(env.launcher.handles.single.writes.single, ascii('ls\n'));
      expect(watcher.only<AttachedMessage>().holdsWriteToken, isFalse);
      expect(watcher.only<AttachedMessage>().writeHolder, 'pane-1');
      final refusal = watcher.only<ErrorMessage>();
      expect(refusal.code, ProtocolErrorCode.writeRefused);
      expect(refusal.message, contains('write token held by pane-1'));
      expect(refusal.message, contains('claimed'));
    },
  );

  test('resize needs the token too, and moves the session geometry', () async {
    final env = build();
    final client = PipeConnection();
    unawaited(env.server.serveConnection(client));
    await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
    await client.send(_open);
    final ref = client.only<AttachedMessage>().sessionRef;

    await client.send(ResizeMessage(ref, 132, 43));

    expect(env.launcher.handles.single.resizes.single, (132, 43));
    expect(env.registry.require('pane-a').columns, 132);
  });

  test(
    'a disconnect frees the token and keeps every session running',
    () async {
      final env = build();
      final first = PipeConnection();
      final serving = env.server.serveConnection(first);
      await first.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await first.send(_open);

      await first.hangUp();
      await serving;

      expect(env.registry.find('pane-a'), isNotNull);
      expect(env.registry.require('pane-a').token.isHeld, isFalse);
      expect(env.launcher.handles.single.signals, isEmpty);
      expect(env.server.clientCount, 0);
    },
  );

  test(
    'reattaching with a since-offset replays exactly the missing bytes',
    () async {
      final env = build();
      final first = PipeConnection();
      final serving = env.server.serveConnection(first);
      await first.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await first.send(_open);
      env.launcher.handles.single.emit(ascii('before-'));
      await first.pump();
      final seenSoFar = first.all<OutputMessage>().last.nextOffset;
      await first.hangUp();
      await serving;

      env.launcher.handles.single.emit(ascii('while-away'));

      final second = PipeConnection();
      unawaited(env.server.serveConnection(second));
      await second.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await second.send(
        AttachMessage(
          requestId: 2,
          sessionId: 'pane-a',
          sinceOffset: seenSoFar,
          claimWrite: true,
        ),
      );

      final attached = second.only<AttachedMessage>();
      expect(attached.replayFromOffset, seenSoFar);
      expect(attached.droppedBytes, 0);
      expect(attached.totalBytes, 17);
      final replayed = second
          .all<OutputMessage>()
          .map((c) => String.fromCharCodes(c.bytes))
          .join();
      expect(replayed, 'while-away', reason: 'nothing repeated, nothing lost');
      expect(second.all<OutputMessage>().first.offset, seenSoFar);
    },
  );

  test(
    'an offset the ring has overwritten is reported, not silently skipped',
    () async {
      final env = build();
      final client = PipeConnection();
      unawaited(env.server.serveConnection(client));
      await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await client.send(_open);
      env.launcher.handles.single.emit(Uint8List(6000)..fillRange(0, 6000, 65));
      await client.pump();
      client.clear();

      await client.send(
        const AttachMessage(
          requestId: 3,
          sessionId: 'pane-a',
          sinceOffset: 0,
          claimWrite: false,
        ),
      );

      final attached = client.only<AttachedMessage>();
      expect(attached.droppedBytes, 6000 - 4096);
      expect(attached.replayFromOffset, 6000 - 4096);
      expect(attached.totalBytes, 6000);
    },
  );

  test(
    'the exit code reaches the client, and an unknown one stays unknown',
    () async {
      final env = build();
      final client = PipeConnection();
      unawaited(env.server.serveConnection(client));
      await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await client.send(_open);
      client.clear();

      env.launcher.handles.single.finish(42);
      await client.pump();

      final exited = client.only<ExitedMessage>();
      expect(exited.exitCode, 42);
      expect(exited.sessionId, 'pane-a');
    },
  );

  test(
    'attaching to a session that already ended still reports its code',
    () async {
      final env = build();
      final client = PipeConnection();
      unawaited(env.server.serveConnection(client));
      await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await client.send(_open);
      env.launcher.handles.single.finish(3);
      await client.pump();
      client.clear();

      await client.send(
        const AttachMessage(
          requestId: 4,
          sessionId: 'pane-a',
          sinceOffset: 0,
          claimWrite: false,
        ),
      );

      expect(client.only<ExitedMessage>().exitCode, 3);
    },
  );

  test('list reports every session with the time the host looked', () async {
    final env = build();
    final client = PipeConnection();
    unawaited(env.server.serveConnection(client));
    await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
    await client.send(_open);
    client.clear();

    await client.send(const ListMessage(7));

    final sessions = client.only<SessionsMessage>();
    expect(sessions.requestId, 7);
    expect(sessions.summaries.single.id, 'pane-a');
    expect(
      sessions.summaries.single.observedAt,
      DateTime.utc(2026, 9, 8, 14, 0),
    );
    expect(sessions.summaries.single.writeHolder, 'pane-1');
  });

  test('claim and release move the token between clients', () async {
    final env = build();
    final a = PipeConnection('a');
    final b = PipeConnection('b');
    unawaited(env.server.serveConnection(a));
    unawaited(env.server.serveConnection(b));
    await a.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
    await a.send(_open);
    final refA = a.only<AttachedMessage>().sessionRef;
    await b.send(const HelloMessage(requestId: 1, clientId: 'pane-2'));
    await b.send(
      const AttachMessage(
        requestId: 2,
        sessionId: 'pane-a',
        sinceOffset: 0,
        claimWrite: false,
      ),
    );
    final refB = b.only<AttachedMessage>().sessionRef;

    await b.send(ClaimMessage(5, refB));
    expect(b.only<ErrorMessage>().code, ProtocolErrorCode.writeRefused);

    await a.send(ReleaseMessage(6, refA));
    expect(a.last<ClaimedMessage>().holdsWriteToken, isFalse);

    await b.send(ClaimMessage(7, refB));
    expect(b.only<ClaimedMessage>().holdsWriteToken, isTrue);
    expect(env.registry.require('pane-a').token.isHeldBy('pane-2'), isTrue);
  });

  test('opening the same id twice is refused rather than shadowing', () async {
    final env = build();
    final client = PipeConnection();
    unawaited(env.server.serveConnection(client));
    await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
    await client.send(_open);
    client.clear();
    await client.send(_open);

    expect(client.only<ErrorMessage>().code, ProtocolErrorCode.sessionExists);
    expect(env.launcher.started, hasLength(1));
  });

  test('a spawn that fails is reported, not swallowed', () async {
    final env = build();
    env.launcher.failWith = const PtyException('openpty failed', errno: 24);
    final client = PipeConnection();
    unawaited(env.server.serveConnection(client));
    await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
    await client.send(_open);

    final error = client.only<ErrorMessage>();
    expect(error.code, ProtocolErrorCode.spawnFailed);
    expect(error.message, contains('errno 24'));
  });

  test('attaching to a session that does not exist says so', () async {
    final env = build();
    final client = PipeConnection();
    unawaited(env.server.serveConnection(client));
    await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
    await client.send(
      const AttachMessage(
        requestId: 2,
        sessionId: 'ghost',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );

    expect(client.only<ErrorMessage>().code, ProtocolErrorCode.unknownSession);
  });

  test('close ends the session on purpose and reports the code', () async {
    final env = build();
    final client = PipeConnection();
    unawaited(env.server.serveConnection(client));
    await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
    await client.send(_open);
    client.clear();

    final closing = client.send(const CloseMessage(8, 'pane-a'));
    await client.pump();
    env.launcher.handles.single.finish(0);
    await closing;
    await client.pump();

    expect(client.only<ClosedMessage>().exitCode, 0);
    expect(env.registry.find('pane-a'), isNull);
  });

  test(
    'a garbled frame ends the conversation instead of resynchronising',
    () async {
      final env = build();
      final client = PipeConnection();
      final serving = env.server.serveConnection(client);
      await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      client.clear();
      client._toServer.add(Uint8List.fromList([0x7f, 0, 0, 0, 0, 0, 0, 0]));
      await client.pump();
      await client.hangUp();
      await serving;

      expect(client.only<ErrorMessage>().code, ProtocolErrorCode.badRequest);
    },
  );

  test(
    'a string that is not UTF-8 is a bad request, and costs only that client',
    () async {
      final env = build();
      final client = PipeConnection();
      final serving = env.server.serveConnection(client);
      final payload =
          (WireWriter()
                ..u32(1)
                ..u32(kProtocolVersion)
                ..u32(2))
              .take();
      client._toServer.add(
        Frame(
          MessageType.hello,
          0,
          Uint8List.fromList([...payload, 0xff, 0xfe]),
        ).encode(),
      );
      await client.pump();
      await client.hangUp();
      await serving;

      expect(client.only<ErrorMessage>().code, ProtocolErrorCode.badRequest);

      final other = PipeConnection('other');
      unawaited(env.server.serveConnection(other));
      await other.send(const HelloMessage(requestId: 1, clientId: 'pane-2'));
      expect(other.only<WelcomeMessage>().protocolVersion, kProtocolVersion);
    },
  );

  test(
    'a fault while handling a frame answers that client and hangs it up',
    () async {
      final launcher = FakePtyLauncher(
        onStart: (_) => throw StateError('the launcher fell over'),
      );
      final server = HostServer(
        registry: SessionRegistry(launcher: launcher),
        ptyLibrary: 'libc.so.6',
      );
      final client = PipeConnection();
      final serving = server.serveConnection(client);
      await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await client.send(_open);
      await client.hangUp();
      await serving;

      final error = client.only<ErrorMessage>();
      expect(error.code, ProtocolErrorCode.internal);
      expect(error.message, contains('the launcher fell over'));
      expect(server.clientCount, 0);
    },
  );

  test('output is flushed in counted batches, never on a timer', () async {
    final env = build();
    final client = PipeConnection();
    unawaited(env.server.serveConnection(client));
    await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
    await client.send(_open);
    final before = client.flushes;

    for (var i = 0; i < 24; i++) {
      env.launcher.handles.single.emit(ascii('x'));
      await client.pump();
    }

    expect(client.flushes - before, 3, reason: '24 chunks, eight to a batch');
    expect(
      client.all<OutputMessage>().length,
      24,
      reason: 'and none dropped by the pause',
    );
  });

  test(
    'a message sent while a flush is in flight is held, not dropped',
    () async {
      final env = build();
      final client = PipeConnection()..holdFlushes = true;
      unawaited(env.server.serveConnection(client));
      await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await client.send(_open);
      client.clear();

      for (var i = 0; i < 8; i++) {
        env.launcher.handles.single.emit(ascii('x'));
      }
      await client.pump();
      expect(client.flushes, 1, reason: 'the eighth chunk opens the window');

      // Both land in the window: an exit and a request, the two shapes that were
      // being dropped and flagged as a hang-up.
      env.launcher.handles.single.finish(9);
      await client.send(const ListMessage(5));
      expect(client.all<ExitedMessage>(), isEmpty);
      expect(client.all<SessionsMessage>(), isEmpty);

      client.releaseFlush();
      await client.pump();

      expect(client.only<ExitedMessage>().exitCode, 9);
      expect(client.only<SessionsMessage>().requestId, 5);
      expect(
        env.server.clientCount,
        1,
        reason: 'the client was never flagged as gone',
      );
    },
  );

  test(
    'a flush that fails ends that client only; the host and its sessions go on',
    () async {
      final env = build();
      final client = PipeConnection()..failFlushes = true;
      final serving = env.server.serveConnection(client);
      await client.send(const HelloMessage(requestId: 1, clientId: 'pane-1'));
      await client.send(_open);

      for (var i = 0; i < 8; i++) {
        env.launcher.handles.single.emit(ascii('x'));
      }
      await client.pump();
      await client.hangUp();
      await serving;

      final other = PipeConnection('other');
      unawaited(env.server.serveConnection(other));
      await other.send(const HelloMessage(requestId: 1, clientId: 'pane-2'));
      await other.send(const ListMessage(2));

      expect(other.only<SessionsMessage>().summaries.single.id, 'pane-a');
      expect(env.launcher.handles.single.signals, isEmpty);
      expect(env.registry.require('pane-a').lifecycle, isA<SessionRunning>());
    },
  );
}
