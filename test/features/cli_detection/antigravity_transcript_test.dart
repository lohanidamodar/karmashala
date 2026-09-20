import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// Antigravity's messages, where the store keeps a readable copy of them.
///
/// The line shapes below are the ones the WSL install writes; see
/// `_parseAntigravityLine` for the survey they were taken from.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_agy_'));
  tearDown(() => removeTempDirectory(tmp));

  String storeHome() => p.join(tmp.path, '.gemini', 'antigravity-cli');
  String conversationFile(String id) =>
      p.join(storeHome(), 'conversations', '$id.db');

  /// Writes [lines] where the CLI puts them for conversation [id].
  String writeTranscript(String id, List<Map<String, Object?>> lines) {
    final path = p.join(
      storeHome(),
      'brain',
      id,
      '.system_generated',
      'logs',
      'transcript.jsonl',
    );
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync(lines.map(jsonEncode).join('\n'));
    return path;
  }

  group('antigravityTranscriptPathFor', () {
    test('a path we were given is returned as it came', () {
      // The hooks payload's own `transcriptPath`. Taken, never rebuilt: the
      // documented shape is under the workspace, which is not where this
      // install keeps it, so reconstruction is the fallback and not the rule.
      const given = '/home/u/somewhere/else/transcript.jsonl';
      expect(antigravityTranscriptPathFor(given), given);
    });

    test('a conversation file resolves to the brain transcript beside it', () {
      final resolved = antigravityTranscriptPathFor(conversationFile('abc'));
      expect(
        resolved,
        p.join(
          storeHome(),
          'brain',
          'abc',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
      );
    });

    test('anything else resolves to nothing, rather than to a guess', () {
      expect(antigravityTranscriptPathFor('/home/u/notes.txt'), isNull);
      expect(antigravityTranscriptPathFor(p.join(tmp.path, 'x.db')), isNull);
    });
  });

  group('readCliTranscript', () {
    test('a conversation with no transcript is still refused', () async {
      // The Windows install here is exactly this: one brain directory, empty,
      // and a `conversations/<id>.pb` beside it. The refusal is the answer.
      final rows = await readCliTranscript(
        conversationFile('missing'),
        AgentIds.antigravity,
      );
      expect(rows, isEmpty);
    });

    test('a user turn, a model turn, a call and its result', () async {
      const id = 'conv-1';
      writeTranscript(id, [
        {
          'step_index': 0,
          'source': 'USER_EXPLICIT',
          'type': 'USER_INPUT',
          'status': 'DONE',
          'created_at': '2026-09-08T14:15:06Z',
          'content': 'list the folder',
        },
        {
          'step_index': 1,
          'source': 'MODEL',
          'type': 'PLANNER_RESPONSE',
          'status': 'DONE',
          'created_at': '2026-09-08T14:15:07Z',
          'content': 'Listing it now.',
          'tool_calls': [
            {
              'name': 'run_command',
              'args': {'CommandLine': 'ls -1', 'Cwd': '/tmp'},
            },
          ],
        },
        {
          'step_index': 2,
          'source': 'MODEL',
          'type': 'GENERIC',
          'status': 'DONE',
          'created_at': '2026-09-08T14:15:09Z',
          'content': 'The command exited with code 0.\nOutput:\na.txt',
        },
      ]);

      final rows = await readCliTranscript(
        conversationFile(id),
        AgentIds.antigravity,
      );

      expect(rows.map((r) => r.role), ['user', 'agent', 'tool']);
      expect(rows[0].text, 'list the folder');
      expect(rows[1].text, 'Listing it now.');
      expect(rows[2].tool?.name, 'run_command');
      expect(rows[2].tool?.output, contains('a.txt'));
      // `created_at`, not a clock of ours.
      expect(rows[0].at, DateTime.utc(2026, 9, 8, 14, 15, 6));
    });

    test('a result with no call above it becomes a row of its own', () async {
      const id = 'conv-2';
      writeTranscript(id, [
        {
          'step_index': 0,
          'source': 'MODEL',
          'type': 'GENERIC',
          'status': 'DONE',
          'created_at': '2026-09-08T14:15:09Z',
          'content': 'orphaned output',
        },
      ]);

      final rows = await readCliTranscript(
        conversationFile(id),
        AgentIds.antigravity,
      );
      expect(rows.single.role, 'tool');
      expect(rows.single.text, 'orphaned output');
      expect(rows.single.tool, isNull);
    });

    test(
      'a call the file says is RUNNING is the one reported in flight',
      () async {
        const id = 'conv-3';
        writeTranscript(id, [
          {
            'step_index': 7,
            'source': 'MODEL',
            'type': 'PLANNER_RESPONSE',
            'status': 'RUNNING',
            'created_at': '2026-09-08T14:15:07Z',
            'tool_calls': [
              {
                'name': 'run_command',
                'args': {'CommandLine': 'sleep 60'},
              },
            ],
          },
        ]);

        final rows = await readCliTranscript(
          conversationFile(id),
          AgentIds.antigravity,
        );
        expect(rows.single.pendingToolUseId, '7');
      },
    );

    test('SYSTEM records render nothing, and a bad line is skipped', () async {
      const id = 'conv-4';
      final path = writeTranscript(id, [
        {
          'step_index': 0,
          'source': 'SYSTEM',
          'type': 'SYSTEM_MESSAGE',
          'status': 'DONE',
          'created_at': '2026-09-08T14:15:06Z',
          'content': 'injected context',
        },
        {
          'step_index': 1,
          'source': 'USER_EXPLICIT',
          'type': 'USER_INPUT',
          'status': 'DONE',
          'created_at': '2026-09-08T14:15:07Z',
          'content': 'the only turn',
        },
      ]);
      File(path).writeAsStringSync(
        '${File(path).readAsStringSync()}\nnot json at all\n',
      );

      final rows = await readCliTranscript(
        conversationFile(id),
        AgentIds.antigravity,
      );
      expect(rows.map((r) => r.text), ['the only turn']);
    });
  });

  /// **The reasoning the CLI writes, and where it lands.**
  ///
  /// Surveyed over the same 4,846 lines as the shapes above: 435 carry a
  /// `thinking` field, every one of them a `PLANNER_RESPONSE` with
  /// `status: DONE`. Only **9** also carry `content`, **425** carry
  /// `tool_calls` and no text at all, and **1** carries neither — so a rule
  /// that only hung it on the text row would show 9 of 435. It rides on the
  /// first row the record produces, and no row is created to hold it.
  group('thinking', () {
    test('a record that only calls a tool puts it on the call', () async {
      const id = 'think-1';
      writeTranscript(id, [
        {
          'step_index': 4,
          'source': 'MODEL',
          'type': 'PLANNER_RESPONSE',
          'status': 'DONE',
          'created_at': '2026-09-09T10:00:01Z',
          'thinking': 'the folder first, then the diff',
          'tool_calls': [
            {
              'name': 'run_command',
              'args': {'CommandLine': '"ls -1"'},
            },
          ],
        },
      ]);

      final rows = await readCliTranscript(
        conversationFile(id),
        AgentIds.antigravity,
      );

      expect(rows.single.role, 'tool');
      expect(rows.single.thinking, 'the folder first, then the diff');
    });

    test('and it survives the result landing on that call', () async {
      // 2,261 of the 2,310 calls here are answered by the very next line, and
      // answering rebuilds the row — so this is the case, not the corner.
      const id = 'think-2';
      writeTranscript(id, [
        {
          'step_index': 4,
          'source': 'MODEL',
          'type': 'PLANNER_RESPONSE',
          'status': 'DONE',
          'created_at': '2026-09-09T10:00:01Z',
          'thinking': 'the folder first, then the diff',
          'tool_calls': [
            {
              'name': 'run_command',
              'args': {'CommandLine': '"ls -1"'},
            },
          ],
        },
        {
          'step_index': 5,
          'source': 'MODEL',
          'type': 'GENERIC',
          'status': 'DONE',
          'created_at': '2026-09-09T10:00:02Z',
          'content': 'a.txt',
        },
      ]);

      final rows = await readCliTranscript(
        conversationFile(id),
        AgentIds.antigravity,
      );

      expect(rows.single.tool?.output, contains('a.txt'));
      expect(rows.single.thinking, 'the folder first, then the diff');
    });

    test('a record with text puts it on the text row', () async {
      const id = 'think-3';
      writeTranscript(id, [
        {
          'step_index': 6,
          'source': 'MODEL',
          'type': 'PLANNER_RESPONSE',
          'status': 'DONE',
          'created_at': '2026-09-09T10:00:03Z',
          'thinking': 'nothing left to check',
          'content': 'Done.',
        },
      ]);

      final rows = await readCliTranscript(
        conversationFile(id),
        AgentIds.antigravity,
      );

      expect(rows.single.role, 'agent');
      expect(rows.single.thinking, 'nothing left to check');
    });

    test('a record with both puts it on the text, not on the call', () async {
      // None of the 435 is shaped this way, so the rule is stated rather than
      // measured: the reasoning belongs to the turn, and the turn is the text.
      const id = 'think-4';
      writeTranscript(id, [
        {
          'step_index': 7,
          'source': 'MODEL',
          'type': 'PLANNER_RESPONSE',
          'status': 'DONE',
          'created_at': '2026-09-09T10:00:04Z',
          'thinking': 'read it before editing it',
          'content': 'Reading the file.',
          'tool_calls': [
            {
              'name': 'view_file',
              'args': {'AbsolutePath': '"/tmp/a.txt"'},
            },
          ],
        },
      ]);

      final rows = await readCliTranscript(
        conversationFile(id),
        AgentIds.antigravity,
      );

      expect(rows.map((r) => r.role), ['agent', 'tool']);
      expect(rows[0].thinking, 'read it before editing it');
      expect(rows[1].thinking, isNull, reason: 'one record, one reasoning');
    });

    test('a record with nothing to hang it on yields no row', () async {
      // The one line of 435. A row invented to carry reasoning would be a row
      // the conversation index never saw before -- see
      // `thinking_is_not_indexed_test.dart`.
      const id = 'think-5';
      writeTranscript(id, [
        {
          'step_index': 8,
          'source': 'MODEL',
          'type': 'PLANNER_RESPONSE',
          'status': 'DONE',
          'created_at': '2026-09-09T10:00:05Z',
          'thinking': 'unfinished, and unattached',
        },
      ]);

      final rows = await readCliTranscript(
        conversationFile(id),
        AgentIds.antigravity,
      );

      expect(rows, isEmpty);
    });

    test('an empty field is no reasoning at all', () async {
      const id = 'think-6';
      writeTranscript(id, [
        {
          'step_index': 9,
          'source': 'MODEL',
          'type': 'PLANNER_RESPONSE',
          'status': 'DONE',
          'created_at': '2026-09-09T10:00:06Z',
          'thinking': '   ',
          'content': 'Done.',
        },
      ]);

      final rows = await readCliTranscript(
        conversationFile(id),
        AgentIds.antigravity,
      );

      expect(rows.single.thinking, isNull);
    });
  });

  group('importedTranscriptProvider', () {
    /// One imported Antigravity conversation, filed at [filePath].
    ProviderContainer containerFor(String filePath) {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      ImportedSessionDao(db).insertIfAbsent(
        ImportedSession(
          id: 'i1',
          repositoryId: 'r1',
          cli: AgentIds.antigravity,
          externalId: 'conv-9',
          environmentId: 'windows',
          filePath: filePath,
          storeHome: storeHome(),
          isSubagent: false,
          preview: '',
          createdAt: testTime,
        ),
      );
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      return container;
    }

    /// The pane's first reading, with the provider held open while it arrives.
    ///
    /// A bare `read(.future)` disposes an auto-disposing provider before its
    /// stream can emit, because nothing is listening to it.
    Future<List<TranscriptMessage>> firstReading(
      ProviderContainer container,
    ) async {
      final provider = importedTranscriptProvider('i1');
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      return container.read(provider.future);
    }

    test('the pane reads the transcript beside the conversation', () async {
      writeTranscript('conv-9', [
        {
          'step_index': 0,
          'source': 'USER_EXPLICIT',
          'type': 'USER_INPUT',
          'status': 'DONE',
          'created_at': '2026-09-08T14:15:06Z',
          'content': 'from the brain directory',
        },
      ]);
      final container = containerFor(conversationFile('conv-9'));

      final rows = await firstReading(container);
      expect(rows.single.text, 'from the brain directory');
    });

    test('with no transcript in the store the refusal stands', () async {
      // The Windows install here, exactly: a conversation file and an empty
      // brain directory. Nothing is invented to fill the pane.
      final container = containerFor(conversationFile('conv-9'));

      final rows = await firstReading(container);
      expect(rows, isEmpty);
    });
  });
}
