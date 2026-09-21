import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:agent_cli/src/cli_detection/data/subagent_transcript.dart';
import 'package:agent_cli/src/util/bounded_lines.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// **A tail must answer exactly what a whole-file read answers.**
///
/// The chat view re-read a 65 MB transcript on every tool call. The tail parses
/// only the appended bytes, but the parser carries state across lines — a
/// result answers a call made a turn earlier, a boundary retires a background
/// agent launched thousands of lines before — so every case here grows a file
/// in pieces, split anywhere, and compares each read with [readCliTranscript]
/// of the file as it stands at that moment. All fixtures are synthetic.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('transcript_tail'));
  tearDown(() => removeTempDirectory(dir));

  /// Grows [name] to [content] through [cuts], reading the tail after each
  /// append, and returns how each read was served.
  Future<List<TranscriptTailRead?>> grow(
    String name,
    String cli,
    List<int> content,
    List<int> cuts, {
    int onCallerBytes = kTranscriptTailOnCallerBytes,
    List<String> subagentIds = const [],
  }) async {
    final file = File(p.join(dir.path, name))..writeAsBytesSync(const []);
    // The index a `Task` row is joined against: every other call, plus a
    // meta whose transcript has not landed and so must not join.
    final index = Directory(subagentsDirectoryFor(file.path));
    for (var i = 0; i < subagentIds.length; i++) {
      index.createSync(recursive: true);
      final stem = p.join(index.path, 'agent-$i');
      File('$stem.meta.json').writeAsStringSync(
        jsonEncode({'toolUseId': subagentIds[i], 'agentType': 'Explore'}),
      );
      if (i.isEven) File('$stem.jsonl').writeAsStringSync('');
    }
    final tail = CliTranscriptTail(
      file.path,
      cli,
      onCallerBytes: onCallerBytes,
    );
    final served = <TranscriptTailRead?>[];
    var at = 0;
    for (final cut in [...cuts, content.length]) {
      file.writeAsBytesSync(content.sublist(at, cut), mode: FileMode.append);
      at = cut;
      final incremental = await tail.read();
      served.add(tail.lastRead);
      final whole = await readCliTranscript(file.path, cli);
      expect(
        describe(incremental),
        describe(whole),
        reason: '$cli after $cut of ${content.length} bytes, cuts $cuts',
      );
    }
    return served;
  }

  final tasks = <String>[];
  for (final (cli, fixture) in [
    (
      AgentIds.claudeCode,
      (Random r, Directory d) => _claudeFixture(r, d, tasks: tasks),
    ),
    (AgentIds.codex, _codexFixture),
    (AgentIds.antigravity, _antigravityFixture),
  ]) {
    test(
      '$cli: every read equals a whole-file read, over random splits',
      () async {
        tasks.clear();
        final content = utf8.encode(fixture(Random(7), dir));
        final random = Random(cli.hashCode);
        for (var round = 0; round < 12; round++) {
          final cuts = {
            for (var i = 0; i < 1 + random.nextInt(24); i++)
              random.nextInt(content.length),
          }.toList()..sort();
          final served = await grow(
            '$cli-$round.jsonl',
            cli,
            content,
            cuts,
            subagentIds: tasks,
          );
          expect(
            served.skip(1),
            everyElement(TranscriptTailRead.delta),
            reason:
                'the guard against a false green: after the first read, '
                'every append must be parsed as a delta, not re-read whole',
          );
        }
        if (cli != AgentIds.claudeCode) return;
        // The other guard: a fixture that never exercised the carried state
        // would pass against a tail that drops it.
        final rows = await readCliTranscript(
          p.join(dir.path, '$cli-0.jsonl'),
          cli,
        );
        for (final (what, has) in <(String, bool Function(TranscriptMessage))>[
          ('an answered call', (m) => m.tool?.output != null),
          ('an unanswered call', (m) => m.pendingToolUseId != null),
          ('a joined subagent', (m) => m.subagent != null),
          (
            'a running background agent',
            (m) => m.pendingBackgroundAgentId != null,
          ),
          ('a compaction', (m) => m.compaction != null),
          ('a truncated result', (m) => m.tool?.outputTruncated ?? false),
        ]) {
          expect(rows.where(has), isNotEmpty, reason: 'fixture lacks $what');
        }
      },
    );
  }

  test('a split at every byte of a call and its answer', () async {
    // The correlation the naive tail loses: the result arrives in a later read
    // than the call it answers, and has to find it in the carried state.
    final content = utf8.encode(_claudeFixture(Random(3), dir, events: 40));
    for (var cut = 1; cut < content.length; cut += 97) {
      await grow('pair-$cut.jsonl', AgentIds.claudeCode, content, [cut]);
    }
    final lines = const LineSplitter().convert(utf8.decode(content));
    var offset = 0;
    for (final line in lines) {
      offset += utf8.encode(line).length + 1;
      if (!line.contains('"tool_use"') || offset + 1 >= content.length) {
        continue;
      }
      // Exactly between a call and the next record, then one byte either side.
      await grow('call-$offset.jsonl', AgentIds.claudeCode, content, [
        offset - 1,
        offset,
        offset + 1,
      ]);
    }
  });

  test('a large append is parsed off the caller, and still equal', () async {
    final content = utf8.encode(_claudeFixture(Random(11), dir));
    final served = await grow('big.jsonl', AgentIds.claudeCode, content, [
      content.length ~/ 3,
      content.length ~/ 2,
    ], onCallerBytes: 64);
    expect(served, [
      TranscriptTailRead.full,
      TranscriptTailRead.offThreadDelta,
      TranscriptTailRead.offThreadDelta,
    ]);
  });

  test('an oversized record split across appends is dropped as whole '
      'reads drop it', () async {
    final content = utf8.encode(
      [
        _line({'type': 'user', 'message': _msg('user', 'before')}),
        _line({
          'type': 'user',
          'message': _msg('user', 'x' * (kMaxTranscriptLineBytes + 10)),
        }),
        _line({'type': 'user', 'message': _msg('user', 'after')}),
      ].join(),
    );
    final start = utf8
        .encode(_line({'type': 'user', 'message': _msg('user', 'before')}))
        .length;
    await grow('giant.jsonl', AgentIds.claudeCode, content, [
      start + 1000,
      start + kMaxTranscriptLineBytes ~/ 2,
      start + kMaxTranscriptLineBytes + 5,
    ]);
  });

  group('a file that did not simply grow is read whole', () {
    late File file;
    late CliTranscriptTail tail;

    Future<void> expectWhole() async {
      final incremental = await tail.read();
      expect(tail.lastRead, TranscriptTailRead.full);
      expect(
        describe(incremental),
        describe(await readCliTranscript(file.path, AgentIds.claudeCode)),
      );
    }

    setUp(() async {
      file = File(p.join(dir.path, 'rewritten.jsonl'))
        ..writeAsStringSync(_claudeFixture(Random(5), dir, events: 30));
      tail = CliTranscriptTail(file.path, AgentIds.claudeCode);
      await tail.read();
      file.writeAsStringSync(
        _line({'type': 'user', 'message': _msg('user', 'more')}),
        mode: FileMode.append,
      );
      await tail.read();
      expect(tail.lastRead, TranscriptTailRead.delta);
    });

    test('truncated', () async {
      final bytes = file.readAsBytesSync();
      file.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      await expectWhole();
    });

    test('emptied', () async {
      file.writeAsStringSync('');
      await expectWhole();
    });

    test('rewritten before the resume point, and longer', () async {
      final text = file.readAsStringSync();
      // Same length up to the end, one earlier byte changed, then grown: size
      // alone says "appended".
      final i = text.lastIndexOf('more');
      file.writeAsStringSync(
        '${text.substring(0, i)}MORE${text.substring(i + 4)}'
        '${_line({'type': 'user', 'message': _msg('user', 'after')})}',
      );
      await expectWhole();
    });

    test('replaced by another transcript with a different head', () async {
      // Longer than the file it replaces, so its size alone says "appended".
      final other = StringBuffer(_claudeFixture(Random(99), dir, events: 60));
      final was = file.lengthSync();
      while (other.length <= was + 1000) {
        other.write(_line({'type': 'user', 'message': _msg('user', 'pad')}));
      }
      file.writeAsStringSync(other.toString());
      await expectWhole();
    });

    test('deleted', () async {
      file.deleteSync();
      expect(await tail.read(), isEmpty);
      file.writeAsStringSync(
        _line({'type': 'user', 'message': _msg('user', 'again')}),
      );
      await expectWhole();
    });
  });

  test(
    'a subagent that lands after its call is joined on a later delta',
    () async {
      final file = File(p.join(dir.path, 'parent.jsonl'))
        ..writeAsStringSync(
          _line({
            'type': 'assistant',
            'message': {
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'task-late',
                  'name': 'Agent',
                  'input': {'description': 'late'},
                },
              ],
            },
          }),
        );
      final tail = CliTranscriptTail(file.path, AgentIds.claudeCode);
      expect((await tail.read()).single.subagent, isNull);

      final subagents = Directory(subagentsDirectoryFor(file.path))
        ..createSync(recursive: true);
      File(p.join(subagents.path, 'agent-late.jsonl')).writeAsStringSync('');
      File(
        p.join(subagents.path, 'agent-late.meta.json'),
      ).writeAsStringSync(jsonEncode({'toolUseId': 'task-late'}));
      file.writeAsStringSync(
        _line({'type': 'user', 'message': _msg('user', 'next')}),
        mode: FileMode.append,
      );

      final rows = await tail.read();
      expect(tail.lastRead, TranscriptTailRead.delta);
      expect(rows.first.subagent?.toolUseId, 'task-late');
      expect(
        describe(rows),
        describe(await readCliTranscript(file.path, AgentIds.claudeCode)),
      );
    },
  );
}

