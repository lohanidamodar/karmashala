import 'package:agent_cli/process.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/store.dart';
import 'package:karmashala_host/src/mcp/tools/review_thread_tool_set.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:test/test.dart';

import 'tool_harness.dart';

/// The files' current blobs, as a test says they are — and every question
/// asked, so a test can see the anchor was computed rather than taken.
class _Anchors implements ReviewAnchors {
  final shas = <String, String>{};
  final asked = <List<String>>[];
  final unreachable = <String>{};

  @override
  bool reaches(String repositoryId) => !unreachable.contains(repositoryId);

  @override
  Future<Map<String, String>> shasFor(
    String repositoryId,
    List<String> paths,
  ) async {
    asked.add(paths);
    return {for (final path in paths) path: ?shas[path]};
  }
}

/// Review threads, run by the server (slice 2b): what an agent can say about
/// a review, and what it cannot. A checkout the server cannot read is handed
/// to the app, which hashes it.
void main() {
  late ToolHarness h;
  late _Anchors anchors;
  late ReviewThreadToolSet tools;

  setUp(() {
    h = ToolHarness();
    anchors = _Anchors()
      ..shas.addAll({'lib/a.dart': 'sha-one', 'lib/b.dart': 'sha-b'});
    tools = ReviewThreadToolSet(h.context, anchors: anchors);
  });
  tearDown(() => h.dispose());

  Future<Map<String, Object?>> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
    String? caller = 's1',
  ]) => h.map(tools, tool, arguments, caller);

  Future<Map<String, Object?>> add({
    String path = 'lib/a.dart',
    int? startLine = 12,
    int? endLine,
    String comment = 'This drops the null check.',
    String? excerpt = 'final value = map[key]!;',
  }) => call('review_thread_add', {
    'path': path,
    'comment': comment,
    'startLine': ?startLine,
    'endLine': ?endLine,
    'excerpt': ?excerpt,
  });

  Matcher argumentError(String words) => throwsA(
    isA<ArgumentError>().having((e) => '$e', 'text', contains(words)),
  );

  test('the calling session supplies the checkout', () async {
    final thread = await add();
    expect(thread['repositoryId'], 'r1');
    expect(thread['sessionId'], 's1');
    expect(thread['path'], 'lib/a.dart');
    expect(thread['startLine'], 12);
    expect(thread['endLine'], 12);
    expect(thread['attachment'], 'attached');
  });

  test('an agent files a claim, not an instruction', () async {
    final thread = await add();
    // `shouldFix` is the set the Changes panel sends back to an author agent.
    expect(thread['status'], 'open');
    final comment = (thread['comments']! as List).single as Map;
    expect(comment['authorKind'], 'agent');
    expect(comment['author'], 'an agent in session s1');
  });

  test('there is no way to file straight into the pending set', () async {
    final thread = await call('review_thread_add', {
      'path': 'lib/a.dart',
      'comment': 'x',
      'status': 'shouldFix',
    });
    expect(thread['status'], 'open');
  });

  test('the anchor is never taken from the caller', () async {
    final thread = await add();
    expect(thread['blobSha'], 'sha-one');
    expect(anchors.asked, [
      ['lib/a.dart'],
    ]);
  });

  test('a file git cannot hash gets no thread', () async {
    await expectLater(
      add(path: 'lib/unhashable.dart'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('git could not hash `lib/unhashable.dart`'),
        ),
      ),
    );
    expect(ReviewThreadDao(h.db).all(), isEmpty);
  });

  test('a detached thread is reported as detached, with no guessing', () async {
    final thread = await add();
    anchors.shas['lib/a.dart'] = 'sha-two';

    final read = await call('review_thread_get', {'id': thread['id']});
    expect(read['attachment'], 'detached');
    // The line it was written at is still reported; nothing has moved it.
    expect(read['startLine'], 12);
    expect(read['excerpt'], 'final value = map[key]!;');

    anchors.shas.remove('lib/a.dart');
    expect(
      (await call('review_thread_get', {'id': thread['id']}))['attachment'],
      'unknown',
    );
  });

  test('replies append and are attributed to the caller', () async {
    final thread = await add();
    final replied = await call('review_thread_reply', {
      'id': thread['id'],
      'comment': 'Fixed: it uses the configured default now.',
    }, 's2');
    final comments = (replied['comments']! as List).cast<Map>();
    expect(comments, hasLength(2));
    expect(comments.last['body'], 'Fixed: it uses the configured default now.');
    expect(comments.last['author'], 'an agent in session s2');
    // A reply does not decide the thread is done — whoever raised it does.
    expect(replied['status'], 'open');
  });

  test('status moves both ways and touches nothing that was written', () async {
    final thread = await add();
    final moved = await call('review_thread_status', {
      'id': thread['id'],
      'status': 'shouldFix',
    });
    expect(moved['status'], 'shouldFix');
    final back = await call('review_thread_status', {
      'id': thread['id'],
      'status': 'open',
    });
    expect(back['status'], 'open');
    expect(back['comments'], hasLength(1));
    expect(back['blobSha'], 'sha-one');
  });

  test('listing filters by file and by status', () async {
    await add();
    final other = await add(path: 'lib/b.dart', comment: 'and this');
    await call('review_thread_status', {
      'id': other['id'],
      'status': 'dismissed',
    });

    expect((await call('review_thread_list'))['threads'], hasLength(2));
    expect(
      (await call('review_thread_list', {'path': 'lib/b.dart'}))['threads'],
      hasLength(1),
    );
    final byStatus =
        (await call('review_thread_list', {
              'status': ['open'],
            }))['threads']!
            as List;
    expect(byStatus, hasLength(1));
    expect((byStatus.single as Map)['path'], 'lib/a.dart');
  });

  test('adding twice is two comments, not one written twice', () async {
    final first = await add(comment: 'the same words');
    final second = await add(comment: 'the same words');
    expect(first['id'], isNot(second['id']));
    expect((await call('review_thread_list'))['threads'], hasLength(2));
  });

  group('refusals say what is wrong', () {
    test('a range without a start is not a range', () async {
      await expectLater(
        call('review_thread_add', {
          'path': 'lib/a.dart',
          'comment': 'x',
          'endLine': 4,
        }),
        argumentError('endLine without startLine is not a range'),
      );
    });

    test('an end before its start is refused', () async {
      await expectLater(
        call('review_thread_add', {
          'path': 'lib/a.dart',
          'comment': 'x',
          'startLine': 9,
          'endLine': 4,
        }),
        argumentError('endLine cannot come before startLine.'),
      );
    });

    test('an empty comment is not a review comment', () async {
      await expectLater(
        call('review_thread_add', {'path': 'lib/a.dart', 'comment': '   '}),
        argumentError('A review comment needs something written in it.'),
      );
      final thread = await add();
      await expectLater(
        call('review_thread_reply', {'id': thread['id'], 'comment': ' '}),
        argumentError('A reply needs something written in it.'),
      );
    });

    test('an unknown status names the ones that exist', () async {
      final thread = await add();
      await expectLater(
        call('review_thread_status', {
          'id': thread['id'],
          'status': 'escalated',
        }),
        argumentError('shouldFix'),
      );
    });

    test('a thread that is not there is said so, in each verb', () async {
      for (final (tool, args) in [
        ('review_thread_get', {'id': 'ghost'}),
        ('review_thread_reply', {'id': 'ghost', 'comment': 'x'}),
        ('review_thread_status', {'id': 'ghost', 'status': 'open'}),
      ]) {
        await expectLater(
          call(tool, args),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'No review thread with id ghost.',
            ),
          ),
          reason: tool,
        );
      }
      await expectLater(
        call('review_thread_get'),
        argumentError('id is required — review_thread_list has them.'),
      );
    });

    test('a caller with no session and no repositoryId is told why', () async {
      await expectLater(
        call('review_thread_add', {'path': 'lib/a.dart', 'comment': 'x'}, null),
        argumentError('list_checkouts'),
      );
    });
  });

  group('a checkout the server cannot read is the app\'s', () {
    test('every verb about it is handed on', () async {
      final thread = await add();
      anchors.unreachable.add('r1');
      expect(tools.call('review_thread_list', const {}, 's1'), isNull);
      expect(
        tools.call('review_thread_add', const {
          'path': 'lib/a.dart',
          'comment': 'x',
        }, 's1'),
        isNull,
      );
      for (final tool in const [
        'review_thread_get',
        'review_thread_reply',
        'review_thread_status',
      ]) {
        expect(
          tools.call(tool, {'id': thread['id']}, 's1'),
          isNull,
          reason: tool,
        );
      }
      // A refusal that needs no checkout is still answered here.
      await expectLater(
        tools.call('review_thread_get', const {}, 's1')!,
        throwsA(isA<ArgumentError>()),
      );
    });

    test('this machine\'s environment is read here; WSL is not', () {
      ExecutionEnvironmentDao(h.db).upsert(
        ExecutionEnvironment(
          id: 'wsl:Ubuntu',
          kind: EnvironmentKind.wsl,
          name: 'Ubuntu',
          createdAt: h.now,
          wslDistribution: 'Ubuntu',
        ),
      );
      h.addRepository('r-wsl', environmentId: 'wsl:Ubuntu');
      final here = h.here.kind == EnvironmentKind.windowsNative;
      final local = LocalReviewAnchors(h.db, windows: here);
      expect(local.reaches('r1'), isTrue);
      expect(local.reaches('r-wsl'), isFalse);
      expect(
        local.reaches('gone'),
        isTrue,
        reason: 'nothing to hash is answered here, as unknown',
      );
      expect(LocalReviewAnchors(h.db, windows: !here).reaches('r1'), isFalse);
    });
  });

  group('the annotations were decided, not defaulted', () {
    test('the reads are read-only and the writes are not', () {
      expect(kMcpToolAnnotations['review_thread_list']!.readOnly, isTrue);
      expect(kMcpToolAnnotations['review_thread_get']!.readOnly, isTrue);
      for (final name in const [
        'review_thread_add',
        'review_thread_reply',
        'review_thread_status',
      ]) {
        expect(kMcpToolAnnotations[name]!.readOnly, isFalse, reason: name);
      }
    });

    test('nothing here is destructive, and that is the honest answer', () {
      // There is deliberately no delete tool, so nothing in this family can
      // remove a review; a status can always be moved back.
      for (final schema in tools.schemas) {
        final name = schema['name']! as String;
        expect(kMcpToolAnnotations[name]!.destructive, isFalse, reason: name);
        expect(kMcpToolAnnotations[name]!.openWorld, isFalse, reason: name);
      }
    });

    test('what appends is not idempotent; what sets a field is', () {
      expect(kMcpToolAnnotations['review_thread_add']!.idempotent, isFalse);
      expect(kMcpToolAnnotations['review_thread_reply']!.idempotent, isFalse);
      expect(kMcpToolAnnotations['review_thread_status']!.idempotent, isTrue);
    });
  });

  test('the panel sees what an agent wrote', () async {
    await add();
    // Written through the data API, so the Changes panel's copy has it.
    final stored = ReviewThreadDao(h.db).forRepository('r1').single;
    expect(stored.status, ReviewThreadStatus.open);
    expect(stored.anchor.startLine, 12);
  });
}
