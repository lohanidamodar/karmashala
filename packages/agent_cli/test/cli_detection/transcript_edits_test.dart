import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/codex/codex_patch_edits.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:agent_cli/src/sessions/tool_activity.dart';
import 'package:test/test.dart';

/// An edit's content rides on its tool row, so the chat can draw the diff
/// without a second read of the transcript.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('edit-transcript');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<String> write(String name, List<Map<String, Object?>> lines) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString(lines.map(jsonEncode).join('\n'));
    return file.path;
  }

  Map<String, Object?> claudeCall(String name, Map<String, Object?> input) => {
    'type': 'assistant',
    'timestamp': '2026-10-04T10:00:00.000Z',
    'message': {
      'content': [
        {'type': 'tool_use', 'id': 'toolu_1', 'name': name, 'input': input},
      ],
    },
  };

  Map<String, Object?> codexCall(Map<String, Object?> payload) => {
    'timestamp': '2026-10-04T10:00:00.000Z',
    'type': 'response_item',
    'payload': payload,
  };

  group('Claude Code', () {
    test('an Edit carries the text it replaced and its replacement', () async {
      final path = await write('edit.jsonl', [
        claudeCall('Edit', {
          'file_path': '/src/a.dart',
          'old_string': 'int a = 1;',
          'new_string': 'int a = 2;',
        }),
      ]);

      final tool = (await readCliTranscript(
        path,
        AgentIds.claudeCode,
      )).single.tool!;
      final edit = tool.edits.single;
      expect(edit.path, '/src/a.dart');
      expect(edit.kind, FileEditKind.modified);
      expect(edit.oldText, 'int a = 1;');
      expect(edit.newText, 'int a = 2;');
      expect(tool.editsTruncated, isFalse);
    });

    test(
      'a MultiEdit is one edit per replacement, a Write its content',
      () async {
        final path = await write('multi.jsonl', [
          claudeCall('MultiEdit', {
            'file_path': '/src/b.dart',
            'edits': [
              {'old_string': 'a', 'new_string': 'b'},
              {'old_string': 'c', 'new_string': 'd'},
            ],
          }),
          claudeCall('Write', {
            'file_path': '/src/c.dart',
            'content': 'x\ny\n',
          }),
        ]);

        final rows = await readCliTranscript(path, AgentIds.claudeCode);
        expect(rows[0].tool!.edits.map((e) => e.newText), ['b', 'd']);
        expect(rows[1].tool!.edits.single.newText, 'x\ny\n');
      },
    );

    test('a call that edits nothing carries no edits', () async {
      final path = await write('read.jsonl', [
        claudeCall('Read', {'file_path': '/src/a.dart'}),
      ]);
      final tool = (await readCliTranscript(
        path,
        AgentIds.claudeCode,
      )).single.tool!;
      expect(tool.edits, isEmpty);
    });

    Map<String, Object?> claudeResult(Map<String, Object?> toolUseResult) => {
      'type': 'user',
      'timestamp': '2026-10-04T10:00:01.000Z',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_1',
            'content': 'The file has been updated.',
          },
        ],
      },
      'toolUseResult': toolUseResult,
    };

    test('the result\'s structuredPatch replaces the input, with line '
        'numbers', () async {
      final path = await write('edit-result.jsonl', [
        claudeCall('MultiEdit', {
          'file_path': '/src/a.dart',
          'edits': [
            {'old_string': 'b', 'new_string': 'c'},
            {'old_string': 'x', 'new_string': 'y'},
          ],
        }),
        claudeResult({
          'filePath': '/src/a.dart',
          'oldString': 'b',
          'newString': 'c',
          'originalFile': 'a\nb\nd\nx\n',
          'structuredPatch': [
            {
              'oldStart': 10,
              'oldLines': 4,
              'newStart': 10,
              'newLines': 4,
              'lines': [' a', '-b', '+c', ' d', '-x', '+y'],
            },
          ],
        }),
      ]);

      final tool = (await readCliTranscript(
        path,
        AgentIds.claudeCode,
      )).single.tool!;
      final edit = tool.edits.single;
      expect(edit.recordedDiff, startsWith('@@ -10,4 +10,4 @@\n a\n-b\n+c'));
      expect(edit.oldText, isNull, reason: 'the whole file is not carried');
      expect(tool.output, 'The file has been updated.');
    });

    test('a Write that created its file reads as created', () async {
      final path = await write('write-result.jsonl', [
        claudeCall('Write', {'file_path': '/src/new.dart', 'content': 'x\n'}),
        claudeResult({
          'type': 'create',
          'filePath': '/src/new.dart',
          'content': 'x\n',
          'structuredPatch': <Object?>[],
        }),
      ]);
      final edit = (await readCliTranscript(
        path,
        AgentIds.claudeCode,
      )).single.tool!.edits.single;
      expect(edit.kind, FileEditKind.created);
      expect(edit.newText, 'x\n');
    });

    test('a failed edit keeps what the input asked for', () async {
      final path = await write('edit-failed.jsonl', [
        claudeCall('Edit', {
          'file_path': '/src/a.dart',
          'old_string': 'a',
          'new_string': 'b',
        }),
        {
          'type': 'user',
          'message': {
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'toolu_1',
                'content': 'String not found',
                'is_error': true,
              },
            ],
          },
          'toolUseResult': 'Error: String not found',
        },
      ]);
      final tool = (await readCliTranscript(
        path,
        AgentIds.claudeCode,
      )).single.tool!;
      expect(tool.isError, isTrue);
      expect(tool.edits.single.newText, 'b');
    });
  });

  group('Codex', () {
    const patch =
        '*** Begin Patch\n'
        '*** Add File: docs/new.md\n'
        '+# Title\n'
        '+body\n'
        '*** Update File: lib/main.dart\n'
        '*** Move to: lib/app.dart\n'
        '@@ void main() {\n'
        '   print(1);\n'
        '-  print(2);\n'
        '+  print(3);\n'
        '*** Delete File: old.txt\n'
        '*** End Patch';

    test('an apply_patch call carries one edit per file', () async {
      final path = await write('codex.jsonl', [
        codexCall({
          'type': 'custom_tool_call',
          'name': 'apply_patch',
          'call_id': 'call_1',
          'input': patch,
        }),
      ]);

      final tool = (await readCliTranscript(path, AgentIds.codex)).single.tool!;
      expect(tool.edits.map((e) => (e.path, e.kind)), [
        ('docs/new.md', FileEditKind.created),
        ('lib/main.dart', FileEditKind.modified),
        ('old.txt', FileEditKind.deleted),
      ]);
      expect(tool.edits[0].newText, '# Title\nbody');
      expect(tool.edits[1].renamedTo, 'lib/app.dart');
      expect(
        tool.edits[1].recordedDiff,
        '@@ void main() {\n   print(1);\n-  print(2);\n+  print(3);',
      );
      // The patch's first line said nothing about what it touched.
      expect(tool.subject, 'docs/new.md');
    });

    test('the function_call form carries its patch in `input`', () async {
      final path = await write('codex-fn.jsonl', [
        codexCall({
          'type': 'function_call',
          'name': 'apply_patch',
          'call_id': 'call_2',
          'arguments': jsonEncode({'input': patch}),
        }),
      ]);
      final tool = (await readCliTranscript(path, AgentIds.codex)).single.tool!;
      expect(tool.edits, hasLength(3));
    });

    test('a patch with no file header reads as no edits', () {
      expect(codexPatchEdits('*** Begin Patch\n*** End Patch'), isEmpty);
      expect(codexPatchEdits('not a patch'), isEmpty);
    });
  });

  group('bounds', () {
    test('small edits pass through untouched', () {
      const edit = FileEditRecord(
        path: 'a',
        kind: FileEditKind.modified,
        oldText: 'x',
        newText: 'y',
      );
      final (kept, cut) = boundedToolEdits(const [edit]);
      expect(identical(kept.single, edit), isTrue);
      expect(cut, isFalse);
    });

    test('a whole-file pair keeps only the changed region and its context', () {
      final lines = [for (var i = 0; i < 20000; i++) 'line $i'];
      final before = lines.join('\n');
      lines[10000] = 'changed';
      final after = lines.join('\n');

      final (kept, cut) = boundedToolEdits([
        FileEditRecord(
          path: 'big',
          kind: FileEditKind.modified,
          oldText: before,
          newText: after,
        ),
      ]);
      expect(cut, isFalse, reason: 'nothing that differs was dropped');
      expect(kept.single.oldText!.split('\n'), [
        for (
          var i = 10000 - kToolEditContextLines;
          i <= 10000 + kToolEditContextLines;
          i++
        )
          'line $i',
      ]);
      expect(
        kept.single.newText!.split('\n')[kToolEditContextLines],
        'changed',
      );
    });

    test('content past the budget is cut and says so', () {
      final huge = List.filled(20000, 'new line of text').join('\n');
      final (kept, cut) = boundedToolEdits([
        FileEditRecord(path: 'n', kind: FileEditKind.created, newText: huge),
      ]);
      expect(cut, isTrue);
      expect(kept.single.newText!.length, lessThanOrEqualTo(kMaxToolEditChars));
      expect(kept.single.newText!.endsWith('\n'), isFalse);
    });

    test('past the edit count, the rest are dropped and it says so', () {
      final many = [
        for (var i = 0; i < kMaxToolEdits + 5; i++)
          FileEditRecord(path: '$i', kind: FileEditKind.modified, newText: 'x'),
      ];
      final (kept, cut) = boundedToolEdits(many);
      expect(kept, hasLength(kMaxToolEdits));
      expect(cut, isTrue);
    });
  });

  test('the wire form carries kind and edits', () {
    const activity = ToolActivity(
      name: 'Edit',
      kind: 'edit',
      edits: [
        FileEditRecord(
          path: '/a',
          kind: FileEditKind.created,
          toolName: 'Write',
          newText: 'x',
        ),
        FileEditRecord(
          path: '/b',
          kind: FileEditKind.modified,
          recordedDiff: '@@\n-a\n+b',
          renamedTo: '/c',
        ),
      ],
      editsTruncated: true,
    );
    final back = ToolActivity.fromJson(
      jsonDecode(jsonEncode(activity.toJson())) as Map<String, Object?>,
    );
    expect(back.kind, 'edit');
    expect(back.edits, activity.edits);
    expect(back.editsTruncated, isTrue);
    expect(back.withResult(output: 'ok').edits, activity.edits);

    final plain = const ToolActivity(name: 'Read').toJson();
    expect(plain.containsKey('edits'), isFalse);
    expect(plain.containsKey('kind'), isFalse);
  });
}
