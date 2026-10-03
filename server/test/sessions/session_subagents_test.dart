import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/sessions/session_subagents.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// `sessions.subagents`: the delegates a record names, joined to their calls,
/// and the sessions recorded as children — every figure read, none guessed.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 9);

  TranscriptMessage task(
    String id, {
    String? output,
    bool open = false,
    bool failed = false,
    String? model,
    DateTime? at,
  }) => TranscriptMessage(
    role: 'tool',
    text: 'Agent(review)',
    tool: ToolActivity(name: 'Agent', output: output, isError: failed),
    at: at ?? t0,
    pendingToolUseId: open ? id : null,
    subagent: SubagentRef(
      toolUseId: id,
      filePath: '/store/s1/subagents/agent-$id.jsonl',
      agentType: 'Explore',
      description: 'Look for $id',
      spawnDepth: 1,
      model: model,
    ),
  );

  Session child(
    String id, {
    SessionStatus status = SessionStatus.running,
    SessionLink link = SessionLink.spawn,
  }) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Child $id',
    useWorktree: false,
    status: status,
    createdAt: t0.add(const Duration(minutes: 1)),
    parentSessionId: 's1',
    parentLink: link,
    modelId: 'gpt-5',
  );

  SessionSubagents reader({
    Map<String, List<TranscriptMessage>> messages = const {},
    List<Session> children = const [],
    Map<String, SubagentState> live = const {},
    bool acp = false,
  }) => SessionSubagents(
    messagesOf: (id) async => messages[id] ?? const [],
    childrenOf: (_) => children,
    liveStateOf: (id) => live[id],
    agentNameOf: (_) => 'Codex',
    sessionTokens: (id) async => (total: 1200, gap: null),
    subagentTokens: (_, path) async => path.endsWith('agent-t2.jsonl')
        ? (total: null, gap: SubagentTokensGap.tooLarge)
        : (total: 42, gap: null),
    speaksAcp: (_) => acp,
    modifiedAt: (_) async => t0.add(const Duration(minutes: 5)),
  );

  test('a record\'s subagents carry their call\'s state, result and the '
      'time their record was last written', () async {
    final list = await reader(
      messages: {
        's1': [
          const TranscriptMessage(role: 'user', text: 'go'),
          task('t1', output: 'Found it in cart.dart', model: 'haiku'),
          task('t2', failed: true, output: 'boom'),
          task('t3', open: true),
        ],
      },
      live: {'s1': SubagentState.running},
    ).read(const SessionSubagentsRead('s1'));

    expect(list.entries.map((e) => e.state), [
      SubagentState.done,
      SubagentState.failed,
      SubagentState.running,
    ]);
    final first = list.entries.first;
    expect(first.kind, SubagentKind.subagent);
    expect(first.title, 'Look for t1');
    expect(first.agent, 'Explore');
    expect(first.model, 'haiku');
    expect(first.finalResult, 'Found it in cart.dart');
    expect(first.tokens, 42);
    expect(first.endedAt, t0.add(const Duration(minutes: 5)));
    expect(first.transcriptPath, endsWith('agent-t1.jsonl'));
    expect(list.entries[1].tokens, isNull);
    expect(list.entries[1].tokensGap, SubagentTokensGap.tooLarge);
    // Still running: no end, no result.
    expect(list.entries[2].endedAt, isNull);
    expect(list.entries[2].finalResult, isNull);
  });

  test('a call left open by a session nothing runs is unknown, never '
      'running', () async {
    final list = await reader(
      messages: {
        's1': [task('t1', open: true)],
      },
    ).read(const SessionSubagentsRead('s1'));
    expect(list.entries.single.state, SubagentState.unknown);
  });

  test('a child session carries its agent, model, live state, tokens and '
      'last answer', () async {
    final list = await reader(
      messages: {
        'c1': [
          TranscriptMessage(role: 'user', text: 'do it', at: t0),
          TranscriptMessage(
            role: 'agent',
            text: 'All done: ${'x' * 5000}',
            at: t0.add(const Duration(minutes: 2)),
          ),
        ],
      },
      children: [child('c1', status: SessionStatus.idle)],
    ).read(const SessionSubagentsRead('s1'));
    final entry = list.entries.single;
    expect(entry.kind, SubagentKind.childSession);
    expect(entry.childSessionId, 'c1');
    expect(entry.agent, 'Codex');
    expect(entry.model, 'gpt-5');
    expect(entry.link, 'spawn');
    expect(entry.state, SubagentState.done);
    expect(entry.tokens, 1200);
    expect(entry.endedAt, t0.add(const Duration(minutes: 2)));
    expect(entry.finalResult, startsWith('All done'));
    expect(entry.finalResult!.length, kSubagentResultMaxChars);
    expect(entry.finalResultTruncated, isTrue);
  });

  test('a live child is the status keeper\'s word, blocked included', () async {
    final list = await reader(
      children: [child('c1')],
      live: {'c1': SubagentState.blocked},
    ).read(const SessionSubagentsRead('s1'));
    expect(list.entries.single.state, SubagentState.blocked);
    expect(list.entries.single.endedAt, isNull);
  });

  test('a failed child that ran nowhere reads failed; one with nothing said '
      'is unknown', () async {
    final list = await reader(
      children: [
        child('c1', status: SessionStatus.failed),
        child('c2', status: SessionStatus.completed),
      ],
    ).read(const SessionSubagentsRead('s1'));
    expect(list.entries.map((e) => e.state), [
      SubagentState.failed,
      SubagentState.unknown,
    ]);
  });

  test('an ACP parent lists its children and says why its tool calls are '
      'not', () async {
    final list = await reader(
      messages: {
        's1': [task('t1', output: 'x')],
      },
      children: [child('c1')],
      acp: true,
    ).read(const SessionSubagentsRead('s1'));
    expect(list.entries.single.kind, SubagentKind.childSession);
    expect(list.note, contains('ACP'));
  });

  test('the live state follows the status report', () {
    AgentStatusReport report(
      AgentActivityStatus status, {
      AgentWaitKind waiting = AgentWaitKind.unrecorded,
    }) => AgentStatusReport(
      agentId: 'x',
      sessionId: 'y',
      status: status,
      observedAt: t0,
      source: AgentStatusSource.hook,
      waiting: waiting,
    );
    expect(
      liveSubagentState(report(AgentActivityStatus.working)),
      SubagentState.running,
    );
    expect(
      liveSubagentState(report(AgentActivityStatus.idle)),
      SubagentState.done,
    );
    expect(
      liveSubagentState(
        report(
          AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.approval,
        ),
      ),
      SubagentState.blocked,
    );
    expect(liveSubagentState(null), SubagentState.unknown);
  });

  test('the answer crosses the wire whole', () {
    final list = SessionSubagentList(
      sessionId: 's1',
      note: 'n',
      entries: [
        SessionSubagent(
          kind: SubagentKind.childSession,
          id: 'c1',
          title: 'Child',
          state: SubagentState.done,
          agent: 'Codex',
          model: 'gpt-5',
          startedAt: t0,
          endedAt: t0.add(const Duration(seconds: 30)),
          tokens: 7,
          finalResult: 'ok',
          finalResultTruncated: true,
          childSessionId: 'c1',
          link: 'spawn',
        ),
        const SessionSubagent(
          kind: SubagentKind.subagent,
          id: 't1',
          title: 'Look',
          state: SubagentState.unknown,
          tokensGap: SubagentTokensGap.notRecorded,
          transcriptPath: '/a.jsonl',
        ),
      ],
    );
    final wire =
        jsonDecode(
              jsonEncode(const SessionSubagentsRead('s1').resultToJson(list)),
            )
            as Object?;
    final read = const SessionSubagentsRead('s1').resultFromJson(wire);
    expect(read.note, 'n');
    expect(read.entries.first.endedAt, t0.add(const Duration(seconds: 30)));
    expect(read.entries.first.finalResultTruncated, isTrue);
    expect(read.entries.first.tokens, 7);
    expect(read.entries.last.tokensGap, SubagentTokensGap.notRecorded);
    expect(read.entries.last.transcriptPath, '/a.jsonl');
    final request = DataRequest.fromJson('sessions.subagents', const {
      'sessionId': 's1',
    });
    expect(request, isA<SessionSubagentsRead>());
  });
}