/// Every field a row carries, so two lists compare by what they say.
List<String> describe(List<TranscriptMessage> rows) => [
  for (final m in rows)
    jsonEncode({
      'role': m.role,
      'text': m.text,
      'thinking': m.thinking,
      'at': m.at?.toIso8601String(),
      'pending': m.pendingToolUseId,
      'background': m.pendingBackgroundAgentId,
      'compaction':
          m.compaction?.trigger ?? (m.compaction == null ? null : '?'),
      'tool': m.tool == null
          ? null
          : {
              'name': m.tool!.name,
              'subject': m.tool!.subject,
              'image': m.tool!.imagePath,
              'output': m.tool!.output,
              'truncated': m.tool!.outputTruncated,
              'error': m.tool!.isError,
              'plan': m.tool!.plan?.items
                  .map((i) => '${i.state.name}:${i.text}')
                  .toList(),
              'note': m.tool!.plan?.note,
            },
      'subagent': m.subagent == null
          ? null
          : [
              m.subagent!.toolUseId,
              m.subagent!.filePath,
              m.subagent!.agentType,
              m.subagent!.description,
              m.subagent!.spawnDepth,
              m.subagent!.model,
            ],
    }),
];

String _line(Map<String, Object?> json, {bool crlf = false}) =>
    '${jsonEncode(json)}${crlf ? '\r\n' : '\n'}';

