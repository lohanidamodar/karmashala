import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

/// A store that only remembers what it was asked; [refuse] makes `open` throw
/// the way a disk that will not take a file does.
class _RecordingStore implements SessionBacklogStore {
  _RecordingStore({this.refuse = false});
  final bool refuse;
  final opened = <String>[];
  final forgotten = <String>[];
  final records = <_Record>[];

  @override
  SessionRecorder open(String id, PtySpawnRequest request, DateTime startedAt) {
    if (refuse) throw StateError('no room for a record');
    opened.add(id);
    final record = _Record();
    records.add(record);
    return record;
  }

  @override
  List<RestoredSession> restore() => const [];

  @override
  void forget(String id) => forgotten.add(id);
}

class _Record implements SessionRecorder {
  var closed = false;
  @override
  void record(Uint8List bytes) {}
  @override
  void ended(SessionLifecycle lifecycle) {}
  @override
  void close() => closed = true;
}

({SessionRegistry registry, FakePtyLauncher launcher}) build({int capacity = 64}) {
  final launcher = FakePtyLauncher();
  return (
    registry: SessionRegistry(
      launcher: launcher,
      backlogCapacityBytes: capacity,
      clock: () => DateTime.utc(2026, 9, 8, 14, 0),
    ),
    launcher: launcher,
  );
}

