import 'package:karmashala_git/git.dart';
import 'package:flutter_test/flutter_test.dart';

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
/// * a request per thread, or any request at all — the threads are copied;
/// * a `hash-object` per thread rather than one over the distinct **files**,
///   which is what makes ten comments on one file cost the same as one;
/// * a per-line lookup during the render, which is what the implementation
///   this replaces did (every diff row filtered the whole annotation list) —
///   the panel reads one index and every row does a map lookup in it.
///
/// The threads are this app's copy of the server's: an index asks the server
/// nothing, however many threads there are.
const _readsPerIndex = 0;

void main() {
  for (final count in [10, 100, 500]) {
    test('$count threads on one file cost the same as one', () async {
      final harness = await ReviewThreadHarness.create(
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
        await harness.service.reply(
          threadId: 'thread-$i',
          body: 'reply $i',
          author: 'an agent',
          authorKind: ReviewAuthorKind.agent,
        );
      }

      harness.server.requests.clear();
      harness.hashObjectCalls = 0;
      final index = await harness.service.indexFor('r1');

      expect(index.all, hasLength(count));
      // Nothing asked of the server, and nothing per thread.
      expect(
        harness.server.requests,
        hasLength(_readsPerIndex),
        reason: '$count threads',
      );
      // One process, over the one distinct file — not one per thread.
      expect(harness.hashObjectCalls, 1, reason: '$count threads');

      // And the render itself: every row of the diff asks the index it already
      // has, and asks the server nothing.
      harness.server.requests.clear();
      harness.hashObjectCalls = 0;
      for (var line = 1; line <= count; line++) {
        expect(index.atLine('lib/a.dart', line), hasLength(1));
      }
      expect(index.pending, hasLength(count));
      expect(
        harness.server.requests,
        isEmpty,
        reason: 'a render must not ask the server',
      );
      expect(harness.hashObjectCalls, 0, reason: 'a render must not run git');
    });
  }

  test(
    'threads spread over many files cost one process, not one each',
    () async {
      final harness = await ReviewThreadHarness.create(
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

      harness.server.requests.clear();
      harness.hashObjectCalls = 0;
      final index = await harness.service.indexFor('r1');

      expect(index.all, hasLength(100));
      expect(harness.server.requests, hasLength(_readsPerIndex));
      // The batch covers all twenty files in one invocation — the anchors are
      // per file, so the cost is per file and not per comment.
      expect(harness.hashObjectCalls, 1);
    },
  );
}
