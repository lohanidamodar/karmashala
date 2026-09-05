import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'migrations.dart';
import '../paths/app_support_directory.dart';

/// The application's SQLite database.
///
/// Persistence uses the `sqlite3` package directly with hand-written SQL — there
/// is **no code generation** anywhere in the project. The schema is created and
/// migrated imperatively via the ordered steps in [schemaMigrations], keyed off
/// SQLite's `PRAGMA user_version`.
///
/// This type owns the connection and exposes small, typed helpers ([query],
/// [execute], [transaction], [lastInsertRowId]). Feature data-access objects
/// (DAOs) depend on those helpers and hold their own SQL, so the `sqlite3`
/// dependency stays confined to this file and never leaks into features.
class AppDatabase {
  AppDatabase(this._db) {
    _configure();
    _migrate();
  }

  final Database _db;

  /// Current schema version: the highest key in [schemaMigrations].
  ///
  /// Read from the keys rather than from `schemaMigrations.length`, which is
  /// the same number **only while the keys are dense**. They are not always:
  /// two feature branches in flight both claim the next version, and whichever
  /// merges second has to renumber, so a branch legitimately holds a migration
  /// numbered above a gap until the merge closes it. `length` answered that
  /// situation with a lower number than the migrations it was describing, which
  /// would stamp a freshly migrated database with a version *behind* its own
  /// schema — the one error in a migration runner that no later run can detect,
  /// because it is indistinguishable from a database that legitimately stopped
  /// there.
  int get schemaVersion =>
      schemaMigrations.keys.fold(0, (a, b) => a > b ? a : b);

  /// Opens the database backed by a file in the per-user application-support
  /// directory (outside the project tree).
  static Future<AppDatabase> open() async {
    final dir = await appSupportDirectory();
    final file = p.join(dir.path, 'karmashala.sqlite');
    return AppDatabase(sqlite3.open(file));
  }

  /// Opens an ephemeral in-memory database, for tests.
  factory AppDatabase.memory() => AppDatabase(sqlite3.openInMemory());

  // --- Schema management -----------------------------------------------------

  /// Connection settings, applied once before any other statement.
  ///
  /// **This connection is synchronous and lives on the UI isolate**, so a
  /// commit is a frame the window does not draw. That is what the journal mode
  /// is chosen for.
  ///
  /// * `foreign_keys` — the cascades the schema declares are only enforced when
  ///   this is on. It is per-connection and off by default.
  /// * `journal_mode = WAL` — a rollback-journal commit writes the *original*
  ///   image of every page it touches to a `-journal` file, fsyncs it, writes
  ///   the new pages to the database, fsyncs again, and then deletes the
  ///   journal. Measured on one scrollback autosave (an `UPDATE` of a 64 KiB
  ///   text column, which the terminal does on its own timer): **86 696 bytes
  ///   of journal on top of the pages the database itself received**, twice.
  ///   WAL appends the new pages to a `-wal` file once and never copies the old
  ///   ones. It also lets a *second process* — which this app has, and has had
  ///   in anger: see `todos_external_change_test.dart`, where the owner ticked
  ///   todos off by writing to `karmashala.sqlite` while the app held it open —
  ///   commit without blocking this connection's reads.
  /// * `synchronous = NORMAL`, **and only once WAL is actually in effect.**
  ///   In WAL mode this drops the fsync from every commit; a checkpoint still
  ///   syncs. In rollback-journal mode the same setting risks a *corrupt*
  ///   database on a power cut, so it is gated on the mode we got rather than
  ///   the mode we asked for.
  ///
  /// **What WAL + NORMAL costs.** A process crash, a kill, or the app being
  /// closed loses nothing: the `-wal` content is in the operating system's
  /// cache and survives the process. An **OS crash or power loss** can lose the
  /// most recently committed transactions — the database is never corrupted,
  /// but the last few seconds of writes may roll back. For this app that is a
  /// scrollback tick, a status word, or a note typed in the last moment.
  ///
  /// WAL is also **persistent in the database file** rather than per-connection:
  /// once set it stays set, and the `-wal`/`-shm` sidecars appear beside
  /// `karmashala.sqlite`. Anyone copying the store for a backup has to take all
  /// three, or take a copy made while nothing has it open.
  ///
  /// The request can legitimately be refused — WAL needs shared memory, so a
  /// database on a network share (a redirected `%APPDATA%`) stays in rollback
  /// mode, and another process holding the file can make the switch fail
  /// outright. Both are handled by reading back what was adopted instead of
  /// assuming, and by carrying on either way: the app works in both modes.
  ///
  /// **Three pragmas were measured and deliberately not set.**
  ///
  /// * `cache_size`. Raising it from the default 2 MiB to 64 MiB changed
  ///   nothing on this workload: 179 page-cache misses either way, reading the
  ///   session list back over a 39 MB store after the terminal had walked every
  ///   pane's scrollback. The session table already fits, and a scrollback walk
  ///   streams pages that no cache size keeps.
  /// * `mmap_size`. An I/O error becomes a segfault rather than an error code,
  ///   and a stray pointer anywhere in the process can write through the
  ///   mapping into the file. That is a poor trade against the user's live
  ///   workspace with no measured gain behind it.
  /// * `page_size`. The store's size is scrollback, so a bigger page is the
  ///   obvious thought. It is the wrong one, and by a wide margin on the read
  ///   that happens *most*: the metadata-only read every structural save makes
  ///   over `terminal_panes` cost 47 page-cache misses at 4 KiB, 92 at 8 KiB
  ///   and 106 at 16 KiB, because a wider page drags more of the neighbouring
  ///   scrollback in per miss. Reading one tab's panes *with* their text
  ///   improved only 12 -> 9 -> 8, and the file grew 18%. It would also need a
  ///   `VACUUM` of the whole store to take effect for anyone who already has
  ///   one, on this same isolate, at startup.
  void _configure() {
    _db.execute('PRAGMA foreign_keys = ON;');
    try {
      _db.execute('PRAGMA journal_mode = WAL;');
    } on SqliteException {
      // Locked by another connection, or a filesystem with no shared memory.
      // The rollback journal is slower, not wrong.
      return;
    }
    if (journalMode != 'wal') return;
    _db.execute('PRAGMA synchronous = NORMAL;');
  }

