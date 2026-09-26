import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// Every size a session had, by the byte it took effect at: what lets a
/// capture of an agent's output be replayed at the widths it was written at.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('karmashala-resizes'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // A handle may still be held on Windows.
    }
  });

  const request = PtySpawnRequest(argv: ['/bin/sh'], columns: 80, rows: 24);

  List<String> sizesOf(String id) {
    final dir = Directory(
      '${root.path}/sessions',
    ).listSync().whereType<Directory>().single;
    return File('${dir.path}/resizes.log').readAsLinesSync();
  }

  test('a resize is written at the offset it took effect', () {
    final store = SessionStore(
      Directory('${root.path}/sessions'),
      owner: '/data/this-server',
      capacityBytes: 4096,
    )..ensureDirectory();
    final record = store.open('s1', request, DateTime.utc(2026, 9, 24))
      ..record(Uint8List(100))
      ..resized(100, 120, 40)
      ..record(Uint8List(50))
      ..resized(150, 90, 30);
    addTearDown(record.close);

    expect(sizesOf('s1'), ['0 80 24', '100 120 40', '150 90 30']);
  });

  test('rotation keeps the size in force at the new first byte', () {
    final store = SessionStore(
      Directory('${root.path}/sessions'),
      owner: '/data/this-server',
      capacityBytes: 100,
    )..ensureDirectory();
    final record = store.open('s1', request, DateTime.utc(2026, 9, 24))
      ..record(Uint8List(60))
      ..resized(60, 120, 40)
      ..record(Uint8List(60))
      ..resized(120, 90, 30)
      // 130 bytes on disk passes the 125 threshold: the first 30 are dropped.
      ..record(Uint8List(10));
    addTearDown(record.close);

    expect(sizesOf('s1'), ['30 80 24', '60 120 40', '120 90 30']);
  });
}
