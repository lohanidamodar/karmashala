import 'package:karmashala_git/git.dart';
import 'package:flutter_test/flutter_test.dart';

import 'review_thread_harness.dart';

/// What a send gathers, and what it leaves behind.
///
/// The old path collected every annotation in the repository and then **cleared
/// them all**, so a review comment existed for exactly as long as it took to
/// mention it once: nothing to check the fix against, nothing to reply to, and
/// no way to tell a comment the agent addressed from one it ignored.
void main() {
  late ReviewThreadHarness harness;

  setUp(() async {
    harness = await ReviewThreadHarness.create(
      shas: {'lib/a.dart': 'sha-one', 'lib/b.dart': 'sha-b'},
    );
  });
  tearDown(() => harness.dispose());

  Future<ReviewThread> comment({
    String path = 'lib/a.dart',
    int? line = 12,
    required String body,
    ReviewAuthorKind authorKind = ReviewAuthorKind.user,
    String excerpt = 'final value = map[key]!;',
  }) => harness.service.open(
    repositoryId: 'r1',
    path: path,
    body: body,
    author: authorKind == ReviewAuthorKind.user ? 'the user' : 'an agent',
    authorKind: authorKind,
    startLine: line,
    excerpt: excerpt,
  );

  test('the pending set is should-fix, not everything', () async {
    await comment(body: 'A: the user wants this fixed.');
    final agent = await comment(
      path: 'lib/b.dart',
      body: 'B: a reviewer thinks this is suspicious.',
      authorKind: ReviewAuthorKind.agent,
    );
    // An agent's finding lands as `open` — a claim awaiting triage — so it is
    // deliberately not in the set that gets sent back to an agent.
    expect(agent.status, ReviewThreadStatus.open);

    final pending = (await harness.service.indexFor('r1')).pending;
    expect(pending.map((e) => e.thread.body), [
      'A: the user wants this fixed.',
    ]);

    // Once a human triages it, it joins the set.
    await harness.service.setStatus(agent.id, ReviewThreadStatus.shouldFix);
    expect((await harness.service.indexFor('r1')).pending, hasLength(2));
  });

  test('dismissed and resolved threads are kept and not sent', () async {
    final one = await comment(body: 'not actually a problem');
    final two = await comment(path: 'lib/b.dart', body: 'already handled');
    await harness.service.setStatus(one.id, ReviewThreadStatus.dismissed);
    await harness.service.setStatus(two.id, ReviewThreadStatus.resolved);

    final index = await harness.service.indexFor('r1');
    expect(index.pending, isEmpty);
    // Kept, not deleted: "we looked at this and decided no" is an answer, and
    // a thread that vanished would be raised again by the next reader.
    expect(index.all, hasLength(2));
  });

  test('sending changes nothing about the threads', () async {
    await comment(body: 'fix this');
    final before = await harness.service.indexFor('r1');
    final prompt = buildReviewThreadPrompt(before.pending);
    expect(prompt, contains('fix this'));

    // Building the prompt is the whole of "send" as far as the threads are
    // concerned. Nothing was cleared, nothing was marked.
    final after = await harness.service.indexFor('r1');
    expect(after.all, hasLength(1));
    expect(after.pending, hasLength(1));
    expect(after.all.single.thread.status, ReviewThreadStatus.shouldFix);
  });

  test('an attached thread is sent with its line and its code', () async {
    await comment(body: 'Use the configured value.');
    final prompt = buildReviewThreadPrompt(
      (await harness.service.indexFor('r1')).pending,
    );
    expect(prompt, contains('`lib/a.dart:12`'));
    expect(prompt, contains('Code: `final value = map[key]!;`'));
    expect(prompt, contains('Review (the user): Use the configured value.'));
    expect(prompt, isNot(contains('has changed since')));
  });

  test(
    'a detached thread is still sent, and says the position is stale',
    () async {
      await comment(body: 'Use the configured value.');
      harness.shas['lib/a.dart'] = 'sha-two';

      final pending = (await harness.service.indexFor('r1')).pending;
      // Still requested: "fix the thing I asked about" survives the file moving.
      expect(pending, hasLength(1));
      final prompt = buildReviewThreadPrompt(pending);
      expect(prompt, contains('the file has changed since this comment'));
      expect(prompt, contains('do not trust the position'));
      // The excerpt is what the agent can actually search for.
      expect(prompt, contains('Code: `final value = map[key]!;`'));
    },
  );

  test('a file that cannot be read says that, and not that it moved', () async {
    await comment(body: 'Use the configured value.');
    harness.shas.remove('lib/a.dart');

    final prompt = buildReviewThreadPrompt(
      (await harness.service.indexFor('r1')).pending,
    );
    expect(prompt, contains('could not be read'));
    expect(prompt, isNot(contains('the file has changed since')));
  });

  test('replies travel with the request, attributed', () async {
    final thread = await comment(body: 'This drops the null check.');
    await harness.service.reply(
      threadId: thread.id,
      body: 'Only on the empty-map path.',
      author: 'an agent in session s1',
      authorKind: ReviewAuthorKind.agent,
    );

    final prompt = buildReviewThreadPrompt(
      (await harness.service.indexFor('r1')).pending,
    );
    expect(prompt, contains('Review (the user): This drops the null check.'));
    expect(
      prompt,
      contains('Reply (an agent in session s1): Only on the empty-map path.'),
    );
  });
}