  /// The journal mode this connection actually got, lower-cased.
  ///
  /// Read rather than assumed: [_configure] *asks* for WAL and SQLite is
  /// entitled to say no, and an in-memory database answers `memory` however
  /// nicely it is asked.
  String get journalMode =>
      (_db.select('PRAGMA journal_mode;').first.values.first! as String)
          .toLowerCase();

  /// Applies every step whose version is greater than the stored
  /// `PRAGMA user_version`, in ascending order, each in its own transaction.
  ///
  /// Driven by the map's own sorted keys rather than by counting up from the
  /// stored version, which is the same thing whenever the keys are dense and
  /// **a hard failure when they are not**: the old loop asked for version
  /// `current + 1` and threw `Missing migration step` if a branch had renumbered
  /// around a gap, refusing to open a database it could have migrated
  /// perfectly well.
  ///
  /// This is what the doc comment on [schemaMigrations] has always described.
  /// The counting loop was a stricter approximation of it that happened to
  /// agree until two loops landed migrations at once.
  void _migrate() {
    final current = _userVersion;
    final pending = schemaMigrations.keys.where((v) => v > current).toList()
      ..sort();
    for (final version in pending) {
      _db.execute('BEGIN;');
      try {
        schemaMigrations[version]!(_db);
        _db.execute('PRAGMA user_version = $version;');
        _db.execute('COMMIT;');
      } catch (_) {
        _db.execute('ROLLBACK;');
        rethrow;
      }
    }
  }

  int get _userVersion =>
      _db.select('PRAGMA user_version;').first.values.first! as int;

  // --- Query helpers ---------------------------------------------------------

  /// Runs a SELECT and returns rows as plain column-name → value maps.
  ///
  /// Returning maps (rather than the `sqlite3` `ResultSet`) keeps the `sqlite3`
  /// types out of feature code.
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    final result = _db.select(sql, params);
    final columns = result.columnNames;
    return [
      for (final row in result)
        {for (final column in columns) column: row[column]},
    ];
  }

  /// Runs a non-SELECT statement (INSERT/UPDATE/DELETE/DDL).
  void execute(String sql, [List<Object?> params = const []]) {
    _db.execute(sql, params);
  }

  /// Rowid generated by the most recent INSERT on this connection.
  int get lastInsertRowId => _db.lastInsertRowId;

  /// Runs [action] inside a transaction, rolling back if it throws.
  T transaction<T>(T Function() action) {
    _db.execute('BEGIN;');
    try {
      final result = action();
      _db.execute('COMMIT;');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  // --- App metadata (key/value store) ---------------------------------------

  /// Reads a metadata value by [key], or `null` if absent.
  String? readMetadata(String key) {
    final rows = query('SELECT value FROM app_metadata WHERE key = ?;', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  /// Inserts or updates a metadata [key] with [value], stamping `updated_at`.
  void writeMetadata(String key, String value) {
    execute(
      'INSERT INTO app_metadata (key, value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET '
      'value = excluded.value, updated_at = excluded.updated_at;',
      [key, value, DateTime.now().toUtc().toIso8601String()],
    );
  }

  /// Releases the underlying database handle.
  void close() => _db.close();
}
