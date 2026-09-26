import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_session/session.dart' show SessionStatus;
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    as engine;
import 'package:test/test.dart';

import 'pipe_connection.dart';

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
    expect(
      events[1].endedByClose,
      isTrue,
      reason: 'the exit a close caused says so, before closed does',
    );
    expect(events[2].exitCode, 143);
    expect(events[2].reason, 'closed on request');
    expect(events[2].endedByClose, isTrue);
    // What every watcher derives, at every step: never `failed`.
    expect(
      [
        for (final event in events)
          engine.lifecycleStatusFrom(
            SessionStatusRecording.eventOf(event).facts,
          ),
      ],
      [SessionStatus.running, SessionStatus.cancelled, SessionStatus.cancelled],
    );

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

  test('between the exit a close caused and closed, the snapshot row says '
      'the close ended it', () async {
    final session = registry.open('pane', request);
    final closing = registry.close('pane');
    await pump();
    expect(
      server.lifecycle.snapshot().single.endedByClose,
      isFalse,
      reason: 'still running while the signal is on its way',
    );
    launcher.handles.last.finish(143);
    await session.ended;
    final row = server.lifecycle.snapshot().single;
    expect(row.state, HostSessionState.exited);
    expect(row.endedByClose, isTrue);
    expect(
      engine.lifecycleStatusFrom(SessionStatusRecording.factsOf(row, clock)),
      SessionStatus.cancelled,
    );
    await closing;
  });

  test('an exit nobody asked for keeps its real code and status', () async {
    final feed = await watch(server);
    final events = <LifecycleEvent>[];
    feed.events.listen(events.add);

    registry.open('crash', request);
    launcher.handles.last.finish(143);
    await pump();
    registry.open('lost', request);
    launcher.handles.last.finish(-1);
    await pump();

    final exits = events
        .where((e) => e.kind == LifecycleEventKind.exited)
        .toList();
    expect(exits.map((e) => e.endedByClose), [isFalse, isFalse]);
    expect(
      [
        for (final e in exits)
          engine.lifecycleStatusFrom(SessionStatusRecording.eventOf(e).facts),
      ],
      [SessionStatus.failed, SessionStatus.unknown],
    );
    expect(
      server.lifecycle.snapshot().map((row) => row.endedByClose),
      everyElement(isFalse),
    );
    // A shutdown is the host stopping, not anybody closing a session.
    registry.open('stopping', request);
    final stopping = registry.shutdown();
    await pump();
    launcher.handles.last.finish(143);
    await stopping;
    await pump();
    expect(events.last.kind, LifecycleEventKind.exited);
    expect(events.last.endedByClose, isFalse);
    await feed.close();
  });

  // Found running the app: after a host crash, a pane lets go of the dead
  // session's record. That close ended nothing, and must not say it did.
  test('closing a session that had already ended says the close ended '
      'nothing, and keeps the end it had', () async {
    final feed = await watch(server);
    final events = <LifecycleEvent>[];
    feed.events.listen(events.add);

    registry.open('leftover', request);
    launcher.handles.last.finish(-1);
    await pump();
    await registry.close('leftover');
    await pump();

    final closed = events.last;
    expect(closed.kind, LifecycleEventKind.closed);
    expect(closed.endedByClose, isFalse);
    expect(
      events.where((e) => e.kind == LifecycleEventKind.exited).single,
      isA<LifecycleEvent>().having(
        (e) => e.endedByClose,
        'endedByClose',
        false,
      ),
    );
    expect(closed.exitCode, isNull);
    expect(closed.reason, isNot('closed on request'));

    final row = server.lifecycle.snapshot().single;
    expect(row.endedByClose, isFalse);
    await feed.close();
  });

  AgentHookEvent hook(String event, {String? pane, int second = 0}) =>
      AgentHookEvent(
        agent: 'claude-code',
        event: event,
        sessionHeader: pane,
        receivedAt: clock.add(Duration(seconds: second)),
        body: {'session_id': 'c-$event', 'hook_event_name': event},
      );

  test('a hook reaches a watching client as it arrives', () async {
    final feed = await watch(server);
    expect(feed.hookSnapshot, isEmpty);
    final hooks = <AgentHookEvent>[];
    feed.hooks.listen(hooks.add);

    server.lifecycle.relayHook(hook('Stop', pane: 'p1'));
    await pump();

    expect(hooks.single.event, 'Stop');
    expect(hooks.single.sessionHeader, 'p1');
    expect(hooks.single.body['session_id'], 'c-Stop');
    await feed.close();
  });

  test('the snapshot carries the latest hook per session, so a client that '
      'connects later catches up', () async {
    final hooks = server.lifecycle.hooks;
    hooks
      ..record(hook('UserPromptSubmit', pane: 'p1', second: 1))
      ..record(hook('Notification', pane: 'p2', second: 2))
      ..record(hook('Stop', pane: 'p1', second: 3))
      ..record(hook('SessionStart', second: 4));

    final feed = await watch(server);
    expect(feed.hookSnapshot.map((h) => (h.sessionHeader, h.event)), [
      ('p2', 'Notification'),
      ('p1', 'Stop'),
      (null, 'SessionStart'),
    ]);
    expect(feed.hookSnapshot[1].receivedAt, clock.add(Duration(seconds: 3)));
    await feed.close();
  });

  test('the hooks kept are bounded, the longest-quiet session going first', () {
    final hooks = RecentHooks(capacity: 2)
      ..record(hook('A', pane: 'p1'))
      ..record(hook('B', pane: 'p2'))
      ..record(hook('C', pane: 'p1'))
      ..record(hook('D', pane: 'p3'));
    expect(hooks.latest().map((h) => h.event), ['C', 'D']);
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
    SessionStore store() => SessionStore(
      Directory('${root.path}/sessions'),
      owner: '/data/this-server',
      capacityBytes: 4096,
    )..ensureDirectory();

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
