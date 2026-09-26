import 'package:karmashala_store/database.dart';
import 'package:karmashala_git/git.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import 'review_thread_harness.dart';

/// What drawing a commented diff costs, counted in statements and processes
/// rather than timed.
///
/// It matters because the Changes panel rebuilds on every working-tree poll and
/// on every keystroke in the review dialog, and the sqlite bindings are
/// synchronous: a query per thread would put the whole review history of the
/// repository on the UI isolate between a git poll and the next frame. A
/// `git hash-object` per thread would be worse — that is a process each.
///
/// The three shapes that would break it, and are guarded here:
///
/// * a comment query per thread, which is what "read the threads, then read
///   each one's replies" looks like — it is one `IN (...)` instead;
/// * a `hash-object` per thread rather than one over the distinct **files**,
///   which is what makes ten comments on one file cost the same as one;
/// * a per-line lookup during the render, which is what the implementation
///   this replaces did (every diff row filtered the whole annotation list) —
///   the panel reads one index and every row does a map lookup in it.
///
/// The number below is four, and it is the same four for ten threads and for
/// five hundred: the repository row, the environment row behind its runner, the
/// threads, and their comments. What is being asserted is that it does not
/// grow, not that it is small.
const _readsPerIndex = 4;

void main() {
  for (final count in [10, 100, 500]) {
    test('$count threads on one file cost the same as one', () async {
      final db = _CountingDatabase();
      final harness = ReviewThreadHarness(
        database: db,
        shas: {'lib/a.dart': 'sha-one'},
      );
      addTearDown(harness.dispose);

      for (var i = 0; i < count; i++) {
        await harness.service.open(
          repositoryId: 'r1',
          path: 'lib/a.dart',
          body: 'comment $i',
          author: 'the user',
          authorKind: ReviewAuthorKind.user,
          startLine: i + 1,
          excerpt: 'line $i',
        );
      }
      // Replies too: a thread with a conversation in it must not cost more
      // reads than a thread without one.
      for (var i = 0; i < count; i++) {
        harness.service.reply(
          threadId: 'thread-$i',
          body: 'reply $i',
          author: 'an agent',
          authorKind: ReviewAuthorKind.agent,
        );
      }

      db.queries = 0;
      harness.hashObjectCalls = 0;
      final index = await harness.service.indexFor('r1');

      expect(index.all, hasLength(count));
      // The repository, its environment, the threads, their comments — and
      // nothing per thread.
      expect(db.queries, _readsPerIndex, reason: '$count threads');
      // One process, over the one distinct file — not one per thread.
      expect(harness.hashObjectCalls, 1, reason: '$count threads');

      // And the render itself: every row of the diff asks the index it already
      // has, and asks the database nothing.
      db.queries = 0;
      harness.hashObjectCalls = 0;
      for (var line = 1; line <= count; line++) {
        expect(index.atLine('lib/a.dart', line), hasLength(1));
      }
      expect(index.pending, hasLength(count));
      expect(db.queries, 0, reason: 'a render must not read the database');
      expect(harness.hashObjectCalls, 0, reason: 'a render must not run git');
    });
  }

  test(
    'threads spread over many files cost one process, not one each',
    () async {
      final db = _CountingDatabase();
      final harness = ReviewThreadHarness(
        database: db,
        shas: {for (var i = 0; i < 20; i++) 'lib/f$i.dart': 'sha-$i'},
      );
      addTearDown(harness.dispose);

      for (var i = 0; i < 20; i++) {
        for (var n = 0; n < 5; n++) {
          await harness.service.open(
            repositoryId: 'r1',
            path: 'lib/f$i.dart',
            body: 'comment $i/$n',
            author: 'the user',
            authorKind: ReviewAuthorKind.user,
            startLine: n + 1,
          );
        }
      }

      db.queries = 0;
      harness.hashObjectCalls = 0;
      final index = await harness.service.indexFor('r1');

      expect(index.all, hasLength(100));
      expect(db.queries, _readsPerIndex);
      // The batch covers all twenty files in one invocation — the anchors are
      // per file, so the cost is per file and not per comment.
      expect(harness.hashObjectCalls, 1);
    },
  );
}

class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  int queries = 0;

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    queries++;
    return super.query(sql, params);
  }
}
