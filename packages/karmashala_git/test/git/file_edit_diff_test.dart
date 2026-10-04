import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

/// The shapes here are copied off real transcripts on this machine. If they
/// drift the feature degrades to "no diff recorded", never to a wrong one.
void main() {
  setUp(clearFileEditDiffCache);

  group('reading Claude Code records', () {
    test('an Edit tool call carries the fragment it replaced', () {
      final edits = claudeFileEdits({
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'Edit',
              'input': {
                'file_path': '/repo/lib/a.dart',
                'old_string': 'final a = 1;',
                'new_string': 'final a = 2;',
              },
            },
          ],
        },
      });

      expect(edits, hasLength(1));
      expect(edits.single.path, '/repo/lib/a.dart');
      expect(edits.single.kind, FileEditKind.modified);
      expect(edits.single.oldText, 'final a = 1;');
      expect(edits.single.newText, 'final a = 2;');
      expect(edits.single.toolName, 'Edit');
    });

    test('a Write tool call with no result yet is a whole new body', () {
      final edits = claudeFileEdits({
        'type': 'assistant',
        'message': {
          'content': [
            {
              'type': 'tool_use',
              'name': 'Write',
              'input': {'file_path': '/repo/new.txt', 'content': 'hello\n'},
            },
          ],
        },
      });

      expect(edits.single.newText, 'hello\n');
      expect(edits.single.oldText, isNull);
    });

    test('MultiEdit reports every replacement it made to the file', () {
      final edits = claudeFileEdits({
        'type': 'assistant',
        'message': {
          'content': [
            {
              'type': 'tool_use',
              'name': 'MultiEdit',
              'input': {
                'file_path': '/repo/m.dart',
                'edits': [
                  {'old_string': 'one', 'new_string': 'ONE'},
                  {'old_string': 'two', 'new_string': 'TWO'},
                ],
              },
            },
          ],
        },
      });

      expect(edits, hasLength(2));
      expect(edits.map((e) => e.newText), ['ONE', 'TWO']);
      expect(edits.every((e) => e.path == '/repo/m.dart'), isTrue);
    });

    test('the tool result carries the patch the agent itself computed', () {
      final edits = claudeFileEdits({
        'type': 'user',
        'toolUseResult': {
          'filePath': '/repo/lib/a.dart',
          'oldString': 'final a = 1;',
          'newString': 'final a = 2;',
          'originalFile': 'final a = 1;\n',
          'structuredPatch': [
            {
              'oldStart': 1,
              'oldLines': 1,
              'newStart': 1,
              'newLines': 1,
              'lines': ['-final a = 1;', '+final a = 2;'],
            },
          ],
        },
      });

      expect(edits.single.kind, FileEditKind.modified);
      expect(
        edits.single.recordedDiff,
        '@@ -1,1 +1,1 @@\n-final a = 1;\n+final a = 2;',
      );
    });

    test('a created file is recorded with an empty patch and its content', () {
      // Claude records `type: create`, `originalFile: null` and — the trap —
      // an EMPTY structuredPatch, so a reader that trusts the patch shows a
      // new file as "nothing changed".
      final edits = claudeFileEdits({
        'type': 'user',
        'toolUseResult': {
          'type': 'create',
          'filePath': '/repo/new.txt',
          'content': 'one\ntwo\n',
          'originalFile': null,
          'structuredPatch': <Object?>[],
        },
      });

      expect(edits.single.kind, FileEditKind.created);
      expect(edits.single.newText, 'one\ntwo\n');
      expect(edits.single.recordedDiff, isNull);
    });

    test('lines that are not file writes are ignored', () {
      expect(
        claudeFileEdits({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': 'thinking'},
              {
                'type': 'tool_use',
                'name': 'Bash',
                'input': {'command': 'ls'},
              },
            ],
          },
        }),
        isEmpty,
      );
      expect(claudeFileEdits({'type': 'summary'}), isEmpty);
    });
  });

  group('reading Codex records', () {
    Map<String, Object?> patchApply(Map<String, Object?> changes) => {
      'payload': {
        'type': 'patch_apply_end',
        'success': true,
        'changes': changes,
      },
    };

    test('an update carries the unified diff Codex applied', () {
      final edits = codexFileEdits(
        patchApply({
          '/repo/a.md': {
            'type': 'update',
            'move_path': null,
            'unified_diff': '@@ -1,1 +1,1 @@\n-old\n+new\n',
          },
        }),
      );

      expect(edits.single.path, '/repo/a.md');
      expect(edits.single.kind, FileEditKind.modified);
      expect(edits.single.recordedDiff, '@@ -1,1 +1,1 @@\n-old\n+new\n');
    });

    test('an add is a created file and a delete keeps the body removed', () {
      final edits = codexFileEdits(
        patchApply({
          '/repo/added.gd': {'type': 'add', 'content': 'a\nb\n'},
          '/repo/gone.gd': {'type': 'delete', 'content': 'x\ny\n'},
        }),
      );

      expect(edits, hasLength(2));
      final added = edits.firstWhere((e) => e.path.endsWith('added.gd'));
      final gone = edits.firstWhere((e) => e.path.endsWith('gone.gd'));
      expect(added.kind, FileEditKind.created);
      expect(added.newText, 'a\nb\n');
      expect(gone.kind, FileEditKind.deleted);
      expect(gone.oldText, 'x\ny\n');
      expect(gone.newText, isNull);
    });

    test('a failed patch is not reported as a change', () {
      expect(
        codexFileEdits({
          'payload': {
            'type': 'patch_apply_end',
            'success': false,
            'changes': {
              '/repo/a.md': {'type': 'add', 'content': 'x'},
            },
          },
        }),
        isEmpty,
      );
    });
  });

  test("a transcript line is read by the right agent's rules", () {
    final claude = {
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'name': 'Write',
            'input': {'file_path': '/a', 'content': 'x'},
          },
        ],
      },
    };
    expect(
      (const ClaudeCodeAdapter().fileChanges as TranscriptFileEdits)
          .editsOnLine(claude),
      hasLength(1),
    );
    // Codex rules find nothing in a Claude line, and vice versa — the readers
    // must not both fire on one line and double-report an edit.
    expect(codexFileEdits(claude), isEmpty);
  });

  group('collecting a whole transcript', () {
    test('a call and its result are one edit, not two', () {
      final collector = ClaudeFileEditCollector()
        ..add({
          'type': 'assistant',
          'message': {
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'Edit',
                'input': {
                  'file_path': '/repo/a.dart',
                  'old_string': 'x',
                  'new_string': 'y',
                },
              },
            ],
          },
        })
        ..add({
          'type': 'user',
          'message': {
            'content': [
              {'type': 'tool_result', 'tool_use_id': 'toolu_1'},
            ],
          },
          'toolUseResult': {
            'filePath': '/repo/a.dart',
            'oldString': 'x',
            'newString': 'y',
            'structuredPatch': [
              {
                'oldStart': 7,
                'oldLines': 1,
                'newStart': 7,
                'newLines': 1,
                'lines': ['-x', '+y'],
              },
            ],
          },
        });

      // One row, upgraded in place to the version that knows where the change
      // landed — not the fragment followed by the patch.
      expect(collector.edits, hasLength(1));
      expect(collector.edits.single.recordedDiff, contains('@@ -7,1 +7,1 @@'));
    });

    test('an unmatched result is still an edit', () {
      final collector = ClaudeFileEditCollector()
        ..add({
          'type': 'user',
          'toolUseResult': {
            'type': 'create',
            'filePath': '/repo/new.txt',
            'content': 'hi\n',
            'structuredPatch': <Object?>[],
          },
        });
      expect(collector.edits.single.kind, FileEditKind.created);
    });

    test('Codex patches are collected in the order they were applied', () {
      final lines = [
        {
          'payload': {
            'type': 'patch_apply_end',
            'success': true,
            'changes': {
              '/repo/one.md': {'type': 'add', 'content': 'a\n'},
            },
          },
        },
        {
          'payload': {
            'type': 'patch_apply_end',
            'success': true,
            'changes': {
              '/repo/two.md': {'type': 'add', 'content': 'b\n'},
            },
          },
        },
      ];
      final edits = [for (final line in lines) ...codexFileEdits(line)];
      expect(edits.map((e) => e.path), ['/repo/one.md', '/repo/two.md']);
    });
  });

  test('a live tool.call event is enough to show what is being written', () {
    // The engine's `tool.call` payload has the input and no result: this is the
    // in-flight form, and it must still produce a diff.
    final edits = fileEditsFromToolCall(
      name: 'Edit',
      input: {
        'file_path': '/repo/a.dart',
        'old_string': 'x',
        'new_string': 'y',
      },
    );
    expect(edits.single.newText, 'y');
  });

  group('building the diff', () {
    test('a normal edit becomes added and removed lines', () {
      final diff = buildFileEditDiff(
        const FileEditRecord(
          path: '/repo/a.dart',
          kind: FileEditKind.modified,
          toolName: 'Edit',
          oldText: 'one\ntwo\nthree\n',
          newText: 'one\nTWO\nthree\n',
        ),
      );

      expect(diff.status, FileEditDiffStatus.ok);
      expect(diff.added, 1);
      expect(diff.removed, 1);
      expect(
        diff.lines.where((l) => l.kind == DiffLineKind.removed).single.text,
        '-two',
      );
      expect(
        diff.lines.where((l) => l.kind == DiffLineKind.added).single.text,
        '+TWO',
      );
      // Context is kept so a reader can see where the change landed.
      expect(
        diff.lines
            .where((l) => l.kind == DiffLineKind.context)
            .map((l) => l.text),
        [' one', ' three'],
      );
    });

    test('a recorded patch is rendered as-is rather than recomputed', () {
      final diff = buildFileEditDiff(
        const FileEditRecord(
          path: '/repo/a.dart',
          kind: FileEditKind.modified,
          recordedDiff: '@@ -1,2 +1,2 @@\n ctx\n-old\n+new',
        ),
      );

      expect(diff.status, FileEditDiffStatus.ok);
      expect(diff.lines.first.kind, DiffLineKind.hunk);
      expect(diff.added, 1);
      expect(diff.removed, 1);
    });

    test('a real-shaped Edit result keeps its line numbers, context and '
        'counts, even for content that starts with -- or ++', () {
      // The shape Claude Code writes: every patch line carries its own
      // ' ', '+' or '-' prefix. Contents are made up.
      final edit = claudeFileEdits({
        'type': 'user',
        'toolUseResult': {
          'filePath': '/repo/docs/config.md',
          'oldString': 'retries: 3',
          'newString': 'retries: 5',
          'originalFile': 'title: Demo\n---\nretries: 3\n',
          'structuredPatch': [
            {
              'oldStart': 40,
              'oldLines': 5,
              'newStart': 40,
              'newLines': 5,
              'lines': [
                ' title: Demo',
                '----',
                '+++ notes',
                '-retries: 3',
                '+retries: 5',
                ' timeout: 10',
                ' ',
              ],
            },
          ],
          'userModified': false,
          'replaceAll': false,
        },
      }).single;

      expect(
        edit.recordedDiff,
        '@@ -40,5 +40,5 @@\n title: Demo\n----\n+++ notes\n'
        '-retries: 3\n+retries: 5\n timeout: 10\n ',
      );
      final diff = buildFileEditDiff(edit);
      expect(diff.status, FileEditDiffStatus.ok);
      expect(diff.added, 2);
      expect(diff.removed, 2);
      expect(diff.lines.map((l) => l.kind), [
        DiffLineKind.hunk,
        DiffLineKind.context,
        DiffLineKind.removed,
        DiffLineKind.added,
        DiffLineKind.removed,
        DiffLineKind.added,
        DiffLineKind.context,
        DiffLineKind.context,
      ]);
      expect(newFileLineNumbers(diff.lines), [
        null,
        40,
        null,
        41,
        null,
        42,
        43,
        44,
      ]);
    });

    test('a new file is all additions and says so', () {
      final diff = buildFileEditDiff(
        const FileEditRecord(
          path: '/repo/new.txt',
          kind: FileEditKind.created,
          newText: 'a\nb\nc\n',
        ),
      );

      expect(diff.status, FileEditDiffStatus.ok);
      expect(diff.added, 3);
      expect(diff.removed, 0);
      expect(
        diff.lines.where((l) => l.kind != DiffLineKind.hunk).map((l) => l.text),
        ['+a', '+b', '+c'],
      );
    });

    test('a deleted file is all removals', () {
      final diff = buildFileEditDiff(
        const FileEditRecord(
          path: '/repo/gone.txt',
          kind: FileEditKind.deleted,
          oldText: 'a\nb\n',
        ),
      );

      expect(diff.added, 0);
      expect(diff.removed, 2);
      expect(
        diff.lines.where((l) => l.kind != DiffLineKind.hunk).map((l) => l.text),
        ['-a', '-b'],
      );
    });

    test('a file with no textual content is undiffable, not empty', () {
      final diff = buildFileEditDiff(
        FileEditRecord(
          path: '/repo/logo.png',
          kind: FileEditKind.created,
          // A NUL byte is what tells a PNG from source; git uses the same rule.
          newText: 'PNG\u0000\u001a\nIHDR\u0000',
        ),
      );

      expect(diff.status, FileEditDiffStatus.binary);
      expect(diff.lines, isEmpty);
      // A binary write still happened; the counts must not claim otherwise.
      expect(diff.added, 0);
      expect(diff.removed, 0);
    });

    test('a write too large to diff reports its size instead of hanging', () {
      final huge = List.filled(60000, 'a line of text').join('\n');
      expect(huge.length, greaterThan(kFileEditMaxBytes));

      final diff = buildFileEditDiff(
        FileEditRecord(
          path: '/repo/huge.txt',
          kind: FileEditKind.modified,
          oldText: huge,
          newText: '$huge\nand one more',
        ),
      );

      expect(diff.status, FileEditDiffStatus.tooLarge);
      expect(diff.lines, isEmpty);
    });

    test('a very long recorded patch is truncated rather than dropped', () {
      final patch = [
        '@@ -1,${kFileEditMaxLines * 2} +1,${kFileEditMaxLines * 2} @@',
        for (var i = 0; i < kFileEditMaxLines * 2; i++) '+line $i',
      ].join('\n');

      final diff = buildFileEditDiff(
        FileEditRecord(
          path: '/repo/big.txt',
          kind: FileEditKind.modified,
          recordedDiff: patch,
        ),
      );

      expect(diff.status, FileEditDiffStatus.ok);
      expect(diff.truncated, isTrue);
      expect(diff.lines.length, lessThanOrEqualTo(kFileEditMaxLines));
      // The counts describe the whole change, not just the part shown.
      expect(diff.added, kFileEditMaxLines * 2);
    });

    test('an edit that changed nothing says nothing changed', () {
      final diff = buildFileEditDiff(
        const FileEditRecord(
          path: '/repo/a.dart',
          kind: FileEditKind.modified,
          oldText: 'same\n',
          newText: 'same\n',
        ),
      );
      expect(diff.status, FileEditDiffStatus.empty);
    });

    test(
      'a rewrite bigger than the alignment budget still shows both sides',
      () {
        // Beyond the budget the diff degrades to "all of the old, all of the
        // new" — a coarse answer, never a missing one, and never an O(n*m) hang.
        final oldText = List.generate(1200, (i) => 'old $i').join('\n');
        final newText = List.generate(1200, (i) => 'new $i').join('\n');
        final diff = buildFileEditDiff(
          FileEditRecord(
            path: '/repo/rewritten.txt',
            kind: FileEditKind.modified,
            oldText: oldText,
            newText: newText,
          ),
        );

        expect(diff.status, FileEditDiffStatus.ok);
        expect(diff.added, 1200);
        expect(diff.removed, 1200);
      },
    );

    test('the same record is not diffed twice', () {
      const record = FileEditRecord(
        path: '/repo/a.dart',
        kind: FileEditKind.modified,
        oldText: 'one\ntwo\n',
        newText: 'one\nTWO\n',
      );
      final before = fileEditDiffComputations;
      buildFileEditDiff(record);
      buildFileEditDiff(record);
      // A different instance holding the same change is the same diff: the
      // transcript re-parses its file every poll tick and hands over new objects.
      buildFileEditDiff(
        const FileEditRecord(
          path: '/repo/a.dart',
          kind: FileEditKind.modified,
          oldText: 'one\ntwo\n',
          newText: 'one\nTWO\n',
        ),
      );
      expect(fileEditDiffComputations - before, 1);
    });
  });
}
