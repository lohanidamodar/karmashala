import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:test/test.dart';

/// One end of an in-memory link: what one side adds, the other receives.
class PipeEnd implements HostConnection {
  PipeEnd(this.description);

  static (PipeEnd, PipeEnd) pair() {
    final client = PipeEnd('client');
    final host = PipeEnd('host');
    client._peer = host;
    host._peer = client;
    return (client, host);
  }

  @override
  final String description;
  late final PipeEnd _peer;
  final _in = StreamController<Uint8List>();
  final _closed = Completer<void>();

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  void add(Uint8List bytes) {
    if (_peer._in.isClosed) throw StateError('StreamSink is closed');
    _peer._in.add(bytes);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    // Like a socket: hanging up ends both directions.
    for (final end in [_in, _peer._in]) {
      if (!end.isClosed) unawaited(end.close());
    }
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> get done => _closed.future;
}

Future<void> pump() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const request = PtySpawnRequest(argv: ['/bin/sh'], columns: 80, rows: 24);
final clock = DateTime.utc(2026, 9, 25, 10, 0);

HostServer serverFor(SessionRegistry registry) =>
    HostServer(registry: registry, ptyLibrary: 'libc.so.6', clock: () => clock);

Future<HostLifecycleWatch> watch(HostServer server) async {
  final (client, host) = PipeEnd.pair();
  unawaited(server.serveConnection(host));
  return HostLifecycleWatch.over(client, clientId: 'app');
}

void main() {
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late HostServer server;

  setUp(() {
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, clock: () => clock);
    server = serverFor(registry);
  });

  test('a watcher gets every session, then started and exited with the code '
      'the host collected', () async {
    registry.open('running', request);
    final done = registry.open('done', request);
    launcher.handles.last.finish(3);
    await done.ended;
    await pump();

    final feed = await watch(server);
    expect(feed.welcome.protocolVersion, kProtocolVersion);
    final byId = {for (final s in feed.snapshot) s.sessionId: s};
    expect(byId['running']!.state, HostSessionState.running);
    expect(byId['running']!.exitCode, isNull);
    expect(byId['running']!.startedAt, clock);
    expect(byId['done']!.state, HostSessionState.exited);
    expect(byId['done']!.exitCode, 3);
    expect(byId['done']!.reason, 'exited');

    final events = <LifecycleEvent>[];
    feed.events.listen(events.add);
    registry.open('new', request);
    final pid = launcher.handles.last.pid;
    launcher.handles.last.finish(0);
    await pump();

    expect(events.map((e) => (e.sessionId, e.kind)), [
      ('new', LifecycleEventKind.started),
      ('new', LifecycleEventKind.exited),
    ]);
    expect(events.first.pid, pid);
    expect(events.last.exitCode, 0, reason: 'a real zero is reported');
    expect(events.last.reason, 'exited');
    expect(events.last.observedAt, clock);
    await feed.close();
  });

  test('an end with no collectable code is reported with none', () async {
    final feed = await watch(server);
    final events = <LifecycleEvent>[];
    feed.events.listen(events.add);

    registry.open('lost', request);
    launcher.handles.last.finish(-1);
    await pump();

    final exited = events.last;
    expect(exited.kind, LifecycleEventKind.exited);
    expect(exited.exitCode, isNull, reason: 'never a fake zero');
    expect(exited.reason, contains('could not be reaped'));
    await feed.close();
  });

  test('a close on request reports the exit, then closed, once each', () async {
    final feed = await watch(server);
    final events = <LifecycleEvent>[];
    feed.events.listen(events.add);

    registry.open('pane', request);
    final closing = registry.close('pane');
    await pump();
    launcher.handles.last.finish(143);
    await closing;
    await pump();

    expect(events.map((e) => e.kind), [
      LifecycleEventKind.started,
      LifecycleEventKind.exited,
      LifecycleEventKind.closed,
    ]);
    expect(events[1].exitCode, 143);
    expect(events[2].exitCode, 143);
    expect(events[2].reason, 'closed on request');

    // A watcher arriving later still learns it was closed, not that it vanished.
    final later = await watch(server);
    final row = later.snapshot.single;
    expect(row.sessionId, 'pane');
    expect(row.state, HostSessionState.closed);
    expect(row.exitCode, 143);
    expect(row.reason, 'closed on request');

    // Reopening the id makes it a running session again, not a closed one.
    registry.open('pane', request);
    expect(server.lifecycle.snapshot().single.state, HostSessionState.running);
    await feed.close();
    await later.close();
  });

