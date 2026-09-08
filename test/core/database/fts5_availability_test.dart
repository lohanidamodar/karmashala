import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// **FTS5 is a compile-time option, so its absence is a runtime failure.**
///
/// `sqlite3_flutter_libs` ships a pre-compiled library rather than building
/// from this package's own defines, so "the defines list FTS5" is not evidence
/// — only the library that actually loads is. Every DAO test in the conversation
/// index stubs nothing and opens a real database for this reason; this file is
/// the one that fails *legibly* if a dependency bump ever ships a build without
/// the module, instead of leaving `CREATE VIRTUAL TABLE` to fail inside a
/// migration on a user's machine.
void main() {
  test('the bundled library reports ENABLE_FTS5', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final options = db
        .select('PRAGMA compile_options;')
        .map((row) => row['compile_options'] as String)
        .toList();
    expect(options, contains('ENABLE_FTS5'));
  });

  test('and a virtual table can actually be created and matched', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute("CREATE VIRTUAL TABLE probe USING fts5(text);");
    db.execute("INSERT INTO probe (text) VALUES ('the decision about caching');");
    final hits = db.select(
      "SELECT text FROM probe WHERE probe MATCH 'caching';",
    );
    expect(hits, hasLength(1));
  });
}
