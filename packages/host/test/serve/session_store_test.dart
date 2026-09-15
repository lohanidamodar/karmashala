import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The record beside the ring, on a real filesystem. Everything is counted —
/// bytes, offsets, records surviving the bound — and nothing waits.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('karmashala-store'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // A handle can still be held on Windows; nothing here depends on it.
    }
  });

  SessionStore storeOf({int capacityBytes = 4096, int keepEndedSessions = 16}) =>
      SessionStore(
        Directory('${root.path}/sessions'),
        capacityBytes: capacityBytes,
        keepEndedSessions: keepEndedSessions,
      )..ensureDirectory();

  const request = PtySpawnRequest(
    argv: ['cmd.exe', '/k'],
    workingDirectory: r'C:\work',
    environment: {'TERM': 'xterm-256color'},
    columns: 100,
    rows: 30,
  );
  final startedAt = DateTime.utc(2026, 9, 9, 12);

  test('a record that cannot be opened is a no-op, never a throw', () {
    // A file where the sessions directory should be: every create under it fails.
    File('${root.path}/blocked').writeAsStringSync('');
    final store = SessionStore(Directory('${root.path}/blocked'));

    final record = store.open('pane-a', request, startedAt);
    expect(record.isRecording, isFalse);
    record
      ..record(_bytes('lost'))
      ..ended(SessionExited(0, startedAt))
      ..close();
    expect(store.restore(), isEmpty);
  });

  test('a session that ended is answered for exactly, code and all', () {
    final store = storeOf();
    store.open('pane-a', request, startedAt)
      ..record(_bytes('hello '))
      ..record(_bytes('world'))
      ..ended(SessionExited(7, DateTime.utc(2026, 9, 9, 12, 5)))
      ..close();

    final restored = storeOf().restore();
    expect(restored, hasLength(1));
    final session = restored.single;
    expect(session.id, 'pane-a');
    expect(session.request.argv, ['cmd.exe', '/k']);
    expect(session.request.workingDirectory, r'C:\work');
    expect(session.request.environment, {'TERM': 'xterm-256color'});
    expect(session.request.columns, 100);
    expect(session.startedAt, startedAt);
    expect(session.wasRunning, isFalse);
    expect(session.lifecycle, isA<SessionExited>());
    expect(session.lifecycle.exitCode, 7);
    expect(session.backlog.totalBytes, 11);
    expect(_text(session.backlog.since(0)), 'hello world');
    expect(_text(session.backlog.since(6)), 'world');
  });

  test('a session that was running is lost, and the record says so in words', () {
    final store = storeOf();
    // No `ended`: this is a host that stopped while the session was alive.
    store.open('pane-b', request, startedAt)
      ..record(_bytes('half a build'))
      ..close();

    final session = storeOf().restore().single;
    expect(session.wasRunning, isTrue);
    // Never a zero: the process did not exit, it died with the host.
    expect(session.lifecycle, isA<SessionEndedWithoutCode>());
    expect(session.lifecycle.exitCode, isNull);
    expect(
      (session.lifecycle as SessionEndedWithoutCode).reason,
      allOf(contains('stopped'), contains('did not survive')),
    );
    expect(_text(session.backlog.since(0)), 'half a build');
  });

  test('the record is bounded the way the ring is, and says what it dropped', () {
    final store = storeOf(capacityBytes: 1024);
    final record = store.open('pane-c', request, startedAt);
    // Past the rotation point twice over, in chunks the rotation has to survive.
    for (var i = 0; i < 40; i++) {
      record.record(Uint8List.fromList(List.filled(100, 0x41 + (i % 26))));
    }
    record
      ..ended(SessionExited(0, DateTime.utc(2026, 9, 9, 13)))
      ..close();

    final onDisk = File('${store.directory.path}/${_only(store.directory)}/out.bin').lengthSync();
    expect(
      onDisk,
      lessThanOrEqualTo(store.rotateAboveBytes),
      reason: 'a session costs no more on disk than it does in the ring',
    );

    final session = storeOf(capacityBytes: 1024).restore().single;
    expect(session.backlog.totalBytes, 4000, reason: 'the absolute count is what it always was');
    expect(session.backlog.heldBytes, lessThanOrEqualTo(1024));
    expect(session.backlog.firstAvailableOffset, 4000 - session.backlog.heldBytes);

    // A client from before the rotation is told how much it lost.
    final slice = session.backlog.since(0);
    expect(slice.droppedBytes, session.backlog.firstAvailableOffset);
    expect(slice.offset, session.backlog.firstAvailableOffset);

    // And the tail really is the tail: the last chunk written is the last read.
    expect(_text(session.backlog.since(3990)), List.filled(10, 'N').join());
  });

  test('a record that was forgotten is gone', () {
    final store = storeOf();
    store.open('pane-d', request, startedAt)
      ..record(_bytes('x'))
      ..close();
    expect(storeOf().restore(), hasLength(1));
    store.forget('pane-d');
    expect(storeOf().restore(), isEmpty);
  });

  test('only the newest ended records are kept; running ones are never pruned', () {
    final store = storeOf(keepEndedSessions: 2);
    for (var i = 0; i < 4; i++) {
      store.open('ended-$i', request, startedAt)
        ..record(_bytes('$i'))
        ..ended(SessionExited(i, DateTime.utc(2026, 9, 9, 12, i)))
        ..close();
    }
    // Opened and left running: the host's job is to hold it.
    store.open('alive', request, startedAt).record(_bytes('still going'));

    final ids = storeOf(keepEndedSessions: 2).restore().map((s) => s.id).toSet();
    expect(ids, contains('alive'));
    expect(ids, containsAll(['ended-2', 'ended-3']));
    expect(ids, isNot(contains('ended-0')));
    expect(ids, isNot(contains('ended-1')));
  });

  test('a half-written record costs its own session and no other', () {
    final store = storeOf();
    store.open('good', request, startedAt)
      ..record(_bytes('kept'))
      ..ended(SessionExited(0, DateTime.utc(2026, 9, 9, 12, 1)))
      ..close();
    store.open('torn', request, startedAt)
      ..record(_bytes('lost'))
      ..close();
    // A power cut during the metadata write is what this looks like.
    final torn = Directory('${store.directory.path}/torn-${_hashOf('torn')}');
    File('${torn.path}/meta.json').writeAsStringSync('{"version":1,"id":"to');

    final restored = storeOf().restore();
    expect(restored.map((s) => s.id), ['good']);
  });

  test('two ids that sanitise the same way do not share a record', () {
    final store = storeOf();
    store.open('pane/one', request, startedAt)
      ..record(_bytes('first'))
      ..close();
    store.open(r'pane\one', request, startedAt)
      ..record(_bytes('second'))
      ..close();

    final restored = storeOf().restore();
    expect(restored.map((s) => s.id).toSet(), {'pane/one', r'pane\one'});
  });
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
String _text(BacklogSlice slice) => utf8.decode(slice.bytes, allowMalformed: true);

String _only(Directory directory) =>
    directory.listSync().whereType<Directory>().single.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .last;

/// The same FNV-1a the store names directories with, so a test can reach one
/// without the store exposing its naming.
String _hashOf(String id) {
  var hash = 0x811c9dc5;
  for (final unit in id.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
