/// Reading somebody else's SQLite file, without depending on a SQLite binding.
///
/// Two of the stores this package reads are SQLite databases the *agent* owns —
/// Antigravity's `conversation_summaries.db` and per-conversation `.db` files,
/// and Codex's `state_<n>.sqlite` thread index. Neither is ours to write, and
/// both are opened read-only.
///
/// The package still takes no SQLite dependency. `package:sqlite3` binds a
/// native library, and a package that pulls one in stops being a package a
/// `dart test` can run without staging `sqlite3.dll` beside it — which is most
/// of the point of extracting this layer at all
/// (docs/PACKAGE_SPLIT.md §4). So the *host* supplies the reader, exactly the
/// way it supplies a [CommandRunner]: a function, injected, defaulting to
/// absent.
library;

/// Runs [sql] against the SQLite file at [path], read-only, and returns its
/// rows as column-name → value maps.
///
/// Returns `null` when the file cannot be read at all — busy, absent, or not a
/// database. Every caller treats that as "not recorded" rather than as an
/// error, because the CLI that owns the file may simply be holding it.
typedef SqliteRowReader =
    Future<List<Map<String, Object?>>?> Function(String path, String sql);

/// The reader used when a caller supplies none: no binding, so nothing is
/// readable and every store degrades to "not recorded".
///
/// This is what makes the SQLite-backed readers safe to construct anywhere,
/// including in this package's own tests.
Future<List<Map<String, Object?>>?> noSqliteBinding(String path, String sql) =>
    Future.value(null);
