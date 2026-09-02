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

  group('failure', () {
    test('StopFailure is a failure, and Stop is still not', () {
      // The event Claude Code 2.1.258 fires *instead of* `Stop` when an API
      // error ended the turn — its own table: "Fires instead of Stop when an
      // API error (rate limit, auth failure, etc.) ended the turn."
      final failed = receiver.handle(
        agentId: 'claudeCode',
        event: 'StopFailure',
        body: jsonEncode({
          'session_id': 's1',
          'cwd': r'C:\src\demo',
          'hook_event_name': 'StopFailure',
          'error': 'rate_limit',
          'last_assistant_message': 'partial work',
        }),
      );

      expect(failed.status, AgentActivityStatus.failed);
      expect(failed.detail, 'StopFailure');
      // A failure holds the user up but offers nothing to press.
      expect(failed.waiting, AgentWaitKind.unrecorded);
      expect(reports.latest('claudeCode', 's1')!.status,
          AgentActivityStatus.failed);

      // And an ordinary finished turn is untouched by any of it.
      expect(
        receiver.handle(
          agentId: 'claudeCode',
          event: 'Stop',
          body: body('s1'),
        ).status,
        AgentActivityStatus.idle,
      );
    });

    /// An `agy` `Stop` payload in the shape 1.1.23 actually sends — protojson,
    /// camelCase, and the termination reason spelled with the
    /// `EXECUTOR_TERMINATION_REASON_` prefix stripped.
    String stop(String reason) => jsonEncode({
      'conversationId': 'c1',
      'executionNum': 1,
      'terminationReason': reason,
      'fullyIdle': true,
      'transcriptPath': '/tmp/t.jsonl',
      'workspacePaths': <String>[],
    });

    test('an Antigravity run that ended badly is not "finished"', () {
      for (final reason in [
        'ERROR',
        'MAX_INVOCATIONS',
        'MAX_FORCED_INVOCATIONS',
        'MAX_TOKEN_BUDGET_EXCEEDED',
      ]) {
        final report = receiver.handle(
          agentId: 'antigravity',
          event: 'Stop',
          body: stop(reason),
        );
        expect(report.status, AgentActivityStatus.failed, reason: reason);
        expect(report.sessionId, 'c1', reason: reason);
        expect(report.detail, 'Stop/$reason', reason: reason);
      }
    });

    test('an Antigravity run that ended normally is still idle', () {
      // `NO_TOOL_CALL` is the reason the one captured payload carried: the
      // model answered without calling a tool. `USER_CANCELED` is the user's
      // own Ctrl-C, which is an ending and not a failure.
      for (final reason in ['NO_TOOL_CALL', 'USER_CANCELED']) {
        expect(
          receiver
              .handle(agentId: 'antigravity', event: 'Stop', body: stop(reason))
              .status,
          AgentActivityStatus.idle,
          reason: reason,
        );
      }
    });

    test('a termination reason we have not judged records nothing', () {
      // Six of the twelve enum values are undeclared because nothing here knows
      // whether they end a run well or badly. `unknown` is not recorded, so the
      // session keeps whatever it last said rather than being told it finished.
      final report = receiver.handle(
        agentId: 'antigravity',
        event: 'Stop',
        body: stop('TERMINAL_CUSTOM_HOOK'),
      );

      expect(report.status, AgentActivityStatus.unknown);
      expect(reports.latest('antigravity', 'c1'), isNull);
    });

    test('an invocation event carries no reason and still reads working', () {
      // The property that makes this a descriptor-only change: an event whose
      // payload has no `terminationReason` falls through to `eventStatus`.
      for (final event in ['PreInvocation', 'PostInvocation']) {
        final report = receiver.handle(
          agentId: 'antigravity',
          event: event,
          body: jsonEncode({'conversationId': 'c1'}),
        );
        expect(report.status, AgentActivityStatus.working, reason: event);
        expect(report.detail, event, reason: event);
      }
    });
  });

  test('clear() drops everything recorded', () {
    receiver.handle(agentId: 'claudeCode', event: 'Stop', body: body('s1'));
    reports.clear();
    expect(reports.latest('claudeCode', 's1'), isNull);
  });
}
