import 'package:agent_cli/read.dart';
import 'package:sqlite3/sqlite3.dart';

/// The app's [SqliteWriter]: `package:sqlite3`, one open per call, every
/// statement run in order. Failures propagate — a store edit that did not land
/// is reported, not swallowed.
Future<void> writeSqliteStatements(
  String path,
  List<SqliteStatement> statements,
) async {
  Database? db;
  try {
    db = sqlite3.open(path);
    for (final (sql, parameters) in statements) {
      db.execute(sql, parameters);
    }
  } finally {
    db?.close();
  }
}
