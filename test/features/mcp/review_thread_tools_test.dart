import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/mcp/mcp_tool_catalogue.dart';
import 'package:karmashala/src/features/mcp/review_thread_tools.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../git/review_thread_harness.dart';

/// The MCP surface: what an agent can say about a review, and what it cannot.
void main() {
  late ReviewThreadHarness harness;
  late ReviewThreadTools tools;

  setUp(() {
    harness = ReviewThreadHarness(
      shas: {'lib/a.dart': 'sha-one', 'lib/b.dart': 'sha-b'},
    );
    AgentInstallationDao(harness.db).insert(agentInstallation());
    SessionDao(harness.db).insert(session(id: 's1'));
    tools = ReviewThreadTools(harness.container, callerSessionId: 's1');
  });
  tearDown(() => harness.dispose());

  Future<Map<String, Object?>> add({
    String path = 'lib/a.dart',
    int? startLine = 12,
    int? endLine,
    String comment = 'This drops the null check.',
    String? excerpt = 'final value = map[key]!;',
  }) async =>
      (await tools.call('review_thread_add', {
        'path': path,
        'comment': comment,
        'startLine': ?startLine,
        'endLine': ?endLine,
        'excerpt': ?excerpt,
      }))!
          as Map<String, Object?>;

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
    // An agent that could file straight into it would be writing the user's
    // task list — see the file's own doc.
    expect(thread['status'], 'open');
    final comment =
        (thread['comments']! as List).single as Map<String, Object?>;
    expect(comment['authorKind'], 'agent');
    expect(comment['author'], contains('s1'));
  });

  test('there is no way to file straight into the pending set', () async {
    // The argument is simply not honoured; nothing here reads it.
    final thread =
        (await tools.call('review_thread_add', {
              'path': 'lib/a.dart',
              'comment': 'x',
              'status': 'shouldFix',
            }))!
            as Map<String, Object?>;
    expect(thread['status'], 'open');
  });

  test('the anchor is never taken from the caller', () async {
    final thread = await add();
    // The sha is computed from the file, not accepted as an argument — a
    // caller-supplied hash could describe content it read three turns ago.
    expect(thread['blobSha'], 'sha-one');
    expect(harness.runner.requests.any((r) => r.arguments.contains('hash-object')),
        isTrue);
  });

  test('a detached thread is reported as detached, with no guessing', () async {
    final thread = await add();
    harness.shas['lib/a.dart'] = 'sha-two';

    final read =
        (await tools.call('review_thread_get', {'id': thread['id']}))!
            as Map<String, Object?>;
    expect(read['attachment'], 'detached');
    // The line it was written at is still reported; nothing has moved it.
    expect(read['startLine'], 12);
    expect(read['excerpt'], 'final value = map[key]!;');
  });

  test('replies append and are attributed to the caller', () async {
    final thread = await add();
    final replied =
        (await tools.call('review_thread_reply', {
              'id': thread['id'],
              'comment': 'Fixed: it uses the configured default now.',
            }))!
            as Map<String, Object?>;
    final comments = replied['comments']! as List;
    expect(comments, hasLength(2));
    expect(
      (comments.last as Map<String, Object?>)['body'],
      'Fixed: it uses the configured default now.',
    );
    // A reply does not decide the thread is done — whoever raised it does.
    expect(replied['status'], 'open');
  });

  test('status moves both ways and touches nothing that was written', () async {
    final thread = await add();
    final moved =
        (await tools.call('review_thread_status', {
              'id': thread['id'],
              'status': 'shouldFix',
            }))!
            as Map<String, Object?>;
    // The status asked for, not some other one: `shouldFix` is the set that
    // gets sent to an author agent, so landing anywhere else here would either
    // silently drop the request or silently raise one.
    expect(moved['status'], 'shouldFix');
    final back =
        (await tools.call('review_thread_status', {
              'id': thread['id'],
              'status': 'open',
            }))!
            as Map<String, Object?>;
    expect(back['status'], 'open');
    expect((back['comments']! as List), hasLength(1));
    expect(back['blobSha'], 'sha-one');
  });

  test('listing filters by file and by status', () async {
    await add();
    final other = await add(path: 'lib/b.dart', comment: 'and this');
    await tools.call('review_thread_status', {
      'id': other['id'],
      'status': 'dismissed',
    });

    final all =
        (await tools.call('review_thread_list', const <String, dynamic>{}))!
            as Map<String, Object?>;
    expect((all['threads']! as List), hasLength(2));

    final byPath =
        (await tools.call('review_thread_list', {'path': 'lib/b.dart'}))!
            as Map<String, Object?>;
    expect((byPath['threads']! as List), hasLength(1));

    final byStatus =
        (await tools.call('review_thread_list', {
              'status': ['open'],
            }))!
            as Map<String, Object?>;
    expect((byStatus['threads']! as List), hasLength(1));
    expect(
      ((byStatus['threads']! as List).single as Map)['path'],
      'lib/a.dart',
    );
  });

  group('refusals say what is wrong', () {
    test('a range without a start is not a range', () async {
      await expectLater(
        tools.call('review_thread_add', {
          'path': 'lib/a.dart',
          'comment': 'x',
          'endLine': 4,
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an end before its start is refused', () async {
      await expectLater(
        tools.call('review_thread_add', {
          'path': 'lib/a.dart',
          'comment': 'x',
          'startLine': 9,
          'endLine': 4,
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an empty comment is not a review comment', () async {
      await expectLater(
        tools.call('review_thread_add', {
          'path': 'lib/a.dart',
          'comment': '   ',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an unknown status names the ones that exist', () async {
      final thread = await add();
      await expectLater(
        tools.call('review_thread_status', {
          'id': thread['id'],
          'status': 'escalated',
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('shouldFix'),
          ),
        ),
      );
    });

    test('a caller with no session and no repositoryId is told why', () async {
      final unattributed = ReviewThreadTools(harness.container);
      await expectLater(
        unattributed.call('review_thread_add', {
          'path': 'lib/a.dart',
          'comment': 'x',
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('list_checkouts'),
          ),
        ),
      );
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
      // The close call is `review_thread_status`: moving a thread to
      // `dismissed` takes it out of the set that gets sent, which *feels* like
      // ending something. But every comment and the anchor are still there
      // afterwards and one more call puts the status back — which is precisely
      // the undo `destructiveHint` says does not exist. There is deliberately
      // no delete tool, so nothing in this family can remove a review.
      for (final name in const [
        'review_thread_list',
        'review_thread_get',
        'review_thread_add',
        'review_thread_reply',
        'review_thread_status',
      ]) {
        expect(kMcpToolAnnotations[name]!.destructive, isFalse, reason: name);
      }
    });

    test('what appends is not idempotent; what sets a field is', () {
      expect(kMcpToolAnnotations['review_thread_add']!.idempotent, isFalse);
      expect(kMcpToolAnnotations['review_thread_reply']!.idempotent, isFalse);
      expect(kMcpToolAnnotations['review_thread_status']!.idempotent, isTrue);
    });

    test('nothing here reaches outside this machine', () {
      for (final name in kMcpToolAnnotations.keys.where(
        (name) => name.startsWith('review_thread_'),
      )) {
        expect(kMcpToolAnnotations[name]!.openWorld, isFalse, reason: name);
      }
    });
  });

  test('adding twice is two comments, not one written twice', () async {
    final first = await add(comment: 'the same words');
    final second = await add(comment: 'the same words');
    expect(first['id'], isNot(second['id']));
    final all =
        (await tools.call('review_thread_list', const <String, dynamic>{}))!
            as Map<String, Object?>;
    expect((all['threads']! as List), hasLength(2));
  });

  test('the panel sees what an agent wrote', () async {
    await add();
    // The MCP write goes through the same service the Changes panel reads, so
    // a finding filed by a reviewer turns up beside the line without anything
    // having to poll for it.
    final index = await harness.service.indexFor('r1');
    expect(index.atLine('lib/a.dart', 12), hasLength(1));
    expect(
      index.atLine('lib/a.dart', 12).single.thread.status,
      ReviewThreadStatus.open,
    );
  });
}
