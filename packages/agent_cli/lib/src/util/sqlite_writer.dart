/// Writing somebody else's SQLite file, without depending on a SQLite binding.
///
/// The write-side sibling of `SqliteRowReader`, for the one store whose index
/// is a database the app must keep in step with a rename or a delete
/// (Antigravity's `conversation_summaries.db`). The host supplies it, for the
/// reason given in `sqlite_rows.dart`.
library;

/// One statement and its positional parameters.
typedef SqliteStatement = (String sql, List<Object?> parameters);

/// Opens the SQLite file at [path], runs [statements] in order, and closes it.
/// Throws when the file cannot be opened or a statement fails.
typedef SqliteWriter =
    Future<void> Function(String path, List<SqliteStatement> statements);
