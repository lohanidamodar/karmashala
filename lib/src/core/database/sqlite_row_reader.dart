import 'package:agent_cli/read.dart';
import 'package:sqlite3/sqlite3.dart';

/// The app's [SqliteRowReader]: `package:sqlite3`, read-only, `null` on any
/// failure — a busy database is "not recorded", not an error to propagate.
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
