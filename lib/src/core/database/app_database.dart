import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// The application's SQLite database.
///
/// Persistence uses the `sqlite3` package directly with hand-written SQL — there
/// is **no code generation** anywhere in the project. The schema is created and
/// migrated imperatively in [_migrate].
///
/// Loop 0 ships exactly one table, `app_metadata` (a key/value store), used for
/// cross-cutting metadata such as the persisted schema version and a first-run
/// marker. The domain schema (projects, repositories, sessions, agent
/// installations, the session-event log) is introduced in Loop 1.
class AppDatabase {
  AppDatabase(this._db) {
    _migrate();
  }

  final Database _db;

  /// Current schema version. Bumped as migrations are added in later loops.
  int get schemaVersion => 1;

  /// Opens the database backed by a file in the per-user application-support
  /// directory (outside the project tree).
  static Future<AppDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = p.join(dir.path, 'chitragupta.sqlite');
    return AppDatabase(sqlite3.open(file));
  }

  /// Opens an ephemeral in-memory database, for tests.
  factory AppDatabase.memory() => AppDatabase(sqlite3.openInMemory());

  void _migrate() {
    _db.execute('PRAGMA foreign_keys = ON;');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS app_metadata (
        key        TEXT PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    _db.execute('PRAGMA user_version = $schemaVersion;');
  }

  /// Reads a metadata value by [key], or `null` if absent.
  String? readMetadata(String key) {
    final result = _db.select('SELECT value FROM app_metadata WHERE key = ?;', [
      key,
    ]);
    if (result.isEmpty) return null;
    return result.first['value'] as String;
  }

  /// Inserts or updates a metadata [key] with [value], stamping `updated_at`.
  void writeMetadata(String key, String value) {
    _db.execute(
      'INSERT INTO app_metadata (key, value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET '
      'value = excluded.value, updated_at = excluded.updated_at;',
      [key, value, DateTime.now().toUtc().toIso8601String()],
    );
  }

  /// Releases the underlying database handle.
  void close() => _db.close();
}
