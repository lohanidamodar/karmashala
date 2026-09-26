import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Deletes a temporary directory a test made, and never fails the test for it.
///
/// `deleteSync(recursive: true)` names the **top** directory when any child
/// cannot be removed, so an unguarded teardown turns a case's real failure into
/// a `PathNotFoundException` about a path in `%TEMP%`. Windows also holds a
/// handle for a moment after the process that had it exits, so a refusal here
/// is a normal outcome and not a fault.
void _removeTempDirectory(FileSystemEntity entity) {
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException {
    // Deliberately silent: the case's own verdict is the one worth reading.
  }
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  // The metadata read/write/upsert cases live in standalone_store_test.dart
  // ('metadata round-trips').

  /// **The connection settings, on a real file.**
  ///
  /// An in-memory database cannot answer any of this — SQLite reports `memory`
  /// for its journal mode whatever is asked — and the settings are exactly the
  /// kind that pass `analyze`, pass every in-memory test, and do nothing at
  /// all in the app. So these open a database in a temporary directory, which
  /// is the only shape that can tell "we asked for WAL" from "we got it".
  group('connection settings on a file-backed database', () {
    late Directory dir;
    late AppDatabase file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('karmashala-db-pragmas');
      file = AppDatabase(sqlite3.open(p.join(dir.path, 'store.sqlite')));
    });
    tearDown(() {
      file.close();
      _removeTempDirectory(dir);
    });

    test('takes the write-ahead log', () {
      expect(file.journalMode, 'wal');
    });

    test('and its sidecar is beside the store, not somewhere else', () {
      file.writeMetadata('color', 'indigo');
      expect(
        File(p.join(dir.path, 'store.sqlite-wal')).existsSync(),
        isTrue,
        reason:
            'WAL puts a -wal and a -shm next to the database; anyone copying '
            'the store for a backup has to take them too',
      );
    });

    test('and drops the per-commit fsync, but only because WAL took', () {
      // `synchronous = NORMAL` is safe in WAL mode and risks a corrupt
      // database in rollback mode, so the setting is gated on the mode that
      // was actually adopted. 1 is NORMAL; the default is 2, FULL.
      expect(file.query('PRAGMA synchronous;').single.values.single, 1);
    });

    test('and still enforces the cascades the schema declares', () {
      expect(file.query('PRAGMA foreign_keys;').single.values.single, 1);
    });

    test('a second open of the same file finds WAL already set', () {
      // WAL is persistent in the file rather than per-connection: it survives
      // the connection that asked for it, which is why the sidecars outlive a
      // run and why an older build opening this store still gets WAL.
      file.close();
      final again = AppDatabase(sqlite3.open(p.join(dir.path, 'store.sqlite')));
      addTearDown(again.close);
      expect(again.journalMode, 'wal');
    });
  });

  test('an in-memory database is left alone', () {
    // It has no journal to configure, and `PRAGMA synchronous` on it means
    // nothing. What matters is that asking does not throw and does not leave
    // the connection claiming a durability it does not have.
    expect(db.journalMode, 'memory');
  });
}
