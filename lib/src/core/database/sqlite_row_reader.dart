import 'package:agent_cli/read.dart';
import 'package:sqlite3/sqlite3.dart';

/// The app's [SqliteRowReader]: `package:sqlite3`, read-only, `null` on any
/// failure.
///
/// Two of the stores `agent_cli` reads are SQLite databases the *agent* owns —
/// Antigravity's `conversation_summaries.db` and its per-conversation files,
/// and Codex's `state_<n>.sqlite` thread index. The package takes no SQLite
/// dependency, because one binds a native library and a package that does stops
/// being one `dart test` can run without staging `sqlite3.dll` beside it
/// (docs/PACKAGE_SPLIT.md §4). So the binding is the host's, and this is it —
/// the same `package:sqlite3` the app's own database already uses.
///
/// `null` for anything that went wrong, which is what every caller wants: the
/// CLI that owns the file may simply be holding it, and a busy database is "not
/// recorded" rather than an error to propagate.
Future<List<Map<String, Object?>>?> readSqliteRows(
  String path,
  String sql,
) async {
  Database? db;
  try {
    db = sqlite3.open(path, mode: OpenMode.readOnly);
    return [for (final row in db.select(sql)) {...row}];
  } on Object {
    return null;
  } finally {
    db?.close();
  }
}
