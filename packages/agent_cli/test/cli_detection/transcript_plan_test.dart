import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_plan.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

/// **The plan comes out of the parse the conversation already pays for.**
///
/// Nothing here opens a second file or runs a second pass: a plan tool's input
/// is decoded once, on the row that published it, and the fold downstream walks
/// a list that already exists. These tests pin that end of it — that both CLIs'
/// real line shapes land on [ToolActivity.plan] — and, in the last group, that
/// a transcript with no plan in it allocates none.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('plan-transcript');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<String> write(String name, List<Map<String, Object?>> lines) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString(lines.map(jsonEncode).join('\n'));
    return file.path;
  }

  Map<String, Object?> claudeTodoWrite(
    List<(String, String)> items, {
    required String at,
    String id = 'toolu_1',
  }) => {
    'type': 'assistant',
    'timestamp': at,
    'message': {
      'content': [
        {
          'type': 'tool_use',
          'id': id,
          'name': 'TodoWrite',
          'input': {
            'todos': [
              for (final (content, status) in items)
                {'content': content, 'activeForm': content, 'status': status},
            ],
          },
        },
      ],
    },
  };

  test('a Claude TodoWrite call lands on the row that published it', () async {
    final path = await write('claude.jsonl', [
      claudeTodoWrite([
        ('Audit the template systems', 'in_progress'),
        ('Wire the localisation keys', 'pending'),
      ], at: '2026-09-08T10:00:00.000Z'),
    ]);

    final messages = await readCliTranscript(path, AgentIds.claudeCode);
    final row = messages.single;
    expect(row.role, 'tool');
    expect(row.tool!.name, 'TodoWrite');
    expect(row.tool!.plan!.total, 2);
    expect(row.tool!.plan!.doneCount, 0);
    expect(row.tool!.plan!.current?.text, 'Audit the template systems');
    // The row's own timestamp is the plan's age, and it is the CLI's, never a
    // first-sighting time.
    expect(row.at, DateTime.utc(2026, 9, 8, 10));
  });

  test('the bare word TodoWrite is no longer the whole row', () async {
    final path = await write('claude-subject.jsonl', [
      claudeTodoWrite([
        ('Ship it', 'completed'),
      ], at: '2026-09-08T10:00:00.000Z'),
    ]);
    final row = (await readCliTranscript(path, AgentIds.claudeCode)).single;
    // Its input carries none of `kToolSubjectKeys`, so before this the summary
    // was the tool's name and nothing else.
    expect(row.tool!.summary, 'TodoWrite(1/1 done)');
  });

  test('a Codex update_plan call lands the same way', () async {
    final path = await write('codex.jsonl', [
      {
        'timestamp': '2026-09-08T11:30:00.000Z',
        'type': 'response_item',
        'payload': {
          'type': 'function_call',
          'name': 'update_plan',
          'call_id': 'call_1',
          'arguments': jsonEncode({
            'explanation': 'Calibrate the defaults first.',
            'plan': [
              {'step': 'Inspect the config', 'status': 'completed'},
              {'step': 'Measure the outputs', 'status': 'in_progress'},
              {'step': 'Adjust and cover', 'status': 'pending'},
            ],
          }),
        },
      },
    ]);

    final row = (await readCliTranscript(path, AgentIds.codex)).single;
    expect(row.tool!.name, 'update_plan');
    expect(row.tool!.plan!.total, 3);
    expect(row.tool!.plan!.doneCount, 1);
    expect(row.tool!.plan!.note, 'Calibrate the defaults first.');
    // The subject used to be the whole argument blob on one line.
    expect(row.tool!.subject, startsWith('1/3 done · Measure the outputs'));
  });

  test('the plan survives the result being attached to the call', () async {
    // Codex answers `update_plan` with the string "Plan updated"; the call is
    // rewritten in place to hang that on it, and the rewrite must not drop the
    // plan the row is there for.
    final path = await write('codex-answered.jsonl', [
      {
        'timestamp': '2026-09-08T11:30:00.000Z',
        'type': 'response_item',
        'payload': {
          'type': 'function_call',
          'name': 'update_plan',
          'call_id': 'call_1',
          'arguments': jsonEncode({
            'plan': [
              {'step': 'Only step', 'status': 'in_progress'},
            ],
          }),
        },
      },
      {
        'timestamp': '2026-09-08T11:30:01.000Z',
        'type': 'response_item',
        'payload': {
          'type': 'function_call_output',
          'call_id': 'call_1',
          'output': 'Plan updated',
        },
      },
    ]);

    final row = (await readCliTranscript(path, AgentIds.codex)).single;
    expect(row.tool!.output, 'Plan updated');
    expect(row.tool!.plan!.items.single.text, 'Only step');
  });

  test('every snapshot is kept, so the last one can win', () async {
    // Both CLIs resend the whole list, so the fold takes the newest — which it
    // can only do if the parse did not collapse them on the way through.
    final path = await write('claude-many.jsonl', [
      claudeTodoWrite(
        [('One', 'in_progress'), ('Two', 'pending')],
        at: '2026-09-08T10:00:00.000Z',
        id: 'a',
      ),
      claudeTodoWrite(
        [('One', 'completed'), ('Two', 'in_progress')],
        at: '2026-09-08T10:05:00.000Z',
        id: 'b',
      ),
    ]);

    final plans = [
      for (final message in await readCliTranscript(path, AgentIds.claudeCode))
        ?message.tool?.plan,
    ];
    expect(plans, hasLength(2));
    expect(plans.first.doneCount, 0);
    expect(plans.last.doneCount, 1);
  });

  group('what a transcript with no plan in it costs', () {
    test('no plan tool means no plan allocated, on either CLI', () async {
      final claude = await write('claude-none.jsonl', [
        for (var i = 0; i < 50; i++)
          {
            'type': 'assistant',
            'timestamp': '2026-09-08T10:00:0${i % 10}.000Z',
            'message': {
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'toolu_$i',
                  'name': 'Bash',
                  'input': {'command': 'git status'},
                },
              ],
            },
          },
      ]);
      final codex = await write('codex-none.jsonl', [
        for (var i = 0; i < 50; i++)
          {
            'timestamp': '2026-09-08T10:00:0${i % 10}.000Z',
            'type': 'response_item',
            'payload': {
              'type': 'function_call',
              'name': 'shell',
              'call_id': 'call_$i',
              'arguments': '{"command":["git","status"]}',
            },
          },
      ]);

      for (final (path, cli) in [
        (claude, AgentIds.claudeCode),
        (codex, AgentIds.codex),
      ]) {
        final messages = await readCliTranscript(path, cli);
        expect(messages, hasLength(50), reason: cli);
        expect(
          messages.where((m) => m.tool?.plan != null),
          isEmpty,
          reason: '$cli: a transcript that planned nothing must allocate none',
        );
      }
    });

    test('a plan tool is the only row that pays', () async {
      final path = await write('claude-mixed.jsonl', [
        for (var i = 0; i < 20; i++)
          {
            'type': 'assistant',
            'timestamp': '2026-09-08T10:00:0${i % 10}.000Z',
            'message': {
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'toolu_$i',
                  'name': 'Read',
                  'input': {'file_path': '/tmp/a$i.dart'},
                },
              ],
            },
          },
        claudeTodoWrite(
          [('Only plan', 'pending')],
          at: '2026-09-08T10:01:00.000Z',
          id: 'plan',
        ),
      ]);

      final messages = await readCliTranscript(path, AgentIds.claudeCode);
      expect(messages.where((m) => m.tool?.plan != null), hasLength(1));
      // And the twenty that are not plans keep the subject they always had.
      expect(messages.first.tool!.subject, '/tmp/a0.dart');
    });

    test('an unreadable agent still reads as nothing at all', () async {
      // Antigravity is refused by name before a byte is read, and that is what
      // makes "this agent publishes no plan" cost nothing to establish.
      final path = await write('agy.jsonl', [
        claudeTodoWrite([('x', 'pending')], at: '2026-09-08T10:00:00.000Z'),
      ]);
      expect(await readCliTranscript(path, AgentIds.antigravity), isEmpty);
    });
  });

  test('a malformed plan line is skipped, and the rest still parses', () async {
    final file = File('${dir.path}/mixed.jsonl');
    await file.writeAsString(
      [
        jsonEncode(
          claudeTodoWrite([
            ('Real', 'pending'),
          ], at: '2026-09-08T10:00:00.000Z'),
        ),
        '{"type":"assistant","message":{"content":[{"type":"tool_use"',
        jsonEncode({
          'type': 'assistant',
          'timestamp': '2026-09-08T10:02:00.000Z',
          'message': {
            'content': [
              {
                'type': 'tool_use',
                'id': 'b',
                'name': 'TodoWrite',
                'input': {'todos': 'not a list'},
              },
            ],
          },
        }),
      ].join('\n'),
    );

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);
    expect(messages, hasLength(2));
    // The second TodoWrite is a shape we cannot read, so it publishes nothing
    // rather than an empty plan that would overwrite the first.
    expect(messages.first.tool!.plan!.total, 1);
    expect(messages.last.tool!.plan, isNull);
    expect(
      messages.last.tool!.subject,
      isNull,
      reason: 'and it falls back to the subject it would have had',
    );
  });

  test('an unknown state word is shown, never counted as done', () {
    // Read here rather than through a file: it is a statement about the
    // declaration, and the declaration is what a new CLI version breaks.
    final plan = kClaudeCodeTodoWrite.planIn({
      'todos': [
        {'content': 'Waiting on review', 'status': 'blocked'},
        {'content': 'Landed', 'status': 'completed'},
      ],
    })!;
    expect(plan.items.first.state, AgentPlanItemState.unrecorded);
    expect(plan.doneCount, 1);
    expect(plan.isFinished, isFalse);
  });

  group("Claude Code's TaskCreate and TaskUpdate", () {
    Map<String, Object?> call(
      String id,
      String name,
      Object input,
      String at,
    ) => {
      'type': 'assistant',
      'timestamp': at,
      'message': {
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
        ],
      },
    };
    Map<String, Object?> answer(
      String id,
      String text,
      Object? result,
      String at, {
      bool isError = false,
    }) => {
      'type': 'user',
      'timestamp': at,
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': id,
            'content': text,
            if (isError) 'is_error': true,
          },
        ],
      },
      'toolUseResult': result,
    };
    Map<String, Object?> create(String id, String task, String subject) => call(
      id,
      'TaskCreate',
      {'subject': subject, 'description': 'Why $subject'},
      '2026-10-06T10:00:00.000Z',
    );
    Map<String, Object?> created(String id, String task, String subject) =>
        answer(id, 'Task #$task created successfully: $subject', {
          'task': {'id': task, 'subject': subject},
        }, '2026-10-06T10:00:01.000Z');
    Map<String, Object?> update(String id, String task, String status) => call(
      id,
      'TaskUpdate',
      {'taskId': task, 'status': status},
      '2026-10-06T10:01:00.000Z',
    );
    Map<String, Object?> updated(String id, String task) =>
        answer(id, 'Updated task #$task status', {
          'success': true,
          'taskId': task,
          'updatedFields': ['status'],
        }, '2026-10-06T10:01:01.000Z');

    test('the tasks are the plan, each call carrying it as it stood', () async {
      final path = await write('claude-tasks.jsonl', [
        create('k1', '1', 'Read the reader'),
        created('k1', '1', 'Read the reader'),
        create('k2', '2', 'Fold the tasks'),
        created('k2', '2', 'Fold the tasks'),
        update('k3', '1', 'in_progress'),
        updated('k3', '1'),
        update('k4', '1', 'completed'),
        updated('k4', '1'),
      ]);

      final plans = [
        for (final m in await readCliTranscript(path, AgentIds.claudeCode))
          ?m.tool?.plan,
      ];
      expect(plans, hasLength(4));
      expect(plans.first.items.map((i) => i.text), ['Read the reader']);
      expect(plans[1].items.map((i) => (i.text, i.state)), [
        ('Read the reader', AgentPlanItemState.pending),
        ('Fold the tasks', AgentPlanItemState.pending),
      ]);
      expect(plans[2].current?.text, 'Read the reader');
      expect(plans.last.doneCount, 1);
      expect(plans.last.total, 2);
    });

    test(
      'a deleted task leaves the plan; a failed call changes nothing',
      () async {
        final path = await write('claude-tasks-deleted.jsonl', [
          create('k1', '1', 'Keep'),
          created('k1', '1', 'Keep'),
          create('k2', '2', 'Drop'),
          created('k2', '2', 'Drop'),
          update('k3', '1', 'completed'),
          answer(
            'k3',
            'Task not found',
            null,
            '2026-10-06T10:01:01.000Z',
            isError: true,
          ),
          update('k4', '2', 'deleted'),
          updated('k4', '2'),
        ]);

        final messages = await readCliTranscript(path, AgentIds.claudeCode);
        final failed = messages.firstWhere((m) => m.tool?.isError ?? false);
        expect(failed.tool!.plan, isNull);
        final last = messages.lastWhere((m) => m.tool?.plan != null);
        expect(last.tool!.plan!.items.map((i) => (i.text, i.state)), [
          ('Keep', AgentPlanItemState.pending),
        ]);
      },
    );

    test('a call still waiting on its answer publishes nothing yet', () async {
      final path = await write('claude-tasks-open.jsonl', [
        create('k1', '1', 'Pending'),
      ]);
      final row = (await readCliTranscript(path, AgentIds.claudeCode)).single;
      expect(row.tool!.plan, isNull);
      expect(row.pendingToolUseId, 'k1');
    });
  });
}
