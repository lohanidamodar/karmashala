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

  /// A `Notification` payload as Claude Code 2.1.258 actually sends it: its
  /// schema makes `notification_type` required, and `message` is the prose the
  /// call site built.
  String notification(String kind, String message) => jsonEncode({
    'session_id': 's1',
    'cwd': r'C:\src\demo',
    'hook_event_name': 'Notification',
    'notification_type': kind,
    'message': message,
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

  test('a permission notification is an approval that may be answered', () {
    final report = receiver.handle(
      agentId: 'claudeCode',
      event: 'Notification',
      body: notification(
        'permission_prompt',
        'Claude needs your permission to use Bash',
      ),
    );

    expect(report.status, AgentActivityStatus.awaitingApproval);
    expect(report.waiting, AgentWaitKind.approval);
    expect(report.evidence, [
      'Claude needs your permission to use Bash',
    ]);
  });

  test('the idle nudge stops the session without offering a key', () {
    final report = receiver.handle(
      agentId: 'claudeCode',
      event: 'Notification',
      body: notification('idle_prompt', 'Claude is waiting for your input'),
    );

    expect(report.status, AgentActivityStatus.awaitingApproval);
    expect(report.waiting, AgentWaitKind.input);
  });

  test('notifications nobody is waiting on are not statuses', () {
    // Every one of these arrived as `awaitingApproval` before the payload's own
    // `notification_type` was read: a successful login, an MCP elicitation
    // result, the end of a computer-use turn, and two notices about a
    // *different* session in the fleet roster. Message text and all, read off
    // the shipped binary's `notificationType:` call sites.
    const notices = {
      'auth_success': 'Claude Code login successful',
      'elicitation_complete': 'MCP server "files" confirmed elicitation e1 '
          'complete',
      'elicitation_response': 'Elicitation response for server "files": accept',
      'computer_use_exit': 'Claude is done using your computer',
      'agent_needs_input': 'reviewer needs your input',
      'agent_completed': 'reviewer finished',
    };

    for (final notice in notices.entries) {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: notification(notice.key, notice.value),
      );

      expect(report.status, AgentActivityStatus.unknown, reason: notice.key);
      expect(report.waiting, AgentWaitKind.unrecorded, reason: notice.key);
      // Unknown is never recorded, so a notice cannot overwrite what the
      // session was last known to be doing.
      expect(reports.latest('claudeCode', 's1'), isNull, reason: notice.key);
    }
  });

  test('a subtype we have never seen is unknown, not an approval', () {
    final report = receiver.handle(
      agentId: 'claudeCode',
      event: 'Notification',
      body: notification('some_future_notice', 'Something happened'),
    );

    expect(report.status, AgentActivityStatus.unknown);
  });

  test('a Notification with no subtype still falls back to the event', () {
    // A CLI predating `notification_type`. The event name is all there is, so
    // the prose rules decide the wait kind exactly as they used to.
    final report = receiver.handle(
      agentId: 'claudeCode',
      event: 'Notification',
      body: body('s1', message: 'Claude needs your permission to use Bash'),
    );

    expect(report.status, AgentActivityStatus.awaitingApproval);
    expect(report.waiting, AgentWaitKind.approval);
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

  test('an event the agent does not declare is unknown', () {
    // Every shipped agent now declares a hook spec, so the case this protects
    // is the other half of the same rule: a spec that does not name this event
    // classifies nothing. `SubagentStop` is a real Codex event, deliberately
    // left undeclared because it describes a different agent inside the
    // session — and an undeclared event must not be able to say anything.
    final report = receiver.handle(
      agentId: 'codex',
      event: 'SubagentStop',
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
