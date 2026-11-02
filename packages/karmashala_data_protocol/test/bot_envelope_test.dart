import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// The bot's wire contract: what a client asks, what it is answered and told,
/// through the envelope as JSON text.
void main() {
  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  DataRequest<Object?> sent(DataRequest<Object?> request) =>
      DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      ).request!;

  R roundTrip<R>(DataRequest<R> request, R result) => DataEnvelope.readAnswer(
    overTheWire(
      DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
    ),
    request,
  ).value;

  final at = DateTime.utc(2026, 11, 2, 12);
  final row = Session(
    id: 'bot',
    repositoryId: 'r',
    agentInstallationId: 'a',
    title: 'Bot',
    useWorktree: false,
    status: SessionStatus.running,
    createdAt: at,
    role: kSessionRoleBot,
    operatorGranted: true,
  );
  final approval = BotApproval(
    id: 'ap',
    sessionId: 'bot',
    tool: 'session_archive',
    arguments: const {'sessionId': 's1'},
    summary: 'Archive session "Fix it"',
    state: BotApprovalState.pending,
    requestedAt: at,
    expiresAt: at.add(kBotApprovalLifetime),
  );
  final state = BotState(
    session: row,
    agents: const [
      BotAgent(agentId: 'claude-acp', name: 'Claude', installationId: 'a'),
    ],
    agentId: 'claude-acp',
    agentSetting: 'claude-acp',
    notice: 'No chat form of Codex here, so Claude runs the bot.',
    approvals: [approval],
  );

  test('every request survives the wire', () {
    expect(sent(const BotStateRead()), isA<BotStateRead>());
    expect(sent(const BotSubscribe()), isA<BotSubscribe>());
    expect(sent(const BotOpen()), isA<BotOpen>());
    expect(sent(const BotClear()), isA<BotClear>());
    expect(
      (sent(const BotAgentSet('codex-acp')) as BotAgentSet).agentId,
      'codex-acp',
    );
    expect((sent(const BotAgentSet(null)) as BotAgentSet).agentId, isNull);
    final answer =
        sent(const BotApprovalAnswer('ap', approve: true)) as BotApprovalAnswer;
    expect(answer.id, 'ap');
    expect(answer.approve, isTrue);
  });

  test('the state survives the wire, and an empty one means no row', () {
    final back = roundTrip(const BotSubscribe(), state);
    expect(back.session!.isBot, isTrue);
    expect(back.session!.operatorGranted, isTrue);
    expect(back.agents.single.name, 'Claude');
    expect(back.agentId, 'claude-acp');
    expect(back.agentSetting, 'claude-acp');
    expect(back.notice, contains('Claude'));
    expect(back.approvals.single.arguments, {'sessionId': 's1'});

    final empty = roundTrip(const BotStateRead(), const BotState());
    expect(empty.session, isNull);
    expect(empty.agents, isEmpty);
    expect(empty.agentSetting, isNull);
  });

  test('an answer is told back as the request stands', () {
    final back = roundTrip(
      const BotApprovalAnswer('ap', approve: false),
      approval,
    );
    expect(back.state, BotApprovalState.pending);
    expect(back.summary, contains('Archive'));
  });

  test('what followers are told survives the wire', () {
    DataChange told(DataChange change) => DataChange.fromJson(
      (jsonDecode(jsonEncode(change.toJson())) as Map).cast<String, Object?>(),
    )!;

    expect((told(BotRowChanged(row)) as BotRowChanged).row.id, 'bot');
    expect(
      (told(BotApprovalChanged(approval)) as BotApprovalChanged).approval.id,
      'ap',
    );
    final agent =
        told(const BotAgentChanged(agentId: 'x', notice: 'n'))
            as BotAgentChanged;
    expect(agent.agentId, 'x');
    expect(agent.agentSetting, isNull);
    expect(agent.notice, 'n');
  });

  test('a capability names the bot', () => expect(BotOpen.feature, 'bot'));

  test('the agent setting is the server\'s, not a preference', () {
    expect(PreferenceKeys.isReserved(kBotAgentKey), isTrue);
  });
}