Map<String, Object?> _msg(String role, Object content) => {
  'role': role,
  'content': content,
};

String _stamp(int i) =>
    DateTime.utc(2026, 9, 21, 10).add(Duration(seconds: i)).toIso8601String();

/// A Claude Code transcript exercising every piece of state the parser carries
/// across lines, with a subagent index beside it for the `Task` calls.
String _claudeFixture(
  Random r,
  Directory dir, {
  int events = 160,
  List<String>? tasks,
}) {
  final out = StringBuffer();
  final open = <String>[];
  final live = <String>[];
  var n = 0;
  for (var i = 0; i < events; i++) {
    final t = _stamp(i);
    switch (r.nextInt(14)) {
      case 0 || 1:
        out.write(
          _line({
            'type': 'user',
            'timestamp': t,
            'message': _msg(
              'user',
              'turn $i — café ☕ 日本語 ${'z' * r.nextInt(300)}',
            ),
          }, crlf: r.nextInt(6) == 0),
        );
      case 2 || 3 || 4:
        final id = 'toolu_${n++}';
        final name = [
          'Bash',
          'Read',
          'Edit',
          'Task',
          'Agent',
          'TodoWrite',
        ][r.nextInt(6)];
        open.add(id);
        if (name == 'Task' || name == 'Agent') tasks?.add(id);
        out.write(
          _line({
            'type': 'assistant',
            'timestamp': t,
            'message': {
              'content': [
                if (r.nextBool()) {'type': 'text', 'text': 'Calling $name'},
                {
                  'type': 'tool_use',
                  'id': id,
                  'name': name,
                  'input': name == 'TodoWrite'
                      ? {
                          'todos': [
                            {'content': 'step', 'status': 'in_progress'},
                          ],
                        }
                      : {'command': 'echo $i', 'description': 'd$i'},
                },
              ],
            },
          }),
        );
      case 5 || 6 || 7:
        if (open.isEmpty) continue;
        // Answered out of order and often a turn or more later.
        final id = open.removeAt(r.nextInt(open.length));
        final async = r.nextInt(3) == 0;
        final agent = 'agent_$id';
        if (async) live.add(agent);
        out.write(
          _line({
            'type': 'user',
            'timestamp': t,
            'message': _msg('user', [
              {
                'type': 'tool_result',
                'tool_use_id': id,
                'is_error': r.nextInt(8) == 0,
                'content': r.nextInt(10) == 0
                    ? 'o' * (70 * 1024)
                    : [
                        {'type': 'text', 'text': 'result of $id'},
                      ],
              },
            ]),
            if (async)
              'toolUseResult': {
                'isAsync': true,
                'status': 'async_launched',
                'agentId': agent,
              },
          }),
        );
      case 8:
        out.write(
          _line({
            'type': 'system',
            'subtype': 'compact_boundary',
            'timestamp': t,
            'compactMetadata': {'trigger': r.nextBool() ? 'auto' : 'manual'},
          }),
        );
        for (final agent in live.where((_) => r.nextBool()).toList()) {
          out.write(
            _line({
              'type': 'attachment',
              'attachment': {
                'type': 'task_status',
                'status': 'running',
                'taskId': agent,
              },
            }),
          );
        }
      case 9:
        if (live.isEmpty) continue;
        final agent = live.removeAt(r.nextInt(live.length));
        final envelope =
            '<task-notification><task-id>$agent</task-id>'
            '<status>completed</status></task-notification>';
        out.write(
          r.nextBool()
              ? _line({
                  'type': 'user',
                  'timestamp': t,
                  'message': _msg('user', envelope),
                })
              : _line({
                  'type': 'attachment',
                  'attachment': {'type': 'queued_command', 'prompt': envelope},
                }),
        );
      case 10:
        if (r.nextInt(4) == 0) {
          out.write(_line({'type': 'system', 'subtype': 'agents_killed'}));
          live.clear();
        } else {
          out.write(r.nextBool() ? '{not json\n' : '\n');
        }
      case _:
        out.write(
          _line({
            'type': 'assistant',
            'timestamp': t,
            'message': {
              'content': [
                {'type': 'text', 'text': 'reply $i ${'y' * r.nextInt(500)}'},
              ],
            },
          }),
        );
    }
  }
  // One background agent still running when the file ends, whatever the dice
  // retired above.
  out
    ..write(
      _line({
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'tool_use', 'id': 'toolu_last', 'name': 'Agent'},
          ],
        },
      }),
    )
    ..write(
      _line({
        'type': 'user',
        'message': _msg('user', [
          {'type': 'tool_result', 'tool_use_id': 'toolu_last', 'content': 'ok'},
        ]),
        'toolUseResult': {'isAsync': true, 'agentId': 'agent_last'},
      }),
    );
  return out.toString();
}