  test('a watcher that hangs up is unsubscribed and ends nothing', () async {
    registry.open('pane', request);
    final feed = await watch(server);
    await pump();
    expect(server.lifecycle.hasWatchers, isTrue);

    await feed.close();
    await pump();
    await feed.done;
    expect(server.lifecycle.hasWatchers, isFalse);
    expect(server.clientCount, 0);
    expect(registry.find('pane')!.lifecycle.hasEnded, isFalse);
  });

  test('a host restarted under a live session reports it exited, with no '
      'code and the reason why', () async {
    final root = Directory.systemTemp.createTempSync('karmashala-feed');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // A handle may still be held on Windows.
      }
    });
    SessionStore store() =>
        SessionStore(Directory('${root.path}/sessions'), capacityBytes: 4096)
          ..ensureDirectory();

    final first = SessionRegistry(launcher: launcher, store: store());
    first.open('pane', request);
    launcher.handles.last.emit(utf8.encode('halfway'));
    await pump();

    final restarted = serverFor(
      SessionRegistry(launcher: launcher, store: store()),
    );
    final feed = await watch(restarted);
    final row = feed.snapshot.single;
    expect(row.state, HostSessionState.exited);
    expect(row.exitCode, isNull);
    expect(row.reason, 'host stopped while running');
    expect(row.endedAt, isNotNull);
    await feed.close();
  });

  test('a host that predates the feed refuses watch, and the client says '
      'so', () async {
    final (client, host) = PipeEnd.pair();
    final parser = FrameParser();
    host.incoming.listen((bytes) {
      // What an older host does: welcome the hello, refuse the unknown type.
      final List<Frame> frames;
      try {
        frames = parser.add(bytes);
      } on FrameFormatException catch (e) {
        host.add(
          ErrorMessage(
            0,
            ProtocolErrorCode.badRequest,
            e.message,
          ).toFrame().encode(),
        );
        unawaited(host.close());
        return;
      }
      for (final frame in frames) {
        if (frame.type == MessageType.hello) {
          host.add(
            WelcomeMessage(
              requestId: 1,
              protocolVersion: 1,
              hostVersion: 'old',
              operatingSystem: 'linux',
              architecture: 'x64',
              ptyLibrary: 'libc.so.6',
              pid: 1,
              startedAt: clock,
              observedAt: clock,
            ).toFrame().encode(),
          );
        } else {
          host.add(
            ErrorMessage(
              0,
              ProtocolErrorCode.badRequest,
              'unknown message type 0x${frame.type.code.toRadixString(16)}',
            ).toFrame().encode(),
          );
        }
      }
    });

    await expectLater(
      HostLifecycleWatch.over(client),
      throwsA(
        isA<HostLifecycleWatchRefused>().having(
          (e) => e.message,
          'message',
          contains('0x17'),
        ),
      ),
    );
  });

  test('an event a newer host sends that this build cannot read is skipped, '
      'not fatal', () async {
    final (client, host) = PipeEnd.pair();
    final parser = FrameParser();
    host.incoming.listen((bytes) {
      for (final frame in parser.add(bytes)) {
        if (frame.type == MessageType.hello) {
          host.add(
            WelcomeMessage(
              requestId: 1,
              protocolVersion: 1,
              hostVersion: 'new',
              operatingSystem: 'linux',
              architecture: 'x64',
              ptyLibrary: 'libc.so.6',
              pid: 1,
              startedAt: clock,
              observedAt: clock,
            ).toFrame().encode(),
          );
        } else if (frame.type == MessageType.watch) {
          host
            ..add(
              WatchingMessage(
                requestId: 2,
                observedAt: clock,
                sessions: const [],
              ).toFrame().encode(),
            )
            ..add(
              Frame(
                MessageType.lifecycle,
                0,
                (WireWriter()..str(
                      jsonEncode({
                        'sessionId': 's',
                        'kind': 'paused',
                        'observedAt': '2026-09-25T10:00:00Z',
                      }),
                    ))
                    .take(),
              ).encode(),
            )
            ..add(
              LifecycleMessage(
                LifecycleEvent(
                  sessionId: 's',
                  kind: LifecycleEventKind.exited,
                  observedAt: clock,
                  exitCode: 1,
                  reason: 'exited',
                ),
              ).toFrame().encode(),
            );
        }
      }
    });

    final feed = await HostLifecycleWatch.over(client);
    final events = <LifecycleEvent>[];
    feed.events.listen(events.add);
    await pump();
    expect(events.single.exitCode, 1);
    await feed.close();
  });
}
