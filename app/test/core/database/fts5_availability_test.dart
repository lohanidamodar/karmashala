import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// **FTS5 is a compile-time option, so its absence is a runtime failure.**
///
/// `sqlite3_flutter_libs` ships a pre-compiled library rather than building
/// from this package's own defines, so "the defines list FTS5" is not evidence
/// — only the library that actually loads is. Every test of the conversation
/// index opens a real database for this reason; this file is the one that fails
/// *legibly* if a dependency bump ever ships a build without the module,
/// instead of leaving `CREATE VIRTUAL TABLE` to fail inside a migration on a
/// user's machine.
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
    db.execute(
      "INSERT INTO probe (text) VALUES ('the decision about caching');",
    );
    final hits = db.select(
      "SELECT text FROM probe WHERE probe MATCH 'caching';",
    );
    expect(hits, hasLength(1));
  });

  // Session search ranks with bm25(), cuts excerpts with snippet() and repairs
  // typos from an fts5vocab table. All three are part of the FTS5 module, but
  // a build could still leave any of them out — so each is exercised here.
  test('bm25 ranks, snippet marks and fts5vocab lists terms', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute("CREATE VIRTUAL TABLE probe USING fts5(text);");
    db.execute(
      "INSERT INTO probe (text) VALUES "
      "('a long note that mentions stripe once among many other words'), "
      "('the stripe webhook and the stripe secret, stripe again');",
    );
    final ranked = db.select(
      "SELECT rowid, snippet(probe, 0, '[', ']', '…', 4) AS s "
      "FROM probe WHERE probe MATCH 'stripe' ORDER BY bm25(probe);",
    );
    // Three mentions in nine words outrank one in eleven — the opposite of
    // rowid order, so it is ORDER BY bm25 that put it first.
    expect(ranked.first['rowid'], 2);
    expect(ranked.first['s'], contains('[stripe]'));

    db.execute(
      "CREATE VIRTUAL TABLE probe_vocab USING fts5vocab(probe, 'row');",
    );
    final terms = db.select(
      "SELECT term, doc FROM probe_vocab WHERE term >= 'st' AND term < 'su';",
    );
    expect(terms.single['term'], 'stripe');
    expect(terms.single['doc'], 2);
  });
}
