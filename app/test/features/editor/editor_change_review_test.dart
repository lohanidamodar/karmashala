/// **An agent's uncommitted changes, reviewed in the editor**: the file's
/// hunks against git in the gutter, Keep and Revert per hunk through round
/// 55's path, comments to the session that made the change — one at a time
/// or batched into one message — and moving between changes. WSL and SSH
/// files go through the same fakes a server would answer for.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/application/editor_change_review.dart';
import 'package:karmashala/src/features/editor/application/review_comments.dart';
import 'package:karmashala/src/features/editor/presentation/editor_change_review_view.dart';
import 'package:karmashala/src/features/git/application/diff_tab_actions.dart'
    show diffForTargetProvider;
import 'package:karmashala/src/features/git/application/parsed_diff.dart';
import 'package:karmashala/src/features/sessions/application/hunk_review_marks.dart';
import 'package:karmashala/src/features/sessions/application/hunk_reverts.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionPromptRefusal;
import 'package:karmashala_files/values.dart' show FileStamp;
import 'package:karmashala_git/git.dart' show FileDiffStat;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/code.dart';

import '../../support/window_matrix.dart';

const _diff =
    'diff --git a/lib/a.dart b/lib/a.dart\n'
    'index 1111111..2222222 100644\n'
    '--- a/lib/a.dart\n'
    '+++ b/lib/a.dart\n'
    '@@ -1,5 +1,6 @@\n'
    ' a\n'
    '-b\n'
    '+B\n'
    ' c\n'
    '+c2\n'
    ' d\n'
    ' e\n'
    '@@ -20,4 +21,3 @@\n'
    ' x\n'
    '-y\n'
    ' z\n'
    ' w\n';

final _middle = [for (var i = 7; i <= 20; i++) 'l$i'];

/// The file as the agent left it: what the diff's new side says.
final _now = [
  'a', 'B', 'c', 'c2', 'd', 'e', ..._middle, 'x', 'z', 'w', //
].join('\n');

List<EditorHunk> _hunks() {
  final parsed = ParsedDiff.parse(_diff);
  return editorHunksOf('lib/a.dart', parsed.lines, parsed.newLineNumbers);
}

