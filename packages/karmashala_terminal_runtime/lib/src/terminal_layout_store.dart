import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// The client-local store's file name, in the app-support folder.
const String kTerminalLayoutFileName = 'terminal_layout.sqlite';

/// This client's terminal layout — tabs, panes and their scrollback, and the
/// `terminal.*` keys — in its own small SQLite file beside the app, never at
/// the server: a layout is one window's, and a phone has none.
class TerminalLayoutStore {
  TerminalLayoutStore(this._db) {
    _db.execute('PRAGMA foreign_keys = ON;');
    _db.execute('PRAGMA busy_timeout = 5000;');
    try {
      _db.execute('PRAGMA journal_mode = WAL;');
      _db.execute('PRAGMA synchronous = NORMAL;');
    } on SqliteException {
      // Another connection holds it; the rollback journal is slower, not wrong.
    }
    _migrate();
  }

  static TerminalLayoutStore open(Directory directory) => TerminalLayoutStore(
    sqlite3.open(p.join(directory.path, kTerminalLayoutFileName)),
  );

  factory TerminalLayoutStore.memory() =>
      TerminalLayoutStore(sqlite3.openInMemory());

  final Database _db;

  static final Map<int, void Function(Database db)> _steps = {1: _createV1};

  void _migrate() {
    final current =
        _db.select('PRAGMA user_version;').first.values.first! as int;
    for (final version
        in _steps.keys.where((v) => v > current).toList()..sort()) {
      transaction(() {
        _steps[version]!(_db);
        _db.execute('PRAGMA user_version = $version;');
      });
    }
  }

  static void _createV1(Database db) {
    const tab = '''
      id              TEXT PRIMARY KEY,
      ordinal         INTEGER NOT NULL,
      layout          TEXT NOT NULL,
      focused_pane_id TEXT,
      is_active       INTEGER NOT NULL,
      detached        INTEGER NOT NULL DEFAULT 0,
      updated_at      TEXT NOT NULL''';
    const pane = '''
      id                TEXT PRIMARY KEY,
      tab_id            TEXT NOT NULL,
      ordinal           INTEGER NOT NULL,
      profile_id        TEXT NOT NULL,
      title             TEXT NOT NULL,
      working_directory TEXT,
      scrollback        TEXT NOT NULL,
      launch_command    TEXT,
      was_live          INTEGER NOT NULL DEFAULT 0,
      updated_at        TEXT NOT NULL''';
    db
      ..execute('CREATE TABLE terminal_tabs ($tab);')
      ..execute(
        'CREATE TABLE terminal_panes ($pane, FOREIGN KEY (tab_id) '
        'REFERENCES terminal_tabs (id) ON DELETE CASCADE);',
      )
      ..execute(
        'CREATE INDEX idx_terminal_panes_tab ON terminal_panes (tab_id);',
      )
      // The layout-loss guard's shadow copy: no FK and no cascade.
      ..execute('CREATE TABLE terminal_tabs_backup ($tab);')
      ..execute('CREATE TABLE terminal_panes_backup ($pane);')
      ..execute(
        'CREATE TABLE layout_metadata (key TEXT PRIMARY KEY, '
        'value TEXT NOT NULL);',
      );
  }

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

  void execute(String sql, [List<Object?> params = const []]) =>
      _db.execute(sql, params);

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

  String? readMetadata(String key) {
    final rows = query('SELECT value FROM layout_metadata WHERE key = ?;', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void writeMetadata(String key, String value) => execute(
    'INSERT INTO layout_metadata (key, value) VALUES (?, ?) '
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
    [key, value],
  );

  void close() => _db.close();
}
