import 'dart:convert';

import 'package:karmashala/src/features/agents/data/agent_hook_receiver.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
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

  String body(String sessionId, {String? message}) => jsonEncode({
    'session_id': sessionId,
    'cwd': r'C:\src\demo',
    'message': ?message,
  });

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
    // Codex, since Antigravity gained real hooks. Codex is told what happened
    // through its `notify` program, not through a hook config, so there is no
    // event name here for the receiver to classify.
    final report = receiver.handle(
      agentId: 'codex',
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

  group('Claude Code fires one Notification for two different things', () {
    // The live misclassification: a finished turn posted a message, Claude Code
    // nudged with `Notification`, and the app offered Approve — which types
    // Enter into a prompt with nothing highlighted and submits the composer.
    test('a nudge about an idle prompt is waiting on input, not approval', () {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: body('s1', message: 'Claude is waiting for your input'),
      );

      expect(report.status, AgentActivityStatus.awaitingApproval);
      expect(report.waiting, AgentWaitKind.input);
      expect(report.evidence, ['Claude is waiting for your input']);
    });

    test('a permission request is an approval', () {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: body('s1', message: 'Claude needs your permission to use Bash'),
      );

      expect(report.status, AgentActivityStatus.awaitingApproval);
      expect(report.waiting, AgentWaitKind.approval);
    });

    test('a message we do not recognise claims no approval', () {
      // The safe direction. A reworded prompt costs an Approve button; a
      // guessed one sends Enter into a session that may have no prompt open.
      for (final message in [null, '', 'Something else entirely']) {
        final report = receiver.handle(
          agentId: 'claudeCode',
          event: 'Notification',
          body: body('s1', message: message),
        );
        expect(report.waiting, AgentWaitKind.unrecorded, reason: '$message');
      }
    });

    test('events that are not about waiting record no wait kind', () {
      for (final event in ['PreToolUse', 'Stop']) {
        expect(
          receiver.handle(
            agentId: 'claudeCode',
            event: event,
            body: body('s1'),
          ).waiting,
          AgentWaitKind.unrecorded,
          reason: event,
        );
      }
    });
  });

  test('clear() drops everything recorded', () {
    receiver.handle(agentId: 'claudeCode', event: 'Stop', body: body('s1'));
    reports.clear();
    expect(reports.latest('claudeCode', 's1'), isNull);
  });
}
