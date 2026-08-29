import 'dart:convert';

import 'package:chitragupta/src/features/agents/data/agent_hook_receiver.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AgentHookReports reports;
  late AgentHookReceiver receiver;

  setUp(() {
    reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: FixedClock(testTime),
    );
  });

  String body(String sessionId) =>
      jsonEncode({'session_id': sessionId, 'cwd': r'C:\src\demo'});

  test('maps Claude hook events onto the status machine', () {
    const expected = {
      'UserPromptSubmit': AgentActivityStatus.working,
      'PreToolUse': AgentActivityStatus.working,
      'PostToolUse': AgentActivityStatus.working,
      'Notification': AgentActivityStatus.awaitingApproval,
      'Stop': AgentActivityStatus.idle,
      'SessionEnd': AgentActivityStatus.idle,
    };
    for (final entry in expected.entries) {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: entry.key,
        body: body('s1'),
      );
      expect(report.status, entry.value, reason: entry.key);
      expect(report.source, AgentStatusSource.hook);
      expect(report.detail, entry.key);
    }
  });

  test('records the report against the agent session it names', () {
    receiver.handle(agentId: 'claudeCode', event: 'Stop', body: body('s1'));

    final stored = reports.latest('claudeCode', 's1')!;
    expect(stored.status, AgentActivityStatus.idle);
    expect(stored.observedAt, testTime);
    expect(reports.latest('claudeCode', 'other'), isNull);
    expect(reports.latest('codex', 's1'), isNull);
  });

  test('the newest report for a session wins', () {
    receiver.handle(agentId: 'claudeCode', event: 'Stop', body: body('s1'));
    receiver.handle(
      agentId: 'claudeCode',
      event: 'PreToolUse',
      body: body('s1'),
    );

    expect(
      reports.latest('claudeCode', 's1')!.status,
      AgentActivityStatus.working,
    );
  });

  test('an unknown event is unknown and is not recorded', () {
    final report = receiver.handle(
      agentId: 'claudeCode',
      event: 'BrandNewHook',
      body: body('s1'),
    );

    expect(report.status, AgentActivityStatus.unknown);
    expect(reports.latest('claudeCode', 's1'), isNull);
  });

  test('an unknown agent is unknown and is not recorded', () {
    final report = receiver.handle(
      agentId: 'nobody',
      event: 'Stop',
      body: body('s1'),
    );

    expect(report.status, AgentActivityStatus.unknown);
    expect(reports.latest('nobody', 's1'), isNull);
  });

  test('an agent with no hook spec is unknown', () {
    final report = receiver.handle(
      agentId: 'antigravity',
      event: 'Stop',
      body: body('s1'),
    );

    expect(report.status, AgentActivityStatus.unknown);
  });

  test('a malformed body classifies but records nothing', () {
    final report = receiver.handle(
      agentId: 'claudeCode',
      event: 'Stop',
      body: 'not json at all',
    );

    expect(report.status, AgentActivityStatus.idle);
    expect(report.sessionId, isEmpty);
    expect(reports.latest('claudeCode', ''), isNull);
  });

  test('a missing event or agent never throws', () {
    expect(
      receiver.handle(agentId: null, event: null, body: '').status,
      AgentActivityStatus.unknown,
    );
  });

  test('clear() drops everything recorded', () {
    receiver.handle(agentId: 'claudeCode', event: 'Stop', body: body('s1'));
    reports.clear();
    expect(reports.latest('claudeCode', 's1'), isNull);
  });
}
