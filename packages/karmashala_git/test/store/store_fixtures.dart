import 'package:karmashala_store/database.dart';

final storeTime = DateTime.utc(2026, 9, 1, 12);

/// A store with checkout `r1` of project `p1` in `windows`.
AppDatabase storeWithCheckout() {
  final db = AppDatabase.memory();
  final at = storeTime.toIso8601String();
  db.execute(
    'INSERT INTO execution_environments (id, kind, name, created_at) '
    "VALUES ('windows', 'windowsNative', 'Windows', ?);",
    [at],
  );
  db.execute(
    'INSERT INTO projects (id, name, root_environment_id, root_path, '
    "created_at) VALUES ('p1', 'App', 'windows', 'C:\\src', ?);",
    [at],
  );
  db.execute(
    'INSERT INTO repositories '
    '(id, project_id, name, environment_id, path, created_at) '
    "VALUES ('r1', 'p1', 'app', 'windows', 'C:\\src', ?);",
    [at],
  );
  return db;
}

/// Retires checkout `r1`, as the server does for a project deleted.
void deleteCheckout(AppDatabase db) =>
    db.execute("DELETE FROM repositories WHERE id = 'r1';");
