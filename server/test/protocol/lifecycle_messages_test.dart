import 'dart:convert';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

T roundTrip<T extends HostMessage>(T message) {
  final frames = FrameParser().add(message.toFrame().encode());
  expect(frames, hasLength(1));
  return decodeMessage(frames.single) as T;
}

/// A `lifecycle` frame carrying whatever JSON a host, old or new, might send.
Frame lifecycleFrame(Object? json) => Frame(
  MessageType.lifecycle,
  0,
  (WireWriter()..str(jsonEncode(json))).take(),
);

Frame watchingFrame(Object? json) => Frame(
  MessageType.watching,
  0,
  (WireWriter()
        ..u32(4)
        ..str(jsonEncode(json)))
      .take(),
);

void main() {
  final t0 = DateTime.utc(2026, 9, 25, 10, 0, 30);

  test('the feed\'s frame types, and the bump that reshaped `watch`', () {
    expect(kProtocolVersion, 10);
    expect(MessageType.watch.code, 0x17);
    expect(MessageType.watching.code, 0x18);
    expect(MessageType.lifecycle.code, 0x19);
    expect(MessageType.sessionChanged.code, 0x1c);
  });

  test('watch carries its request id and the sessions the client runs', () {
    final watch = roundTrip(const WatchMessage(7, runByClient: ['a', 'b.c']));
    expect(watch.requestId, 7);
    expect(watch.runByClient, ['a', 'b.c']);
    expect(roundTrip(const WatchMessage(8)).runByClient, isEmpty);
  });

  test('sessionChanged round-trips the row and the status written', () {
    final changed = roundTrip(
      const SessionChangedMessage(sessionId: 's.1', status: 'completed'),
    );
    expect(changed.sessionId, 's.1');
    expect(changed.status, 'completed');
  });

  test('each event kind round-trips with the facts it carries', () {
    final started = roundTrip(
      LifecycleMessage(
        LifecycleEvent(
          sessionId: 'karmashala_a',
          kind: LifecycleEventKind.started,
          observedAt: t0,
          pid: 4242,
        ),
      ),
    ).event;
    expect(started.kind, LifecycleEventKind.started);
    expect(started.pid, 4242);
    expect(started.observedAt, t0);
    expect(started.exitCode, isNull);

    final exited = roundTrip(
      LifecycleMessage(
        LifecycleEvent(
          sessionId: 'karmashala_a',
          kind: LifecycleEventKind.exited,
          observedAt: t0,
          exitCode: 0,
          reason: 'exited',
        ),
      ),
    ).event;
    expect(exited.exitCode, 0, reason: 'a real zero survives as a zero');
    expect(exited.reason, 'exited');
    expect(exited.endedByClose, isFalse);

    final exitedByClose = roundTrip(
      LifecycleMessage(
        LifecycleEvent(
          sessionId: 'karmashala_a',
          kind: LifecycleEventKind.exited,
          observedAt: t0,
          exitCode: 143,
          reason: 'exited',
          endedByClose: true,
        ),
      ),
    ).event;
    expect(exitedByClose.exitCode, 143);
    expect(
      exitedByClose.endedByClose,
      isTrue,
      reason: 'the exit a close caused says so on the wire',
    );

    final closed = roundTrip(
      LifecycleMessage(
        LifecycleEvent(
          sessionId: 'karmashala_a',
          kind: LifecycleEventKind.closed,
          observedAt: t0,
          reason: 'closed on request',
        ),
      ),
    ).event;
    expect(closed.kind, LifecycleEventKind.closed);
    expect(closed.exitCode, isNull, reason: 'unknown stays unknown, never 0');
  });

  test('an event with no code carries no exitCode field at all', () {
    final json = LifecycleEvent(
      sessionId: 's',
      kind: LifecycleEventKind.exited,
      observedAt: t0,
      reason: SessionEndedWithoutCode.hostStoppedWhileRunning,
    ).toJson();
    expect(json.containsKey('exitCode'), isFalse);
    expect(json['observedAt'], '2026-09-25T10:00:30.000Z');
  });

  test('the snapshot round-trips every state', () {
    final decoded = roundTrip(
      WatchingMessage(
        requestId: 3,
        observedAt: t0,
        sessions: [
          HostSessionFacts(
            sessionId: 'a',
            state: HostSessionState.running,
            startedAt: t0,
          ),
          HostSessionFacts(
            sessionId: 'b',
            state: HostSessionState.exited,
            reason: SessionEndedWithoutCode.hostStoppedWhileRunning,
            startedAt: t0,
            endedAt: t0,
          ),
          const HostSessionFacts(
            sessionId: 'c',
            state: HostSessionState.closed,
            exitCode: 143,
            reason: 'closed on request',
          ),
        ],
      ),
    );
    expect(decoded.requestId, 3);
    expect(decoded.observedAt, t0);
    expect(decoded.sessions.map((s) => s.state), [
      HostSessionState.running,
      HostSessionState.exited,
      HostSessionState.closed,
    ]);
    expect(decoded.sessions[0].exitCode, isNull);
    expect(decoded.sessions[1].exitCode, isNull);
    expect(decoded.sessions[1].endedAt, t0);
    expect(decoded.sessions[2].exitCode, 143);
    expect(decoded.sessions[2].startedAt, isNull);
    expect(decoded.hooks, isEmpty);
  });

  test('a hook round-trips with its body, alone and in the snapshot', () {
    expect(MessageType.hook.code, 0x1a);
    final hook = AgentHookEvent(
      agent: 'claude-code',
      event: 'Stop',
      sessionHeader: 'pane-1',
      receivedAt: t0,
      body: const {
        'session_id': 'c1',
        'nested': {
          'list': [1, 2],
        },
      },
    );
    final alone = roundTrip(HookMessage(hook)).hook;
    expect(alone.agent, 'claude-code');
    expect(alone.event, 'Stop');
    expect(alone.sessionHeader, 'pane-1');
    expect(alone.receivedAt, t0);
    expect(alone.body, hook.body);
    expect(alone.holdId, isNull);
    expect(hook.toJson().containsKey('holdId'), isFalse);

    final unnamed = AgentHookEvent(
      agent: 'codex',
      event: 'Stop',
      receivedAt: t0,
      body: const {},
    );
    expect(unnamed.toJson().containsKey('sessionHeader'), isFalse);
    final snapshot = roundTrip(
      WatchingMessage(
        requestId: 1,
        observedAt: t0,
        sessions: const [],
        hooks: [hook, unnamed],
      ),
    );
    expect(snapshot.hooks.map((h) => (h.agent, h.sessionHeader)), [
      ('claude-code', 'pane-1'),
      ('codex', null),
    ]);
  });

  group('tolerant parsing', () {
    test('fields a newer host adds are ignored', () {
      final message =
          decodeMessage(
                lifecycleFrame({
                  'sessionId': 's',
                  'kind': 'exited',
                  'observedAt': '2026-09-25T10:00:30Z',
                  'exitCode': 2,
                  'cpuSeconds': 12.5,
                  'nested': {'x': 1},
                }),
              )
              as LifecycleMessage;
      expect(message.event.exitCode, 2);
    });

    test('a snapshot row in a state this build does not know is dropped', () {
      final message =
          decodeMessage(
                watchingFrame({
                  'observedAt': '2026-09-25T10:00:30Z',
                  'sessions': [
                    {'sessionId': 'a', 'state': 'running'},
                    {'sessionId': 'b', 'state': 'hibernating'},
                  ],
                  'hooks': [],
                  'hostNote': 'ignored',
                }),
              )
              as WatchingMessage;
      expect(message.sessions.map((s) => s.sessionId), ['a']);
    });

    test('an unknown event kind is a format error the client can skip', () {
      expect(
        () => decodeMessage(
          lifecycleFrame({
            'sessionId': 's',
            'kind': 'paused',
            'observedAt': '2026-09-25T10:00:30Z',
          }),
        ),
        throwsA(isA<WireFormatException>()),
      );
    });

    for (final (what, json) in <(String, Object?)>[
      ('not an object', [1, 2]),
      ('no session id', {'kind': 'started', 'observedAt': '2026-09-25T10:00Z'}),
      ('no time', {'sessionId': 's', 'kind': 'started'}),
      (
        'a time that is not one',
        {'sessionId': 's', 'kind': 'started', 'observedAt': 'yesterday'},
      ),
      (
        'an exit code that is not an int',
        {
          'sessionId': 's',
          'kind': 'exited',
          'observedAt': '2026-09-25T10:00Z',
          'exitCode': '0',
        },
      ),
    ]) {
      test('an event with $what is malformed', () {
        expect(
          () => decodeMessage(lifecycleFrame(json)),
          throwsA(isA<WireFormatException>()),
        );
      });
    }

    test('a payload that is not JSON is malformed', () {
      final frame = Frame(
        MessageType.lifecycle,
        0,
        (WireWriter()..str('{not json')).take(),
      );
      expect(() => decodeMessage(frame), throwsA(isA<WireFormatException>()));
    });

    test('a snapshot without its session list is malformed', () {
      expect(
        () => decodeMessage(watchingFrame({'observedAt': '2026-09-25T10:00Z'})),
        throwsA(isA<WireFormatException>()),
      );
    });
  });

  test('a held hook carries its hold id, and the reply names it', () {
    expect(MessageType.hookReply.code, 0x1b);
    final held = AgentHookEvent(
      agent: 'claude-code',
      event: 'PreToolUse',
      receivedAt: t0,
      body: const {},
    ).heldAs(42);
    expect(roundTrip(HookMessage(held)).hook.holdId, 42);
    expect(held.unheld.holdId, isNull);
    expect(roundTrip(const HookReplyMessage(42)).holdId, 42);
  });
}