void main() {
  group('HostSession output', () {
    test('a late reader replays from an offset and then follows live', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final pty = env.launcher.handles.single;

      pty.emit(ascii('first '));
      pty.emit(ascii('second '));
      await Future<void>.delayed(Duration.zero);

      final seen = <OutputChunk>[];
      session.readFrom(6).listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      pty.emit(ascii('third'));
      await Future<void>.delayed(Duration.zero);

      expect(seen.map((c) => String.fromCharCodes(c.bytes)).join(), 'second third');
      expect(seen.first.offset, 6);
      expect(seen.last.nextOffset, 18);
    });

    test('replay and live do not overlap: every byte arrives once', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final pty = env.launcher.handles.single;

      for (var i = 0; i < 5; i++) {
        pty.emit(ascii('ab'));
      }
      await Future<void>.delayed(Duration.zero);

      final seen = <OutputChunk>[];
      session.readFrom(0).listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      pty.emit(ascii('cd'));
      await Future<void>.delayed(Duration.zero);

      final joined = seen.map((c) => String.fromCharCodes(c.bytes)).join();
      expect(joined, 'ababababab' 'cd');
      expect(joined.length, session.backlog.totalBytes);
      var expected = 0;
      for (final chunk in seen) {
        expect(chunk.offset, expected, reason: 'offsets must be contiguous');
        expected = chunk.nextOffset;
      }
    });

    test('a reader attaching from the current end gets only what comes next', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final pty = env.launcher.handles.single;
      pty.emit(ascii('old'));
      await Future<void>.delayed(Duration.zero);

      final seen = <OutputChunk>[];
      session.readFrom(session.backlog.totalBytes).listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      pty.emit(ascii('new'));
      await Future<void>.delayed(Duration.zero);

      expect(seen.single.offset, 3);
      expect(String.fromCharCodes(seen.single.bytes), 'new');
    });
  });

  group('HostSession writing', () {
    test('a write without the token is refused and names nobody holds it', () {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final refusal = session.write('pane-1', ascii('ls\n'), DateTime.utc(2026));

      expect(refusal, isNotNull);
      expect(refusal!.message, contains('nobody holds'));
      expect(env.launcher.handles.single.writes, isEmpty);
    });

    test('the holder writes and resizes; an observer is refused by name', () {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final t0 = DateTime.utc(2026, 9, 8, 14, 0);
      session.token.claim('pane-1', t0);

      expect(session.write('pane-1', ascii('ls\n'), t0), isNull);
      expect(session.resize('pane-1', 100, 30, t0), isNull);
      final refusal = session.write('pane-2', ascii('rm\n'), t0.add(const Duration(minutes: 7)));

      expect(env.launcher.handles.single.writes.single, ascii('ls\n'));
      expect(env.launcher.handles.single.resizes.single, (100, 30));
      expect(session.columns, 100);
      expect(session.rows, 30);
      expect(refusal!.message, 'write token held by pane-1 (claimed 7m ago)');
      expect(env.launcher.handles.single.writes, hasLength(1));
    });
  });

  group('HostSession lifecycle', () {
    test('a running session has no exit code, and that is not zero', () {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      expect(session.lifecycle, isA<SessionRunning>());
      expect(session.lifecycle.exitCode, isNull);
      expect(session.lifecycle.describe(), 'running');
    });

    test('a real exit is recorded with its code', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      env.launcher.handles.single.finish(7);
      await session.ended;

      expect(session.lifecycle, isA<SessionExited>());
      expect(session.lifecycle.exitCode, 7);
      expect(session.lifecycle.describe(), 'exited 7');
    });

    test('an unreapable child ends with an unknown code, never zero', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      env.launcher.handles.single.finish(-1);
      await session.ended;

      expect(session.lifecycle, isA<SessionEndedWithoutCode>());
      expect(session.lifecycle.exitCode, isNull);
      expect(session.lifecycle.describe(), contains('unknown'));
    });

    test('terminate prefers the real exit code over "terminated"', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final pty = env.launcher.handles.single;
      final terminating = session.terminate();
      expect(pty.signals.single, 15);
      pty.finish(130);

      expect((await terminating).exitCode, 130);
      expect(pty.closeCount, 1);
    });

    test('a child that exits on its own gives its handles back, unasked', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final pty = env.launcher.handles.single;

      pty.emit(ascii('some work'));
      await Future<void>.delayed(Duration.zero);
      expect(pty.closeCount, 0, reason: 'a running session holds its pty');

      pty.finish(0);
      await session.ended;
      await Future<void>.delayed(Duration.zero);

      // Nobody called terminate: an ended session keeps its code for a late
      // reconnect, but not the fd, the pipe and the job nothing would reach again.
      expect(pty.closeCount, 1);
      expect(session.backlog.totalBytes, 9, reason: 'and every byte it wrote is still readable');
    });

    test('a session that has ended is closed once, not twice', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final pty = env.launcher.handles.single;
      pty.finish(3);
      await session.ended;
      await Future<void>.delayed(Duration.zero);

      await session.terminate();
      expect(pty.closeCount, 1);
    });

    test('a child that will not be reaped is killed, then ends with a stated reason', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final end = await session.terminate(reapWithin: const Duration(milliseconds: 20));

      expect(env.launcher.handles.single.signals, [15, 9]);
      expect(end, isA<SessionEndedWithoutCode>());
      expect((end as SessionEndedWithoutCode).reason, contains('signalled 15, then 9'));
      expect(end.exitCode, isNull);
    });

    test('a shell that ignores SIGTERM gets SIGKILL, and its real code is kept', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh', '-l']));
      final pty = env.launcher.handles.single;
      final terminating = session.terminate(reapWithin: const Duration(milliseconds: 20));
      expect(pty.signals, [15]);

      while (pty.signals.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(pty.signals, [15, 9]);
      pty.finish(137);

      expect((await terminating).exitCode, 137);
    });

    test('asked for SIGKILL outright, there is nothing to escalate to', () async {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final end = await session.terminate(signal: 9, reapWithin: const Duration(milliseconds: 20));

      expect(env.launcher.handles.single.signals, [9]);
      expect((end as SessionEndedWithoutCode).reason, contains('signalled 9 and'));
    });
  });

  group('SessionRegistry', () {
    test('sessions are keyed by the id the client chose', () {
      final env = build();
      env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      expect(
        () => env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh'])),
        throwsA(isA<SessionAlreadyExists>()),
      );
      expect(() => env.registry.require('pane-2'), throwsA(isA<UnknownSession>()));
    });

    test('a summary carries when it was observed, not just what was seen', () async {
      final env = build();
      env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh', '-l'], columns: 90));
      env.launcher.handles.single.emit(ascii('hello'));
      await Future<void>.delayed(Duration.zero);

      final summary = env.registry.list().single;
      expect(summary.id, 'pane-1');
      expect(summary.argv, ['/bin/sh', '-l']);
      expect(summary.columns, 90);
      expect(summary.observedAt, DateTime.utc(2026, 9, 8, 14, 0));
      expect(summary.totalBytes, 5);
      expect(summary.writeHolder, isNull);
      expect(summary.lifecycle, isA<SessionRunning>());
    });

    test('a client going away frees its tokens and keeps its sessions', () {
      final env = build();
      final session = env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      session.token.claim('client-a', DateTime.utc(2026));

      env.registry.forgetClient('client-a');

      expect(session.token.isHeld, isFalse);
      expect(env.registry.find('pane-1'), isNotNull);
      expect(env.launcher.handles.single.signals, isEmpty, reason: 'a disconnect kills nothing');
    });

    test('ended sessions are kept, so a late reconnect still reads the code', () async {
      final launcher = FakePtyLauncher();
      final registry = SessionRegistry(launcher: launcher, keepEndedSessions: 3);
      for (var i = 0; i < 3; i++) {
        registry.open('pane-$i', const PtySpawnRequest(argv: ['/bin/sh']));
      }
      for (final handle in launcher.handles) {
        handle.finish(0);
      }
      await Future<void>.delayed(Duration.zero);

      expect(registry.endedCount, 3);
      expect(registry.find('pane-0')!.lifecycle.exitCode, 0);
    });

    test('the oldest ended sessions are forgotten beyond the bound', () async {
      final launcher = FakePtyLauncher();
      final registry = SessionRegistry(launcher: launcher, keepEndedSessions: 2);
      for (var i = 0; i < 5; i++) {
        registry.open('pane-$i', const PtySpawnRequest(argv: ['/bin/sh']));
      }
      // Ended in order, so which two survive is decided and not incidental.
      for (var i = 0; i < 5; i++) {
        launcher.handles[i].finish(i);
        await Future<void>.delayed(Duration.zero);
      }

      expect(registry.endedCount, 2);
      expect(registry.sessions.map((s) => s.id), ['pane-3', 'pane-4']);
      expect(registry.find('pane-0'), isNull);
    });

    test('running sessions are never pruned, however many there are', () async {
      final launcher = FakePtyLauncher();
      final registry = SessionRegistry(launcher: launcher, keepEndedSessions: 1);
      for (var i = 0; i < 6; i++) {
        registry.open('pane-$i', const PtySpawnRequest(argv: ['/bin/sh']));
      }
      launcher.handles.first.finish(0);
      await Future<void>.delayed(Duration.zero);

      expect(registry.sessions, hasLength(6));
      expect(registry.endedCount, 1);
    });

    test('the record opens before the child is spawned, so a failed spawn leaves no orphan',
        () {
      final launcher = FakePtyLauncher()
        ..failWith = const PtyException('posix_spawn failed', errno: 2);
      final store = _RecordingStore();
      final registry = SessionRegistry(launcher: launcher, store: store);

      expect(
        () => registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh'])),
        throwsA(isA<PtyException>()),
      );
      expect(store.opened, ['pane-1']);
      expect(store.forgotten, ['pane-1'], reason: 'the record of a session that never ran goes');
      expect(store.records.single.closed, isTrue);
      expect(registry.find('pane-1'), isNull);
    });

    test('a store that refuses the record spawns nothing', () {
      final launcher = FakePtyLauncher();
      final registry = SessionRegistry(launcher: launcher, store: _RecordingStore(refuse: true));

      expect(
        () => registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh'])),
        throwsA(isA<StateError>()),
      );
      expect(launcher.started, isEmpty, reason: 'a child with no session is unreachable');
    });

    test('shutdown signals every session at once and waits for them together', () async {
      final env = build();
      env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      env.registry.open('pane-2', const PtySpawnRequest(argv: ['/bin/sh']));

      final stopping = env.registry.shutdown();
      expect(env.launcher.handles.map((h) => h.signals.single), [15, 15]);
      for (final handle in env.launcher.handles) {
        handle.finish(0);
      }
      await stopping;

      expect(env.registry.sessions.every((s) => s.lifecycle.hasEnded), isTrue);
    });

    test('close ends the session and drops it', () async {
      final env = build();
      env.registry.open('pane-1', const PtySpawnRequest(argv: ['/bin/sh']));
      final closing = env.registry.close('pane-1');
      env.launcher.handles.single.finish(0);
      await closing;

      expect(env.registry.find('pane-1'), isNull);
      expect(env.launcher.handles.single.signals.single, 15);
    });
  });
}