String _codexFixture(Random r, Directory dir) {
  final out = StringBuffer();
  final open = <String>[];
  for (var i = 0; i < 160; i++) {
    final t = _stamp(i);
    switch (r.nextInt(5)) {
      case 0:
        out.write(
          _line({
            'timestamp': t,
            'type': 'response_item',
            'payload': {
              'type': 'message',
              'role': r.nextBool() ? 'user' : 'assistant',
              'content': [
                {'type': 'output_text', 'text': 'codex $i ✓'},
              ],
            },
          }),
        );
      case 1 || 2:
        final id = 'call_$i';
        open.add(id);
        out.write(
          _line({
            'timestamp': t,
            'type': 'response_item',
            'payload': r.nextBool()
                ? {
                    'type': 'function_call',
                    'name': 'shell',
                    'call_id': id,
                    'arguments': jsonEncode({
                      'command': ['echo', '$i'],
                    }),
                  }
                : {
                    'type': 'custom_tool_call',
                    'name': 'exec',
                    'call_id': id,
                    'input': 'ls $i\nmore',
                  },
          }),
        );
      case 3:
        if (open.isEmpty) continue;
        final id = open.removeAt(r.nextInt(open.length));
        out.write(
          _line({
            'timestamp': t,
            'type': 'response_item',
            'payload': {
              'type': 'function_call_output',
              'call_id': id,
              'output': 'out $id',
            },
          }),
        );
      case _:
        out.write(r.nextBool() ? '{"payload":\n' : '\r\n');
    }
  }
  return out.toString();
}

String _antigravityFixture(Random r, Directory dir) {
  final out = StringBuffer();
  for (var i = 0; i < 160; i++) {
    final base = {
      'step_index': i,
      'created_at': _stamp(i),
      'status': r.nextInt(5) == 0 ? 'RUNNING' : 'DONE',
    };
    switch (r.nextInt(4)) {
      case 0:
        out.write(
          _line({
            ...base,
            'source': 'USER_EXPLICIT',
            'type': 'USER_INPUT',
            'content': '<USER_REQUEST>ask $i</USER_REQUEST>',
          }),
        );
      case 1:
        out.write(
          _line({
            ...base,
            'source': 'MODEL',
            'type': 'PLANNER_RESPONSE',
            if (r.nextBool()) 'content': 'plan $i',
            if (r.nextBool()) 'thinking': 'thinking $i',
            if (r.nextBool())
              'tool_calls': [
                {
                  'name': 'run_command',
                  'args': {'toolSummary': '"cmd $i"'},
                },
              ],
          }),
        );
      case 2:
        out.write(
          _line({
            ...base,
            'source': 'MODEL',
            'type': 'GENERIC',
            'content': 'result $i',
          }),
        );
      case _:
        out.write(
          _line({
            ...base,
            'source': 'SYSTEM',
            'type': 'SYSTEM_MESSAGE',
            'content': 'sys',
          }),
        );
    }
  }
  return out.toString();
}
