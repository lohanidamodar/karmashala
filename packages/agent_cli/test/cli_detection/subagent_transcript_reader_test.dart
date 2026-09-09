import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:agent_cli/src/cli_detection/data/subagent_transcript.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// The subagent side of a Claude Code session, which the reader used to walk
/// straight past.
///
/// Claude Code writes each delegated agent to
/// `<session-id>/subagents/agent-<id>.jsonl` beside an `agent-<id>.meta.json`
/// carrying `agentType`, `description`, `spawnDepth` and `toolUseId`. The
/// parent transcript shows only the `Task(…)` call, so everything the delegate
/// actually did was on disk and unread.
///
/// Every case here is a way the directory can be wrong, because the format is
/// documented by Anthropic as internal and version-unstable: the promise is
/// that **a subagent we cannot read costs the parent transcript nothing**.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('subagent_test'));
  tearDown(() => removeTempDirectory(root));

  /// The parent transcript's path.
  String parentPath() => '${root.path}/s1.jsonl';

  /// Writes the parent transcript's lines.
  void writeParent(List<String> lines) =>
      File(parentPath()).writeAsStringSync(lines.join('\n'));

  /// The directory Claude Code hangs a session's subagents off.
  Directory subagentsDir() =>
      Directory('${root.path}/s1/subagents')..createSync(recursive: true);

  /// One subagent on disk: its meta and its turns. [meta] is written verbatim
  /// so a test can hand over something malformed.
  void writeSubagent(
    String id, {
    required String meta,
    List<String>? turns,
    String? rawTurns,
  }) {
    final dir = subagentsDir();
    File('${dir.path}/agent-$id.meta.json').writeAsStringSync(meta);
    if (turns != null || rawTurns != null) {
      File(
        '${dir.path}/agent-$id.jsonl',
      ).writeAsStringSync(rawTurns ?? turns!.join('\n'));
    }
  }

  String metaJson({
    required String toolUseId,
    String agentType = 'Explore',
    String description = 'find the reader',
    int spawnDepth = 1,
    String? model,
  }) =>
      '{"agentType":"$agentType","description":"$description",'
      '"spawnDepth":$spawnDepth,"toolUseId":"$toolUseId"'
      '${model == null ? '' : ',"model":"$model"'}}';

  /// A parent transcript holding one `Task` call with [id].
  List<String> taskCall(String id) => [
    '{"type":"user","message":{"role":"user","content":"delegate it"}}',
    '{"type":"assistant","message":{"content":[{"type":"tool_use",'
        '"id":"$id","name":"Task","input":{"description":"find the reader",'
        '"subagent_type":"Explore"}}]}}',
  ];

  test('a Task call is joined to its subagent by toolUseId', () async {
    writeParent(taskCall('toolu_01'));
    writeSubagent(
      'a1',
      meta: metaJson(toolUseId: 'toolu_01', model: 'opus'),
      turns: [
        '{"type":"user","message":{"role":"user","content":"find the reader"}}',
        '{"type":"assistant","message":{"content":[{"type":"text",'
            '"text":"it is cli_transcript_reader.dart"}]}}',
      ],
    );

    final messages = await readCliTranscript(parentPath(), AgentIds.claudeCode);

    // The parent still reads exactly as it did: one user turn, one tool row.
    expect(messages.map((m) => m.role), ['user', 'tool']);
    final ref = messages.last.subagent;
    expect(ref, isNotNull);
    expect(ref!.toolUseId, 'toolu_01');
    expect(ref.agentType, 'Explore');
    expect(ref.description, 'find the reader');
    expect(ref.spawnDepth, 1);
    expect(ref.model, 'opus');
    expect(ref.filePath, endsWith('agent-a1.jsonl'));

    // …and the turns are there to be read, once someone asks for them.
    final turns = await readSubagentTranscript(ref.filePath);
    expect(turns.map((m) => '${m.role}:${m.text}'), [
      'user:find the reader',
      'agent:it is cli_transcript_reader.dart',
    ]);
  });

  test('a Task call with no subagent file renders exactly as it does today',
      () async {
    writeParent(taskCall('toolu_01'));
    // A `subagents/` directory that exists but holds someone else's agent.
    writeSubagent(
      'a1',
      meta: metaJson(toolUseId: 'toolu_other'),
      turns: ['{"type":"user","message":{"role":"user","content":"hi"}}'],
    );

    final messages = await readCliTranscript(parentPath(), AgentIds.claudeCode);

    expect(messages.map((m) => '${m.role}:${m.text}'), [
      'user:delegate it',
      'tool:Task(find the reader)',
    ]);
    expect(messages.last.subagent, isNull);
  });

  test('a missing subagents/ directory costs the transcript nothing', () async {
    writeParent(taskCall('toolu_01'));

    final messages = await readCliTranscript(parentPath(), AgentIds.claudeCode);

    expect(messages.map((m) => m.role), ['user', 'tool']);
    expect(messages.last.subagent, isNull);
    expect(await readSubagentIndexFor(parentPath()), isEmpty);
  });

  test('a malformed .meta.json is skipped, and its neighbours still join',
      () async {
    writeParent([
      ...taskCall('toolu_01'),
      '{"type":"assistant","message":{"content":[{"type":"tool_use",'
          '"id":"toolu_02","name":"Task","input":{"description":"second"}}]}}',
    ]);
    // Three ways a meta goes wrong: not JSON at all, JSON that is not an
    // object, and an object with no `toolUseId` to join on (seen on this
    // machine: one meta carried `name` instead).
    writeSubagent('bad1', meta: 'not json at all', turns: ['{}']);
    writeSubagent('bad2', meta: '[1,2,3]', turns: ['{}']);
    writeSubagent(
      'bad3',
      meta: '{"agentType":"Explore","description":"d","spawnDepth":1}',
      turns: ['{}'],
    );
    writeSubagent(
      'good',
      meta: metaJson(toolUseId: 'toolu_02', description: 'second'),
      turns: [
        '{"type":"assistant","message":{"content":[{"type":"text",'
            '"text":"done"}]}}',
      ],
    );

    final messages = await readCliTranscript(parentPath(), AgentIds.claudeCode);

    expect(messages[1].subagent, isNull, reason: 'nothing claims toolu_01');
    expect(messages[2].subagent?.description, 'second');
  });

  test('a meta whose .jsonl has not been written yet is not offered', () async {
    writeParent(taskCall('toolu_01'));
    // The meta lands first; the agent has not written a turn. Offering the row
    // would promise turns that are not there.
    writeSubagent('a1', meta: metaJson(toolUseId: 'toolu_01'));

    final messages = await readCliTranscript(parentPath(), AgentIds.claudeCode);

    expect(messages.last.subagent, isNull);
  });

  test('a half-written .jsonl yields the turns that did land', () async {
    writeParent(taskCall('toolu_01'));
    writeSubagent(
      'a1',
      meta: metaJson(toolUseId: 'toolu_01'),
      // The agent is still running: the last line stops mid-object.
      rawTurns:
          '{"type":"user","message":{"role":"user","content":"go"}}\n'
          '{"type":"assistant","message":{"content":[{"type":"text",'
          '"text":"working"}]}}\n'
          '{"type":"assistant","message":{"content":[{"type":"te',
    );

    final ref = (await readCliTranscript(
      parentPath(),
      AgentIds.claudeCode,
    )).last.subagent!;
    final turns = await readSubagentTranscript(ref.filePath);

    expect(turns.map((m) => '${m.role}:${m.text}'), [
      'user:go',
      'agent:working',
    ]);
  });

  test('a nested subagent joins inside its parent subagent transcript',
      () async {
    // spawnDepth > 1. Claude Code keeps every depth in the *same* directory —
    // 99 at depth 1, 16 at depth 2 and 3 at depth 3 in one real session here —
    // so a depth-2 meta joins a `Task` call inside a depth-1 transcript.
    writeParent(taskCall('toolu_01'));
    writeSubagent(
      'a1',
      meta: metaJson(toolUseId: 'toolu_01', description: 'the delegate'),
      turns: [
        '{"type":"assistant","message":{"content":[{"type":"tool_use",'
            '"id":"toolu_deep","name":"Task",'
            '"input":{"description":"deeper"}}]}}',
      ],
    );
    writeSubagent(
      'a2',
      meta: metaJson(
        toolUseId: 'toolu_deep',
        description: 'deeper',
        spawnDepth: 2,
      ),
      turns: [
        '{"type":"assistant","message":{"content":[{"type":"text",'
            '"text":"the bottom"}]}}',
      ],
    );

    final outer = (await readCliTranscript(
      parentPath(),
      AgentIds.claudeCode,
    )).last.subagent!;
    expect(outer.spawnDepth, 1);

    final middle = (await readSubagentTranscript(outer.filePath)).single;
    final inner = middle.subagent;
    expect(inner, isNotNull, reason: 'a delegate can delegate again');
    expect(inner!.spawnDepth, 2);
    expect(inner.description, 'deeper');
    expect(
      (await readSubagentTranscript(inner.filePath)).single.text,
      'the bottom',
    );
  });

  test('Codex transcripts are left alone', () async {
    // The directory layout is Claude Code's. Codex keeps no such thing, and
    // deriving a path from a `rollout-…jsonl` would be a guess.
    File(
      '${root.path}/rollout.jsonl',
    ).writeAsStringSync('{"payload":{"type":"message","role":"user",'
        '"content":"hi"}}');

    final messages = await readCliTranscript(
      '${root.path}/rollout.jsonl',
      AgentIds.codex,
    );

    expect(messages.single.subagent, isNull);
  });
}
