import 'package:karmashala_git/git.dart';
import 'package:flutter_test/flutter_test.dart';

import 'review_thread_harness.dart';

/// The anchor, which is the whole point of the feature.
///
/// The bug being fixed was not "comments are not saved". It was that a comment
/// keyed by a row of a rendered diff went on *claiming* to point at code after
/// the code moved, and said nothing about it. So these tests are about what the
/// thread says once the file has changed, not about whether it survived.
void main() {
  late ReviewThreadHarness harness;

  setUp(() {
    harness = ReviewThreadHarness(shas: {'lib/a.dart': 'sha-one'});
  });
  tearDown(() => harness.dispose());

  Future<ReviewThread> comment({
    String path = 'lib/a.dart',
    int? line = 12,
    String body = 'This drops the null check.',
  }) => harness.service.open(
    repositoryId: 'r1',
    path: path,
    body: body,
    author: 'the user',
    authorKind: ReviewAuthorKind.user,
    startLine: line,
    excerpt: 'final value = map[key]!;',
  );

  test('a comment anchors to the content it was written against', () async {
    final thread = await comment();
    expect(thread.anchor.blobSha, 'sha-one');
    expect(thread.anchor.startLine, 12);
    // A single-line anchor is a range of one, not a range with a missing end.
    expect(thread.anchor.endLine, 12);

    final index = await harness.service.indexFor('r1');
    expect(index.all.single.attachment, ReviewThreadAttachment.attached);
    expect(index.atLine('lib/a.dart', 12), hasLength(1));
  });

  test('editing the file detaches the thread — it does not move', () async {
    await comment();
    // The agent edits the file the comment is on. Under the old diffIndex key
    // this was invisible: the comment stayed on row 12 of a diff that now had
    // different code on row 12.
    harness.shas['lib/a.dart'] = 'sha-two';

    final index = await harness.service.indexFor('r1');
    final entry = index.all.single;
    expect(entry.attachment, ReviewThreadAttachment.detached);
    // The line number is still recorded — it is where the comment *was* — but
    // nothing will draw it against the current file.
    expect(entry.anchor.startLine, 12);
    expect(index.atLine('lib/a.dart', 12), isEmpty);
    // It is not lost either: it moves to the strip above the diff.
    expect(index.unplaced('lib/a.dart'), hasLength(1));
  });

  test('nothing re-anchors a detached thread by matching its text', () async {
    await comment();
    // The excerpt is still present in the file, one line lower — the case a
    // fuzzy re-anchor would "fix" and would sometimes get wrong.
    harness.shas['lib/a.dart'] = 'sha-two';

    final entry = (await harness.service.indexFor('r1')).all.single;
    expect(entry.attachment, ReviewThreadAttachment.detached);
    expect(
      entry.anchor.startLine,
      12,
      reason: 'the stored line must be the line it was written at, not a guess '
          'at where the excerpt went',
    );
    expect(
      entry.anchor.excerpt,
      'final value = map[key]!;',
      reason: 'the excerpt is evidence for a human, kept verbatim',
    );
  });

  test('content coming back re-attaches, because it is the same bytes', () async {
    await comment();
    harness.shas['lib/a.dart'] = 'sha-two';
    expect(
      (await harness.service.indexFor('r1')).all.single.attachment,
      ReviewThreadAttachment.detached,
    );

    // A revert, a checkout, an undone edit. This is not a guess about where
    // the code went: it is the identity the sha states.
    harness.shas['lib/a.dart'] = 'sha-one';
    expect(
      (await harness.service.indexFor('r1')).all.single.attachment,
      ReviewThreadAttachment.attached,
    );
  });

  test('a file git cannot read is unknown, never attached', () async {
    await comment();
    harness.shas.remove('lib/a.dart');

    final entry = (await harness.service.indexFor('r1')).all.single;
    expect(entry.attachment, ReviewThreadAttachment.unknown);
    expect(entry.isAttached, isFalse);
  });

  test('a file-level comment has no line and is still a real anchor', () async {
    final thread = await comment(line: null);
    expect(thread.anchor.isFileLevel, isTrue);
    expect(thread.anchor.startLine, isNull);
    expect(thread.anchor.endLine, isNull);
    expect(thread.anchor.blobSha, 'sha-one');
    expect(thread.anchor.location, 'lib/a.dart');

    final index = await harness.service.indexFor('r1');
    // Attached — the file is unchanged — but no line can carry it, so it is
    // drawn above the diff rather than nowhere.
    expect(index.all.single.attachment, ReviewThreadAttachment.attached);
    expect(index.unplaced('lib/a.dart'), hasLength(1));
  });

  test('one unreadable file does not blind the threads on every other', () async {
    harness.shas['lib/b.dart'] = 'sha-b';
    await comment();
    await comment(path: 'lib/b.dart');
    // `git hash-object` aborts the whole invocation on the first path it
    // cannot read. Without the per-path retry behind it, one deleted file
    // would report every thread in the repository as "cannot tell".
    harness.shas.remove('lib/a.dart');

    final index = await harness.service.indexFor('r1');
    final byPath = {
      for (final entry in index.all) entry.anchor.path: entry.attachment,
    };
    expect(byPath['lib/a.dart'], ReviewThreadAttachment.unknown);
    expect(byPath['lib/b.dart'], ReviewThreadAttachment.attached);
  });

  test('an empty comment is refused before an anchor is even taken', () async {
    // Refused in the service and not only at each caller, because a thread
    // whose only comment is whitespace renders as a marker on a line with
    // nothing behind it — a reader clicks it and learns nothing.
    await expectLater(
      comment(body: '   '),
      throwsA(isA<ArgumentError>()),
    );
    expect((await harness.service.indexFor('r1')).all, isEmpty);

    final thread = await comment();
    expect(
      () => harness.service.reply(
        threadId: thread.id,
        body: '  \n ',
        author: 'an agent',
        authorKind: ReviewAuthorKind.agent,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(harness.service.getById(thread.id)!.comments, hasLength(1));
  });

  test('a file git will not hash gets no thread, and says why', () async {
    harness.shas.remove('lib/a.dart');
    await expectLater(
      comment(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('anchor'),
        ),
      ),
    );
    expect((await harness.service.indexFor('r1')).all, isEmpty);
  });
}
