import 'dart:io';

import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/files/data/files_client.dart'
    show FilesStaleException;
import 'package:karmashala/src/features/sessions/application/hunk_review_marks.dart';
import 'package:karmashala/src/features/sessions/application/hunk_reverts.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/hunk_review.dart';
import 'package:karmashala_files/values.dart' show FileStamp;
import 'package:karmashala_git/git.dart' show buildFileEditDiff;

import '../../support/window_matrix.dart';

/// Keep or revert an agent's change a hunk at a time: the reverse worked out
/// from the file the server reads, a checkpoint first, the server writing it;
/// a file that moved on says so; Keep is a mark kept on this device.
void main() {
  const path = '/home/me/app/lib/a.dart';
  const recorded =
      '@@ -1,5 +1,5 @@\n a\n-b\n+B\n c\n d\n e\n'
      '@@ -20,3 +20,3 @@\n x\n-y\n+Y\n z';
  const edit = FileEditRecord(
    path: path,
    kind: FileEditKind.modified,
    toolName: 'Edit',
    recordedDiff: recorded,
  );
  final hunks = diffHunks(path, buildFileEditDiff(edit).lines);

  String file(List<String> lines) => '${lines.join('\n')}\n';
  final edited = file([
    'a', 'B', 'c', 'd', 'e', //
    for (var i = 6; i < 20; i++) 'l$i',
    'x', 'Y', 'z',
  ]);

  group('hunks', () {
    test('one per @@, numbered, counted, keyed alike every time', () {
      expect(hunks, hasLength(2));
      expect(hunks.first.before, ['a', 'b', 'c', 'd', 'e']);
      expect(hunks.first.after, ['a', 'B', 'c', 'd', 'e']);
      expect(hunks.last.newStart, 20);
      expect((hunks.first.added, hunks.first.removed), (1, 1));
      expect(
        hunks.first.key,
        diffHunks(path, buildFileEditDiff(edit).lines).first.key,
      );
      expect(hunks.first.key, isNot(hunks.last.key));
    });

    test('changes far apart in one stretch are two hunks', () {
      const whole = FileEditRecord(
        path: 'w.txt',
        kind: FileEditKind.modified,
        oldText: 'p\nq1\nr\ns\nt\nu\nv\nw\nx\ny\nz\nq2\n',
        newText: 'p\nQ1\nr\ns\nt\nu\nv\nw\nx\ny\nz\nQ2\n',
      );
      final split = diffHunks('w.txt', buildFileEditDiff(whole).lines);
      expect(split, hasLength(2));
      expect(split.map((h) => h.index), [0, 1]);
    });

    test('putting one back changes only it, CRLF kept', () {
      final put = revertHunk(edited, hunks.last) as HunkReverted;
      expect(put.text, contains('\ny\n'));
      expect(put.text, contains('\nB\n'), reason: 'the other hunk stays');

      final crlf = edited.replaceAll('\n', '\r\n');
      final back = revertHunk(crlf, hunks.first) as HunkReverted;
      expect(back.text, startsWith('a\r\nb\r\nc'));
      expect(back.text.endsWith('\r\n'), isTrue);
    });

    test('a file that moved on is a conflict, never a guess', () {
      final moved = edited.replaceFirst('Y', 'Yes');
      expect(revertHunk(moved, hunks.last), isA<HunkConflict>());
      expect(revertHunks(moved, hunks), isA<HunkConflict>());
    });

    test('an excerpt is found inside its lines', () {
      const excerpt = FileEditRecord(
        path: 'e.dart',
        kind: FileEditKind.modified,
        oldText: 'count = 1',
        newText: 'count = 2',
      );
      final only = diffHunks('e.dart', buildFileEditDiff(excerpt).lines).single;
      final put = revertHunk('final count = 2;\n', only) as HunkReverted;
      expect(put.text, 'final count = 1;\n');
    });
  });

  group('the revert service', () {
    late _FakeFiles files;
    late List<String> log;
    late HunkReverts reverts;

    setUp(() {
      log = [];
      files = _FakeFiles(log);
      reverts = HunkReverts(
        files: files,
        checkpoint: (sessionId, label) async =>
            log.add('checkpoint $sessionId: $label'),
        discard: (checkout, path) async =>
            log.add('discard ${checkout.path} $path'),
      );
    });

    for (final environment in ['wsl:Ubuntu', 'ssh:build-box']) {
      test(
        'a checkpoint first, then the server writes, in $environment',
        () async {
          final where = EnvironmentPath(environmentId: environment, path: path);
          files.held[where] = edited;
          final outcome = await reverts.revert(
            sessionId: 's1',
            file: where,
            hunks: [hunks.last],
          );
          expect(outcome, isA<Reverted>());
          expect(log, [
            'read $environment $path',
            'checkpoint s1: Before reverting a change in a.dart',
            'write $environment $path',
          ]);
          expect(files.held[where], contains('\ny\n'));
        },
      );
    }

    test(
      'a hunk that no longer applies: no checkpoint, nothing written',
      () async {
        const where = EnvironmentPath(environmentId: 'w', path: path);
        files.held[where] = edited.replaceFirst('Y', 'Yes');
        final outcome = await reverts.revert(
          sessionId: 's1',
          file: where,
          hunks: [hunks.last],
        );
        expect(outcome, isA<RevertConflict>());
        expect(log, ['read w $path']);
      },
    );

    test('a file that changed between read and write is refused', () async {
      const where = EnvironmentPath(environmentId: 'w', path: path);
      files
        ..held[where] = edited
        ..stale = true;
      final outcome = await reverts.revert(
        sessionId: 's1',
        file: where,
        hunks: hunks,
      );
      expect(outcome, isA<RevertConflict>());
      expect((outcome as RevertConflict).reason, contains('changed while'));
    });

    test('no checkpoint, no change', () async {
      const where = EnvironmentPath(environmentId: 'w', path: path);
      files.held[where] = edited;
      final refusing = HunkReverts(
        files: files,
        checkpoint: (_, _) async => throw StateError('no repository'),
        discard: (_, _) async {},
      );
      final outcome = await refusing.revert(
        sessionId: 's1',
        file: where,
        hunks: hunks,
      );
      expect(outcome, isA<RevertFailed>());
      expect(log.where((l) => l.startsWith('write')), isEmpty);
    });

    test("the Files tab's Revert file is git's, after a checkpoint", () async {
      final outcome = await reverts.revertToGit(
        sessionId: 's1',
        checkout: const EnvironmentPath(environmentId: 'w', path: '/repo'),
        path: 'lib/a.dart',
      );
      expect(outcome, isA<Reverted>());
      expect(log, [
        'checkpoint s1: Before reverting a.dart',
        'discard /repo lib/a.dart',
      ]);
    });
  });

  test('Keep marks are kept per session on this device', () async {
    final dir = Directory.systemTemp.createTempSync('hunk_marks');
    // Windows refuses to delete a file a late save still holds open (seen on
    // the CI runner); it is a temp folder, so try for a moment, then leave it.
    addTearDown(() async {
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          dir.deleteSync(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    ProviderContainer container() => ProviderContainer(
      overrides: [
        hunkReviewMarksDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    final first = container();
    await first.read(hunkReviewMarksProvider.notifier).loaded;
    first.read(hunkReviewMarksProvider.notifier).toggle('s1', 'k1');
    expect(first.read(hunkReviewMarksProvider)['s1'], {'k1'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    first.dispose();

    final again = container();
    addTearDown(again.dispose);
    final marks = again.read(hunkReviewMarksProvider.notifier);
    await marks.loaded;
    expect(marks.kept('s1', 'k1'), isTrue);
    expect(marks.kept('s2', 'k1'), isFalse);
  });

  group('in the chat', () {
    final call = ChatMessage(
      role: 'tool',
      text: 'Edit(a.dart)',
      pending: true,
      tool: ToolActivity(name: 'Edit', subject: path, edits: const [edit]),
    );

    Widget host(
      _FakeFiles files,
      List<String> log, {
      Directory? marks,
      List<String>? opened,
    }) => ProviderScope(
      overrides: [
        hunkRevertsProvider.overrideWithValue(
          HunkReverts(
            files: files,
            checkpoint: (sessionId, label) async => log.add('checkpoint'),
            discard: (_, _) async {},
          ),
        ),
        if (marks != null)
          hunkReviewMarksDirectoryProvider.overrideWithValue(() async => marks),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: HunkReviewHost(
            sessionId: 's1',
            place: (p) => EnvironmentPath(environmentId: 'wsl:Ubuntu', path: p),
            openFile: (p) => opened?.add(p),
            child: ChatTranscriptView(
              messages: [
                const ChatMessage(role: 'user', text: 'Fix both'),
                call,
              ],
              turn: TranscriptTurn.working,
            ),
          ),
        ),
      ),
    );

    late Directory marks;
    setUp(() => marks = Directory.systemTemp.createTempSync('hunk_ui'));
    tearDown(() => marks.deleteSync(recursive: true));

    testWidgets('each hunk has Keep and Revert; Revert puts it back', (
      tester,
    ) async {
      final log = <String>[];
      final files = _FakeFiles(log);
      const where = EnvironmentPath(environmentId: 'wsl:Ubuntu', path: path);
      files.held[where] = edited;
      await tester.pumpWidget(host(files, log, marks: marks));
      await tester.pump();
      expect(find.byKey(const ValueKey('hunk-bar-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('hunk-keep')), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('hunk-revert')).first);
      await tester.pumpAndSettle();
      expect(
        log.indexOf('checkpoint'),
        lessThan(log.indexOf('write wsl:Ubuntu $path')),
      );
      expect(files.held[where], startsWith('a\nb\n'));
      expect(find.byKey(const ValueKey('hunk-reverted')), findsOneWidget);
    });

    testWidgets('Keep marks it, and nothing in the file moves', (tester) async {
      final log = <String>[];
      await tester.pumpWidget(host(_FakeFiles(log), log, marks: marks));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hunk-keep')).first);
      await tester.pump();
      expect(find.text('Kept'), findsOneWidget);
      expect(log, isEmpty);
    });

    testWidgets('a hunk that no longer applies says so and offers the file', (
      tester,
    ) async {
      final log = <String>[];
      final files = _FakeFiles(log);
      final opened = <String>[];
      files.held[const EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: path,
          )] =
          'rewritten\n';
      await tester.pumpWidget(host(files, log, marks: marks, opened: opened));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hunk-revert')).first);
      await tester.pumpAndSettle();
      expect(find.text('This change no longer applies'), findsOneWidget);
      expect(find.textContaining('changed since that turn'), findsOneWidget);
      await tester.tap(find.text('Open file'));
      await tester.pumpAndSettle();
      expect(opened, [path]);
      expect(log.where((l) => l.startsWith('write')), isEmpty);
    });

    testWidgets('Revert file asks first, then puts back every hunk', (
      tester,
    ) async {
      final log = <String>[];
      final files = _FakeFiles(log);
      const where = EnvironmentPath(environmentId: 'wsl:Ubuntu', path: path);
      files.held[where] = edited;
      await tester.pumpWidget(host(files, log, marks: marks));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hunk-revert-file')).first);
      await tester.pumpAndSettle();
      expect(find.text('Revert a.dart?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(log, isEmpty);

      await tester.tap(find.byKey(const ValueKey('hunk-revert-file')).first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Revert file'),
        ),
      );
      await tester.pumpAndSettle();
      expect(files.held[where], allOf(contains('\nb\n'), contains('\ny\n')));
    });

    testWidgets('fits 360 px at text 1.6 and a desktop', (tester) async {
      final log = <String>[];
      await expectSurvivesWindowMatrix(
        tester,
        because: 'a hunk\'s line holds its count, Keep and Revert',
        matrix: const [
          WindowCell('360x760 phone, text 1.6', Size(360, 760), textScale: 1.6),
          desktopWindow,
        ],
        build: () => host(_FakeFiles(log), log, marks: marks),
      );
    });
  });
}

class _FakeFiles implements HunkFiles {
  _FakeFiles(this.log);

  final List<String> log;
  final held = <EnvironmentPath, String>{};
  var stale = false;

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
    if (stale) throw FilesStaleException(null);
    log.add('write ${path.environmentId} ${path.path}');
    held[path] = text;
  }
}
