import 'dart:io';

/// The SQLite files an agent wrote, without a SQLite binding.
///
/// `agent_cli` depends on no native library, so the readers that open
/// Antigravity's conversation stores and Codex's thread index take a
/// `SqliteRowReader` and the caller supplies it. This is the test's: rows go in
/// per file, and the two aggregate queries those readers actually issue are
/// answered over them — so the suites still assert "these rows produce this
/// reading" rather than asserting against a stubbed answer.
///
/// [put] also creates the file on disk, because the readers find their stores
/// by listing a directory before they read anything out of one.
class FakeSqliteFiles {
  final Map<String, List<Map<String, Object?>>> _rows = {};
  final Map<String, String> _tables = {};

  /// Registers [rows] as the contents of [table] in the database at [path],
  /// and creates the file so a directory listing finds it.
  void put(String path, String table, List<Map<String, Object?>> rows) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(const []);
    _rows[path] = rows;
    _tables[path] = table;
  }

  /// A [SqliteRowReader]: null for a file that is not a database of ours, or
  /// whose one table is not the one the query names.
  Future<List<Map<String, Object?>>?> read(String path, String sql) async {
    final rows = _rows[path];
    if (rows == null) return null;
    if (!sql.contains('from ${_tables[path]}')) return null;

    if (sql.contains('count(*) as n') && sql.contains('min(created_at)')) {
      final created = rows.map((r) => r['created_at']).whereType<int>();
      final updated = rows.map((r) => r['updated_at']).whereType<int>();
      return [
        {
          'n': rows.length,
          'first': created.isEmpty
              ? null
              : created.reduce((a, b) => a < b ? a : b),
          'last': updated.isEmpty
              ? null
              : updated.reduce((a, b) => a > b ? a : b),
        },
      ];
    }
    if (sql.contains('count(*) as n')) {
      return [
        {'n': rows.length},
      ];
    }
    return rows;
  }
}
