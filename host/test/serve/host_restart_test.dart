import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// What a restarted host can answer for, and what it must admit it cannot.
///
/// The registry is built twice over one store — which is what a restart is —
/// and the second one is asked the questions a reconnecting pane asks. Nothing
/// here waits on a clock; a session ends because a test ended it.
void main() {
  late Directory root;
  late FakePtyLauncher launcher;

  setUp(() {
    root = Directory.systemTemp.createTempSync('karmashala-restart');
    launcher = FakePtyLauncher();
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // A handle may still be held on Windows; nothing below depends on it.
    }
  });

  SessionStore store({int keep = 16}) => SessionStore(
    Directory('${root.path}/sessions'),
    capacityBytes: 4096,
    keepEndedSessions: keep,
  )..ensureDirectory();

  const request = PtySpawnRequest(argv: ['/bin/sh'], columns: 80, rows: 24);

  test('a session that ended while the host was down answers attach since N', () async {
    final first = SessionRegistry(launcher: launcher, store: store());
    final session = first.open('pane-a', request);
    launcher.handles.last
      ..emit(utf8.encode('first line\n'))
      ..emit(utf8.encode('second line\n'))
      ..finish(3);
    await session.ended;

    final second = SessionRegistry(launcher: launcher, store: store());
    final restored = second.require('pane-a');
    expect(restored.lifecycle.exitCode, 3, reason: 'the code it really had survives');
    expect(restored.backlog.totalBytes, 23);

    // The question a reconnecting pane asks: everything after what it rendered.
    final replay = await restored.readFrom(11).toList();
    expect(
      replay.map((chunk) => utf8.decode(chunk.bytes)).join(),
      'second line\n',
    );
    expect(replay.single.offset, 11);
  });

  test('a session that was running is reported lost, in the words a pane shows', () async {
    final first = SessionRegistry(launcher: launcher, store: store());
    first.open('pane-b', request);
    launcher.handles.last.emit(utf8.encode('a build, halfway'));
    // No finish, no shutdown: the host was killed under it.
    await Future<void>.delayed(Duration.zero);

    final second = SessionRegistry(launcher: launcher, store: store());
    final restored = second.require('pane-b');
    expect(restored.lifecycle.hasEnded, isTrue);
    // Never a zero: the process did not exit, it died with the host that held
    // it, and that is what `ExitedMessage`'s null code is for.
    expect(restored.lifecycle.exitCode, isNull);
    expect(restored.lifecycle.describe(), contains('did not survive'));

    final summary = second.list().single;
    expect(summary.id, 'pane-b');
    expect(summary.lifecycle.exitCode, isNull);
    expect(utf8.decode(restored.backlog.since(0).bytes), 'a build, halfway');
  });

  test('a lost session does not hold its id: reopening it starts a process', () async {
    final first = SessionRegistry(launcher: launcher, store: store());
    first.open('pane-c', request);
    launcher.handles.last.emit(utf8.encode('gone with the host'));
    await Future<void>.delayed(Duration.zero);

    final second = SessionRegistry(launcher: launcher, store: store());
    expect(second.require('pane-c').lifecycle.hasEnded, isTrue);

    final reopened = second.open('pane-c', request);
    expect(reopened.lifecycle.hasEnded, isFalse);
    expect(reopened.backlog.totalBytes, 0, reason: 'a new session starts from nothing');
    // And the old record went with it, rather than being replayed into the new
    // session's numbering on the next restart.
    final third = SessionRegistry(launcher: launcher, store: store());
    expect(third.require('pane-c').backlog.totalBytes, 0);
  });

  test('a running session still holds its id', () {
    final registry = SessionRegistry(launcher: launcher, store: store());
    registry.open('pane-d', request);
    expect(() => registry.open('pane-d', request), throwsA(isA<SessionAlreadyExists>()));
  });

  test('shutting down writes each end rather than forgetting it', () async {
    final first = SessionRegistry(launcher: launcher, store: store());
    first.open('pane-e', request);
    final handle = launcher.handles.last..emit(utf8.encode('work'));
    // `terminate` signals and waits for the reaping; the fake reaps when told.
    final stopping = first.shutdown();
    handle.finish(143);
    await stopping;

    final second = SessionRegistry(launcher: launcher, store: store());
    final restored = second.require('pane-e');
    expect(restored.lifecycle.exitCode, 143);
    expect(utf8.decode(restored.backlog.since(0).bytes), 'work');
  });

  test('closing a session on purpose forgets it, across a restart', () async {
    final first = SessionRegistry(launcher: launcher, store: store());
    first.open('pane-f', request);
    final handle = launcher.handles.last..emit(utf8.encode('done'));
    final closing = first.close('pane-f');
    handle.finish(0);
    await closing;

    expect(SessionRegistry(launcher: launcher, store: store()).sessions, isEmpty);
  });

  test('the bound survives a restart: sixteen ended sessions, not sixty', () async {
    final first = SessionRegistry(launcher: launcher, store: store(keep: 3));
    for (var i = 0; i < 6; i++) {
      final session = first.open('pane-$i', request);
      launcher.handles.last
        ..emit(Uint8List.fromList([0x41 + i]))
        ..finish(i);
      await session.ended;
    }

    final second = SessionRegistry(
      launcher: launcher,
      store: store(keep: 3),
      keepEndedSessions: 3,
    );
    expect(second.sessions.map((s) => s.id).toSet(), {'pane-3', 'pane-4', 'pane-5'});
  });
}
