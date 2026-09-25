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

  test('the feed is new frame types, not a protocol bump', () {
    expect(kProtocolVersion, 1);
    expect(MessageType.watch.code, 0x17);
    expect(MessageType.watching.code, 0x18);
    expect(MessageType.lifecycle.code, 0x19);
  });

  test('watch carries its request id', () {
    expect(roundTrip(const WatchMessage(7)).requestId, 7);
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
}