void main() {
  group('hunks on the editor lines', () {
    test('a replacement with an addition, and a removal, placed', () {
      final hunks = _hunks();
      expect(hunks, hasLength(2));

      final first = hunks.first;
      expect((first.startLine, first.endLine), (2, 4));
      expect(first.addedLines, [2, 4]);
      expect(first.replacedLines, {2});
      expect(first.removedAbove, isEmpty);
      expect((first.edit.added, first.edit.removed), (2, 1));
      expect(first.quote, '-b\n+B\n+c2');
      expect(first.range, '2–4');

      final second = hunks.last;
      expect(second.addedLines, isEmpty);
      expect(second.removedAbove, [22]);
      expect((second.startLine, second.endLine), (22, 22));
      expect(second.range, '22');
    });

    test('the hunk at a line', () {
      final hunks = _hunks();
      expect(hunkAtLine(hunks, 3)?.index, 0);
      expect(hunkAtLine(hunks, 22)?.index, 1);
      expect(hunkAtLine(hunks, 10), isNull);
    });
  });

  group('which session a file is reviewed with', () {
    Repository repo(String id, String env, String path) => Repository(
      id: id,
      projectId: 'p',
      name: id,
      path: EnvironmentPath(environmentId: env, path: path),
      createdAt: DateTime.utc(2026),
    );
    Session session(String id, {int day = 1, bool archived = false}) => Session(
      id: id,
      repositoryId: 'r',
      agentInstallationId: 'i',
      title: 'Session $id',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: DateTime.utc(2026, 10, day),
      archivedAt: archived ? DateTime.utc(2026, 10, 9) : null,
    );

    for (final (env, root, file) in [
      ('wsl:Ubuntu', '/home/me/app', '/home/me/app/lib/a.dart'),
      ('ssh:build-box', '/srv/app', '/srv/app/lib/a.dart'),
      ('local', r'C:\code\app', r'C:\code\app\lib\a.dart'),
    ]) {
      test('a file in a $env checkout, by its session', () {
        final app = repo('app', env, root);
        final target = resolveEditorReview(
          file: EnvironmentPath(environmentId: env, path: file),
          repositories: [app],
          sessions: [
            (session: session('s1'), checkouts: [app]),
          ],
        );
        expect(target?.sessionId, 's1');
        expect(target?.checkout, app.path);
        expect(target?.relativePath, 'lib/a.dart');
        expect(target?.repositoryId, 'app');
      });
    }

    test('the same path in another environment is not that checkout', () {
      final app = repo('app', 'wsl:Ubuntu', '/home/me/app');
      expect(
        resolveEditorReview(
          file: const EnvironmentPath(
            environmentId: 'ssh:box',
            path: '/home/me/app/lib/a.dart',
          ),
          repositories: [app],
          sessions: [
            (session: session('s1'), checkouts: [app]),
          ],
        ),
        isNull,
      );
    });

    test('the focused session first, else the newest live one', () {
      final app = repo('app', 'wsl:Ubuntu', '/home/me/app');
      final hub = repo('hub', 'wsl:Ubuntu', '/home/me');
      final sessions = [
        (session: session('old', day: 1), checkouts: [app]),
        (session: session('new', day: 5), checkouts: [app]),
        (session: session('gone', day: 8, archived: true), checkouts: [app]),
        (session: session('elsewhere', day: 9), checkouts: [hub]),
      ];
      const file = EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/home/me/app/lib/a.dart',
      );
      expect(
        resolveEditorReview(
          file: file,
          repositories: [hub, app],
          sessions: sessions,
        )?.sessionId,
        'new',
      );
      expect(
        resolveEditorReview(
          file: file,
          repositories: [hub, app],
          sessions: sessions,
          focusedSessionId: 'old',
        )?.sessionId,
        'old',
      );
    });
  });

  group('the files of the session', () {
    test('absolute paths in a WSL checkout, opened where they are', () {
      final files = sessionReviewFiles(
        checkout: const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/app',
        ),
        changed: ['/home/me/app/lib/b.dart', 'lib/a.dart', '/etc/hosts'],
        stats: const {'lib/a.dart': FileDiffStat(added: 2, removed: 1)},
      );
      expect(files.map((f) => f.relativePath), ['lib/a.dart', 'lib/b.dart']);
      expect(files.first.added, 2);
      expect(files.last.documentId, 'wsl:Ubuntu␟/home/me/app/lib/b.dart');
    });

    test('a Windows checkout, and git standing in for a silent session', () {
      final files = sessionReviewFiles(
        checkout: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\code\app',
        ),
        changed: null,
        stats: const {'lib/a.dart': FileDiffStat(added: 1, removed: 0)},
      );
      expect(files.single.documentId, r'C:\code\app\lib\a.dart');
    });
  });

  group('comments', () {
    const one = ReviewComment(
      id: 'c1',
      repositoryId: 'app',
      path: 'app/lib/x.dart',
      startLine: 42,
      endLine: 48,
      note: 'this loop is wrong, use a map',
      quote: '-for (a in b)\n+for (c in d)',
    );

    test('one is placed, noted and quoted', () {
      expect(
        reviewCommentMessage([one]),
        'In app/lib/x.dart:42–48: this loop is wrong, use a map\n\n'
        '```diff\n-for (a in b)\n+for (c in d)\n```',
      );
    });

    test('several are one numbered message, naming their threads', () {
      final message = reviewCommentMessage([
        one.withThread('t1'),
        const ReviewComment(
          id: 'c2',
          repositoryId: 'app',
          path: 'app/lib/y.dart',
          startLine: 7,
          endLine: 7,
          note: 'rename this',
          quote: '+var x;',
        ).withThread('t2'),
      ]);
      expect(message, startsWith('2 comments on your changes:\n\n1. In '));
      expect(message, contains('\n\n2. In app/lib/y.dart:7: rename this'));
      expect(message, contains('review threads t1, t2'));
    });

    test('sent to its session through the send, threads filed once', () async {
      final sent = <(String, String)>[];
      final filed = <String>[];
      var refuse = true;
      final container = ProviderContainer(
        overrides: [
          reviewCommentSenderProvider.overrideWithValue(
            ReviewCommentSender(
              send: (sessionId, text) async {
                if (refuse) throw const SessionPromptRefusal('it stopped');
                sent.add((sessionId, text));
                return true;
              },
              fileThread: (sessionId, comment) async {
                filed.add('${comment.id}@$sessionId');
                return 'thread-${comment.id}';
              },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final drafts = container.read(reviewCommentDraftsProvider.notifier);
      final a = drafts.add(
        's1',
        repositoryId: 'app',
        path: 'lib/a.dart',
        startLine: 2,
        endLine: 4,
        note: 'first',
        quote: '+B',
      );
      drafts.add(
        's2',
        repositoryId: 'app',
        path: 'lib/a.dart',
        startLine: 9,
        endLine: 9,
        note: 'for the other session',
        quote: '+Z',
      );

      final refused = await drafts.send('s1');
      expect(refused, isA<ReviewNotSent>());
      expect(drafts.of('s1').single.threadId, 'thread-${a.id}');

      refuse = false;
      final outcome = await drafts.send('s1');
      expect(outcome, isA<ReviewSent>());
      expect(filed, ['${a.id}@s1'], reason: 'filed once, not per attempt');
      expect(sent.single.$1, 's1');
      expect(sent.single.$2, startsWith('In lib/a.dart:2–4: first'));
      expect(drafts.of('s1'), isEmpty);
      expect(drafts.of('s2'), hasLength(1), reason: "another session's stay");
    });
  });

  group('in the editor', () {
    late Directory marks;
    setUp(() => marks = Directory.systemTemp.createTempSync('editor_review'));
    tearDown(() => marks.deleteSync(recursive: true));

    EditorReviewTarget target(String env, String root) => EditorReviewTarget(
      sessionId: 's1',
      sessionTitle: 'Fix the loop',
      repositoryId: 'app',
      checkout: EnvironmentPath(environmentId: env, path: root),
      relativePath: 'lib/a.dart',
    );

    Widget host({
      required EditorReviewTarget review,
      required CodeLineEditingController controller,
      _FakeFiles? files,
      List<String>? log,
      List<(String, String)>? sent,
      List<Override> more = const [],
      bool realEditor = true,
      FocusNode? focus,
    }) => ProviderScope(
      overrides: [
        editorReviewTargetProvider.overrideWith((ref, id) => review),
        diffForTargetProvider.overrideWith((ref, target) async => _diff),
        hunkRevertsProvider.overrideWithValue(
          HunkReverts(
            files: files ?? _FakeFiles([]),
            checkpoint: (sessionId, label) async =>
                log?.add('checkpoint $sessionId'),
            discard: (_, _) async {},
          ),
        ),
        hunkReviewMarksDirectoryProvider.overrideWithValue(() async => marks),
        reviewCommentSenderProvider.overrideWithValue(
          ReviewCommentSender(
            send: (sessionId, text) async {
              sent?.add((sessionId, text));
              return true;
            },
            fileThread: (_, _) async => null,
          ),
        ),
        ...more,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EditorChangeReview(
            documentId: 'doc',
            controller: controller,
            isDirty: false,
            editor: (hooks) => realEditor
                ? AppCodeEditor(
                    controller: controller,
                    focusNode: focus,
                    changeMarks: hooks?.marks,
                    onChangeMarkTap: hooks?.onMarkTap,
                    onNextChange: hooks?.onNext,
                    onPreviousChange: hooks?.onPrevious,
                  )
                : const SizedBox.expand(),
          ),
        ),
      ),
    );

    CodeLineEditingController editing() {
      final controller = CodeLineEditingController.fromText(_now);
      addTearDown(controller.dispose);
      return controller;
    }

    String label(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('editor-review-label')))
        .textSpan!
        .toPlainText();

    testWidgets('the hunks are drawn in the gutter', (tester) async {
      await tester.pumpWidget(
        host(
          review: target('wsl:Ubuntu', '/home/me/app'),
          controller: editing(),
        ),
      );
      await tester.pumpAndSettle();
      final gutter = tester.widget<CodeChangeGutter>(
        find.byType(CodeChangeGutter),
      );
      expect(gutter.marks, {
        1: CodeLineChange.modified,
        3: CodeLineChange.added,
        21: CodeLineChange.removedAbove,
      });
      expect(label(tester), contains('Change 1 of 2'));
      expect(label(tester), contains('lines 2–4'));
    });

    testWidgets('no session, no change: just the editor', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            editorReviewTargetProvider.overrideWith((ref, id) => null),
          ],
          child: MaterialApp(
            home: EditorChangeReview(
              documentId: 'doc',
              controller: editing(),
              isDirty: false,
              editor: (hooks) => Text(hooks == null ? 'plain' : 'reviewed'),
            ),
          ),
        ),
      );
      expect(find.text('plain'), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-review-strip')), findsNothing);
    });

    testWidgets('next and previous, by button and by key', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final controller = editing();
      await tester.pumpWidget(
        host(
          review: target('wsl:Ubuntu', '/home/me/app'),
          controller: controller,
          focus: focus,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-review-next')));
      await tester.pumpAndSettle();
      expect(label(tester), contains('Change 2 of 2'));
      expect(controller.selection.extentIndex, 21);

      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(label(tester), contains('Change 1 of 2'));
      expect(controller.selection.extentIndex, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(label(tester), contains('Change 2 of 2'));
    });

    testWidgets('Keep marks the change and writes nothing', (tester) async {
      final log = <String>[];
      await tester.pumpWidget(
        host(
          review: target('wsl:Ubuntu', '/home/me/app'),
          controller: editing(),
          files: _FakeFiles(log),
          log: log,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-review-keep')));
      await tester.pumpAndSettle();
      expect(find.text('Kept'), findsOneWidget);
      expect(log, isEmpty);
    });

    for (final (env, root) in [
      ('wsl:Ubuntu', '/home/me/app'),
      ('ssh:build-box', '/srv/app'),
    ]) {
      testWidgets('Revert puts one hunk back through the server, $env', (
        tester,
      ) async {
        final log = <String>[];
        final files = _FakeFiles(log);
        final where = EnvironmentPath(
          environmentId: env,
          path: '$root/lib/a.dart',
        );
        files.held[where] = '$_now\n';
        await tester.pumpWidget(
          host(
            review: target(env, root),
            controller: editing(),
            files: files,
            log: log,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('editor-review-next')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('editor-review-revert')));
        await tester.pumpAndSettle();

        expect(log, [
          'read $env $root/lib/a.dart',
          'checkpoint s1',
          'write $env $root/lib/a.dart',
        ]);
        expect(files.held[where], contains('\nx\ny\nz\nw\n'));
        expect(files.held[where], contains('\nB\nc\nc2\n'), reason: 'only it');
        expect(
          find.byKey(const ValueKey('editor-review-reverted')),
          findsOneWidget,
        );
      });
    }

    testWidgets('a comment goes to the session that made the change', (
      tester,
    ) async {
      final sent = <(String, String)>[];
      await tester.pumpWidget(
        host(
          review: target('wsl:Ubuntu', '/home/me/app'),
          controller: editing(),
          sent: sent,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-review-comment')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-review-quote')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('editor-review-note')),
        'use a map',
      );
      await tester.tap(find.byKey(const ValueKey('editor-review-send-now')));
      await tester.pumpAndSettle();

      expect(sent, [
        ('s1', 'In lib/a.dart:2–4: use a map\n\n```diff\n-b\n+B\n+c2\n```'),
      ]);
      expect(find.textContaining('Comment sent'), findsOneWidget);
    });

    testWidgets('comments batch into one message with Send 2 comments', (
      tester,
    ) async {
      final sent = <(String, String)>[];
      await tester.pumpWidget(
        host(
          review: target('wsl:Ubuntu', '/home/me/app'),
          controller: editing(),
          sent: sent,
        ),
      );
      await tester.pumpAndSettle();
      Future<void> comment(String note) async {
        await tester.tap(find.byKey(const ValueKey('editor-review-comment')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('editor-review-note')),
          note,
        );
        await tester.tap(find.byKey(const ValueKey('editor-review-add')));
        await tester.pumpAndSettle();
      }

      await comment('first');
      expect(find.text('Send 1 comment'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-review-next')));
      await tester.pumpAndSettle();
      await comment('second');
      expect(sent, isEmpty);

      await tester.tap(find.text('Send 2 comments'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(sent.single.$1, 's1');
      expect(sent.single.$2, startsWith('2 comments on your changes:'));
      expect(sent.single.$2, contains('1. In lib/a.dart:2–4: first'));
      expect(sent.single.$2, contains('2. In lib/a.dart:22: second'));
      expect(find.byKey(const ValueKey('editor-review-pending')), findsNothing);
    });

    testWidgets('fits 360 px at text 1.6 and a desktop', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        because:
            'the strip holds the change, Keep, Revert, Comment, the '
            'moves, and the waiting comments',
        matrix: const [
          WindowCell('360x760 phone, text 1.6', Size(360, 760), textScale: 1.6),
          desktopWindow,
        ],
        build: () => host(
          review: target('ssh:build-box', '/srv/app'),
          controller: editing(),
          realEditor: false,
          more: [reviewCommentDraftsProvider.overrideWith(_TwoWaiting.new)],
        ),
      );
    });
  });
}

class _TwoWaiting extends ReviewCommentDrafts {
  @override
  Map<String, List<ReviewComment>> build() => const {
    's1': [
      ReviewComment(
        id: 'a',
        repositoryId: 'app',
        path: 'lib/a.dart',
        startLine: 2,
        endLine: 4,
        note: 'one',
        quote: '+B',
      ),
      ReviewComment(
        id: 'b',
        repositoryId: 'app',
        path: 'lib/a.dart',
        startLine: 22,
        endLine: 22,
        note: 'two',
        quote: '-y',
      ),
    ],
  };
}

class _FakeFiles implements HunkFiles {
  _FakeFiles(this.log);

  final List<String> log;
  final held = <EnvironmentPath, String>{};

  @override
  Future<ReadText?> read(EnvironmentPath path) async {
    log.add('read ${path.environmentId} ${path.path}');
    final text = held[path];
    return text == null
        ? null
        : (text: text, stamp: FileStamp(length: text.length, modified: null));
  }

  @override
  Future<void> write(
    EnvironmentPath path,
    String text,
    FileStamp? stamp,
  ) async {
    log.add('write ${path.environmentId} ${path.path}');
    held[path] = text;
  }
}
