import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/git/presentation/diff_line_tile.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_edit_diff_card.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_run.dart';
import 'package:karmashala/src/features/sessions/presentation/turn_changed_files.dart';
import 'package:karmashala_git/git.dart';

/// An edit's diff is drawn in the chat under the call that made it, from a
/// CLI transcript and from an ACP agent alike, and each turn ends with the
/// files it changed.
void main() {
  setUp(clearFileEditDiffCache);

  ChatMessage said(String text, {String role = 'agent'}) =>
      ChatMessage(role: role, text: text);

  ChatMessage call(ToolActivity tool) =>
      ChatMessage(role: 'tool', text: tool.summary, tool: tool);

  /// A Claude Code `Edit` as the CLI transcript reader builds it.
  ToolActivity cliEdit(String path, String before, String after) =>
      toolActivityFor('Edit', {
        'file_path': path,
        'old_string': before,
        'new_string': after,
      }).withResult(output: 'The file has been updated.');

  /// An ACP edit as the server's transcript page carries it.
  ToolActivity acpEdit(String path, String? before, String after) =>
      ToolActivity.fromJson({
        'name': 'Edit $path',
        'subject': path,
        'output': 'edited $path',
        'kind': 'edit',
        'edits': [
          {
            'path': path,
            'kind': before == null ? 'created' : 'modified',
            'oldText': ?before,
            'newText': after,
          },
        ],
      });

  Widget view(List<ChatMessage> messages) => MaterialApp(
    home: Scaffold(
      body: ChatTranscriptView(messages: messages, turn: TranscriptTurn.idle),
    ),
  );

  Finder shown(String text) => find.textContaining(text, findRichText: true);

  Iterable<String> diffRows(WidgetTester tester) => tester
      .widgetList<DiffLineTile>(find.byType(DiffLineTile))
      .map((tile) => tile.line.text);

  group('folding unchanged lines', () {
    List<DiffLine> lines(String unified) => parseUnifiedDiff(unified);

    test('a long unchanged stretch between changes folds to its edges', () {
      final rows = foldUnchangedLines(
        lines(
          [
            '-a',
            '+b',
            for (var i = 0; i < 20; i++) ' same $i',
            '-c',
            '+d',
          ].join('\n'),
        ),
      );
      expect(rows.whereType<DiffFoldRow>().single.lines, hasLength(14));
      expect(rows.whereType<DiffShownRow>(), hasLength(4 + 2 * 3));
    });

    test('a short stretch, or one at either end, keeps its context', () {
      final short = foldUnchangedLines(
        lines(['-a', '+b', ' x', ' y', ' z', '-c'].join('\n')),
      );
      expect(short.whereType<DiffFoldRow>(), isEmpty);

      final ends = foldUnchangedLines(
        lines(
          [
            for (var i = 0; i < 10; i++) ' head $i',
            '-a',
            '+b',
            for (var i = 0; i < 10; i++) ' tail $i',
          ].join('\n'),
        ),
      );
      final folds = ends.whereType<DiffFoldRow>().toList();
      expect(folds.map((f) => f.lines.length), [7, 7]);
      expect((ends[1] as DiffShownRow).line.text, ' head 7');
    });
  });

  group('the card', () {
    testWidgets('a CLI edit draws its diff under the call', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolEditDiffCard(
              activity: cliEdit('/src/a.dart', 'int a = 1;', 'int a = 2;'),
            ),
          ),
        ),
      );
      expect(diffRows(tester), ['-int a = 1;', '+int a = 2;']);
      expect(find.text('a.dart'), findsOneWidget);
      expect(find.text('/src/'), findsOneWidget);
      expect(shown('+1'), findsOneWidget);
      expect(shown('−1'), findsOneWidget);
    });

    testWidgets('a long diff is collapsed until asked for', (tester) async {
      final after = [for (var i = 0; i < 30; i++) 'line $i'].join('\n');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolEditDiffCard(
                activity: acpEdit('gen.txt', null, after),
              ),
            ),
          ),
        ),
      );
      expect(diffRows(tester), hasLength(kDiffCardCollapsedRows));
      final more = find.text('Show ${31 - kDiffCardCollapsedRows} more lines');
      expect(more, findsOneWidget);

      await tester.tap(more);
      await tester.pump();
      expect(diffRows(tester), hasLength(31));
    });

    testWidgets('a folded stretch opens where it is', (tester) async {
      final before = [for (var i = 0; i < 40; i++) 'line $i'];
      final after = [...before]..[20] = 'changed';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolEditDiffCard(
                activity: acpEdit('f', before.join('\n'), after.join('\n')),
              ),
            ),
          ),
        ),
      );
      // 20 lines above the change, 3 kept as context; the 16 below are past
      // the collapsed head.
      final fold = find.text('17 unchanged lines');
      expect(fold, findsOneWidget);
      expect(diffRows(tester), isNot(contains(' line 0')));
      await tester.tap(fold);
      await tester.pump();
      expect(diffRows(tester), contains(' line 0'));
    });

    testWidgets('at phone width the file name survives a long path', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const dir =
          r'C:\Users\someone\projects\a-rather-deep\monorepo\packages\feature';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolEditDiffCard(
              activity: acpEdit('$dir\\settings_screen.dart', 'a', 'b'),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final name = find.text('settings_screen.dart');
      expect(name, findsOneWidget);
      final box = tester.getRect(name);
      expect(box.right, lessThanOrEqualTo(390));
      expect(box.width, greaterThan(0));
    });

    testWidgets('a cut change says so', (tester) async {
      final tool = ToolActivity(
        name: 'Write',
        edits: const [
          FileEditRecord(path: 'big', kind: FileEditKind.created, newText: 'x'),
        ],
        editsTruncated: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ToolEditDiffCard(activity: tool)),
        ),
      );
      expect(shown('cut to fit'), findsOneWidget);
    });
  });

  group('per-turn files', () {
    test('only the last batch of a turn carries the turn\'s files', () {
      final messages = [
        said('do it', role: 'user'),
        call(cliEdit('/a', 'x', 'y')),
        call(toolActivityFor('Read', {'file_path': '/b'})),
        said('halfway'),
        call(acpEdit('/c', null, 'new')),
        call(cliEdit('/a', 'y', 'z')),
        said('next', role: 'user'),
        call(cliEdit('/d', '1', '2')),
      ];
      final rows = transcriptRows(messages, turn: TranscriptTurn.idle);
      final batches = rows.where((r) => r.isBatch).toList();
      expect(turnChangedFiles(messages, batches[0]), isNull);

      final files = turnChangedFiles(messages, batches[1])!;
      expect(files.map((f) => (f.path, f.kind)), [
        ('/a', FileEditKind.modified),
        ('/c', FileEditKind.created),
      ]);
      expect(files.first.edits, hasLength(2));
      expect(files.first.added, 2);
      expect(files.first.removed, 2);

      expect(turnChangedFiles(messages, batches[2])!.single.path, '/d');
    });

    test('a turn that wrote nothing has no line', () {
      final messages = [
        said('look', role: 'user'),
        call(toolActivityFor('Read', {'file_path': '/b'})),
      ];
      final row = transcriptRows(messages, turn: TranscriptTurn.idle).last;
      expect(turnChangedFiles(messages, row), isNull);
    });
  });

  group('in the chat', () {
    for (final (source, edit) in [
      ('a CLI agent', cliEdit('/src/a.dart', 'old line', 'new line')),
      ('an ACP agent', acpEdit('/src/a.dart', 'old line', 'new line')),
    ]) {
      testWidgets('$source: the turn names its files and opens to the diff', (
        tester,
      ) async {
        await tester.pumpWidget(
          view([said('fix it', role: 'user'), call(edit), said('done')]),
        );
        await tester.pumpAndSettle();

        expect(shown('Edited 1 file'), findsOneWidget);
        final line = find.text('1 file changed');
        expect(line, findsOneWidget);
        expect(find.byType(DiffLineTile), findsNothing);

        await tester.tap(line);
        await tester.pumpAndSettle();
        expect(diffRows(tester), ['-old line', '+new line']);
      });

      testWidgets('$source: an opened batch shows the diff under the call', (
        tester,
      ) async {
        await tester.pumpWidget(
          view([said('fix it', role: 'user'), call(edit), said('done')]),
        );
        await tester.pumpAndSettle();
        await tester.tap(shown('Edited 1 file'));
        await tester.pumpAndSettle();
        expect(diffRows(tester), ['-old line', '+new line']);
      });
    }
  });
}
