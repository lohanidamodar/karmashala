import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// **A subagent Claude Code ran in the background, read out of the parent's own
/// transcript.**
///
/// The measurement this exists for. In the owner's store there are 518 `Agent`
/// calls and the longest **outstanding** one — issued with no `tool_result` yet
/// — is 1.5 minutes, because the CLI answers the parent's call at once with
/// `{"isAsync":true,"status":"async_launched"}` and delivers the real outcome
/// much later in a `<task-notification>`. Two runs on 2026-09-07 took 76 and 80
/// minutes. So `pendingToolUseId` cannot see a background subagent at all, at
/// any age, and no ageing rule can be written that would.
///
/// What the transcript does record is a **ledger**, and every line of it is a
/// record the CLI wrote for its own reasons:
///
/// * `toolUseResult.isAsync` on the `tool_result` — this call went to the
///   background, and its `agentId`.
/// * `<task-notification>`'s `<task-id>` — that agent reported back.
/// * `system/compact_boundary` followed by `attachment/task_status` rows — the
///   CLI **re-enumerating** what is still live, which is what retires an agent
///   that died without ever reporting.
/// * `system/agents_killed` — the kill-all gesture; nothing is live after it.
///
/// Every shape below is copied from the owner's real store on 2026-09-08.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('bg_subagent'));
  tearDown(() => removeTempDirectory(root));

  String parentPath() => '${root.path}/s1.jsonl';
  void writeParent(List<String> lines) =>
      File(parentPath()).writeAsStringSync(lines.join('\n'));

  Future<List<TranscriptMessage>> read() =>
      readCliTranscript(parentPath(), AgentIds.claudeCode);

  /// The assistant line that issues the call.
  String agentCall(String toolUseId, String description) =>
      '{"type":"assistant","timestamp":"2026-09-08T09:17:25.733Z",'
      '"message":{"content":[{"type":"tool_use","id":"$toolUseId",'
      '"name":"Agent","input":{"description":"$description",'
      '"subagent_type":"general-purpose"}}]}}';

  /// The `user` line that answers it — the launch stub, plus the structured
  /// `toolUseResult` the CLI puts beside it.
  String launched(String toolUseId, String agentId, String description) =>
      '{"type":"user","timestamp":"2026-09-08T09:17:25.777Z",'
      '"message":{"content":[{"type":"tool_result","tool_use_id":"$toolUseId",'
      '"content":"Async agent launched successfully."}]},'
      '"toolUseResult":{"isAsync":true,"status":"async_launched",'
      '"agentId":"$agentId","description":"$description",'
      '"canReadOutputFile":true}}';

  /// The envelope the CLI wakes the session with when the agent reports back.
  String reported(
    String agentId,
    String toolUseId, {
    String status = 'completed',
  }) =>
      '{"type":"user","timestamp":"2026-09-08T10:33:00.000Z",'
      '"message":{"role":"user","content":"<task-notification>\\n'
      '<task-id>$agentId</task-id>\\n<tool-use-id>$toolUseId</tool-use-id>\\n'
      '<status>$status</status>\\n<summary>Agent finished</summary>\\n'
      '</task-notification>"}}';

  const compactBoundary =
      '{"type":"system","subtype":"compact_boundary",'
      '"timestamp":"2026-09-08T08:00:00.000Z",'
      '"content":"Conversation compacted","compactMetadata":{"trigger":"auto"}}';

  /// One agent the CLI re-states as live at a boundary.
  String stillRunning(String agentId) =>
      '{"type":"attachment","timestamp":"2026-09-08T08:00:01.000Z",'
      '"attachment":{"type":"task_status","taskId":"$agentId",'
      '"taskType":"local_agent","description":"long job","status":"running",'
      '"deltaSummary":"reading the reader"}}';

  const agentsKilled =
      '{"type":"system","subtype":"agents_killed",'
      '"timestamp":"2026-09-08T08:30:00.000Z"}';

  /// The one row a background subagent lands on: the `Agent` call itself.
  TranscriptMessage agentRow(List<TranscriptMessage> messages) =>
      messages.firstWhere((m) => m.tool?.name == 'Agent');

  test(
    'a launched-and-unreported background subagent is marked on its call',
    () async {
      writeParent([
        agentCall('toolu_1', 'Show background subagents while they run'),
        launched('toolu_1', 'a809fe33a06af42de', 'Show background subagents'),
      ]);

      final row = agentRow(await read());

      // Not outstanding — the CLI answered the call 0.2 minutes in — and yet
      // running. That is the whole gap this closes.
      expect(row.pendingToolUseId, isNull);
      expect(row.pendingBackgroundAgentId, 'a809fe33a06af42de');
      // The age comes off the transcript's own timestamp, as every reading here
      // must: the call was issued at 09:17:25.733Z.
      expect(row.at, DateTime.utc(2026, 9, 8, 9, 17, 25, 733));
    },
  );

  test('an envelope naming its task id retires it', () async {
    writeParent([
      agentCall('toolu_1', 'job'),
      launched('toolu_1', 'a809fe33a06af42de', 'job'),
      reported('a809fe33a06af42de', 'toolu_1'),
    ]);

    expect(agentRow(await read()).pendingBackgroundAgentId, isNull);
  });

  // Seen on the Oppo, 2026-09-19: "1 subagent running, oldest 10h 38m" on a
  // session whose Explore agent had finished at 03:51. It reported back while
  // the parent was mid-turn, and Claude Code 2.1.274 records such an envelope
  // as a queued command, not a user turn (copied from that transcript).
  test('an envelope queued while the parent was busy retires it too', () async {
    writeParent([
      agentCall('toolu_1', 'job'),
      launched('toolu_1', 'ab0c1e796c3cfbbad', 'job'),
      '{"type":"attachment","timestamp":"2026-09-19T03:52:01.700Z",'
          '"attachment":{"type":"queued_command","prompt":"<task-notification>\\n'
          '<task-id>ab0c1e796c3cfbbad</task-id>\\n'
          '<tool-use-id>toolu_1</tool-use-id>\\n<status>completed</status>\\n'
          '</task-notification>"}}',
    ]);

    expect(agentRow(await read()).pendingBackgroundAgentId, isNull);
  });

  test('every outcome the CLI reports retires it, not just success', () async {
    // Measured across the store: 722 completed, 41 stopped, 40 failed, 15
    // killed. The status word says what happened; that it arrived at all says
    // the agent is no longer running, which is the only question here.
    for (final status in ['completed', 'failed', 'killed', 'stopped']) {
      writeParent([
        agentCall('toolu_1', 'job'),
        launched('toolu_1', 'a1', 'job'),
        reported('a1', 'toolu_1', status: status),
      ]);

      expect(
        agentRow(await read()).pendingBackgroundAgentId,
        isNull,
        reason: 'a $status envelope is still a report',
      );
    }
  });

  test(
    'an agent that died without reporting is retired by the next boundary',
    () async {
      // **The case that makes this honest.** In the owner's largest session 95 of
      // 311 background subagents never got an envelope — killed with a CLI that
      // went away, or by the kill gesture — and drawing all 95 as running is the
      // confident false statement the whole design exists to delete. The CLI
      // re-enumerates what is live at each compaction, and that enumeration is
      // what prunes them: this one is not in it.
      writeParent([
        agentCall('toolu_1', 'job'),
        launched('toolu_1', 'a-dead', 'job'),
        compactBoundary,
        stillRunning('a-other'),
      ]);

      expect(agentRow(await read()).pendingBackgroundAgentId, isNull);
    },
  );

  test('an agent the boundary re-states as running survives it', () async {
    // The 76-minute run that spans a compaction. Its launch record is still in
    // the file, so it keeps its real age rather than being restamped.
    writeParent([
      agentCall('toolu_1', 'job'),
      launched('toolu_1', 'a-long', 'job'),
      compactBoundary,
      stillRunning('a-long'),
    ]);

    final row = agentRow(await read());
    expect(row.pendingBackgroundAgentId, 'a-long');
    expect(row.at, DateTime.utc(2026, 9, 8, 9, 17, 25, 733));
  });

  test('the kill-all gesture leaves nothing live', () async {
    writeParent([
      agentCall('toolu_1', 'job'),
      launched('toolu_1', 'a-long', 'job'),
      agentsKilled,
    ]);

    expect(agentRow(await read()).pendingBackgroundAgentId, isNull);
  });

  test(
    'a boundary re-statement for an agent we never saw launched is ignored',
    () async {
      // A `task_status` with no launch record behind it carries no instant to
      // count from, and an age we invented would be an age we were inventing a
      // claim about — the same rule that drops a call whose line had no
      // timestamp.
      writeParent([compactBoundary, stillRunning('a-unknown')]);

      expect(
        (await read()).where((m) => m.pendingBackgroundAgentId != null),
        isEmpty,
      );
    },
  );

  test('a foreground call is untouched', () async {
    // Every other CLI, and every Claude Code call that is not a background
    // agent: no `isAsync`, so nothing here applies and `pendingToolUseId`
    // remains the only word on whether it is running.
    writeParent([
      '{"type":"assistant","timestamp":"2026-09-08T09:00:00.000Z",'
          '"message":{"content":[{"type":"tool_use","id":"toolu_1",'
          '"name":"Bash","input":{"command":"git status"}}]}}',
    ]);

    final row = (await read()).single;
    expect(row.pendingToolUseId, 'toolu_1');
    expect(row.pendingBackgroundAgentId, isNull);
  });

  test('a launch with no agent id is not a join', () async {
    // Best-effort in every direction: Anthropic documents this layout as
    // internal and version-unstable, and a launch we cannot name is one we
    // cannot retire either.
    writeParent([
      agentCall('toolu_1', 'job'),
      '{"type":"user","timestamp":"2026-09-08T09:17:25.777Z",'
          '"message":{"content":[{"type":"tool_result",'
          '"tool_use_id":"toolu_1","content":"launched"}]},'
          '"toolUseResult":{"isAsync":true,"status":"async_launched"}}',
    ]);

    expect(agentRow(await read()).pendingBackgroundAgentId, isNull);
  });

  test('a session that ran several keeps them apart', () async {
    writeParent([
      agentCall('toolu_1', 'browser'),
      launched('toolu_1', 'a1', 'browser'),
      agentCall('toolu_2', 'agents'),
      launched('toolu_2', 'a2', 'agents'),
      agentCall('toolu_3', 'sessions'),
      launched('toolu_3', 'a3', 'sessions'),
      reported('a2', 'toolu_2'),
    ]);

    final live = [
      for (final m in await read())
        if (m.pendingBackgroundAgentId != null) m.pendingBackgroundAgentId,
    ];
    expect(live, ['a1', 'a3']);
  });
}
