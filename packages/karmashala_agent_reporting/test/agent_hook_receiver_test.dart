import 'dart:convert';

import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

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
    expect(report.evidence, ['Claude needs your permission to use Bash']);
  });

  // Found on a phone, 2.1.283: a minute after every turn the session entered
  // the inbox as "needs you", over an agent at rest at its own prompt.
  test('the idle nudge is idle, not a prompt waiting on anyone', () {
    final report = receiver.handle(
      agentId: 'claudeCode',
      event: 'Notification',
      body: notification('idle_prompt', 'Claude is waiting for your input'),
    );

    expect(report.status, AgentActivityStatus.idle);
    expect(report.waiting, AgentWaitKind.unrecorded);
    expect(report.hasOpenPrompt, isFalse);
    expect(report.evidence, ['Claude is waiting for your input']);
  });

  test('notifications nobody is waiting on are not statuses', () {
    // Every one of these arrived as `awaitingApproval` before the payload's own
    // `notification_type` was read: a successful login, an MCP elicitation
    // result, the end of a computer-use turn, and two notices about a
    // *different* session in the fleet roster. Message text and all, read off
    // the shipped binary's `notificationType:` call sites.
    const notices = {
      'auth_success': 'Claude Code login successful',
      'elicitation_complete':
          'MCP server "files" confirmed elicitation e1 '
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

  test('a session stopped on something it cannot answer itself says so', () {
    // Six subtypes newer than the ten this map was first written against. Each
    // of these is *this* session stopped and unable to go on: an MCP server
    // holding a dialog open (the CLI's own table marks both `waitingFor:
    // "input needed"`), and a usage limit that did not resume on its own.
    // Undeclared, every one of them left the session reading whatever it last
    // said — normally `working` — for as long as it sat there.
    const stopped = {
      'elicitation_dialog': 'Claude Code needs your input',
      'elicitation_url_dialog': 'An MCP server needs your input',
      'quota_auto_resume_stale': 'Usage limit reset — press enter to continue',
      'quota_auto_resume_disabled':
          'Automatic continue was turned off — the task will not resume on '
          'its own',
    };

    for (final entry in stopped.entries) {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: notification(entry.key, entry.value),
      );

      expect(
        report.status,
        AgentActivityStatus.awaitingApproval,
        reason: entry.key,
      );
      expect(report.evidence, [entry.value], reason: entry.key);
      // None of them is a list with a highlighted option, so none offers a
      // button that types Enter into somebody's session.
      expect(report.hasOpenPrompt, isFalse, reason: entry.key);
    }
  });

  test('a session that resumed on its own is not holding anyone up', () {
    // The other half of the same state machine: "Usage limit available —
    // Claude is continuing your task". News that nobody is waiting is not a
    // status, so it stays unrecorded.
    final report = receiver.handle(
      agentId: 'claudeCode',
      event: 'Notification',
      body: notification(
        'quota_auto_resume_fired',
        'Usage limit available — Claude is continuing your task',
      ),
    );

    expect(report.status, AgentActivityStatus.unknown);
    expect(reports.latest('claudeCode', 's1'), isNull);
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

  group('what the agent said, not just that it said something', () {
    test('a finished turn quotes its own last message', () {
      // Captured verbatim from Claude Code 2.1.260 on 2026-09-04. Before this
      // the payload was read for `message`, which `Stop` does not have, so
      // every completion toast was a session name and nothing else.
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: jsonEncode({
          'session_id': 's1',
          'hook_event_name': 'Stop',
          'stop_hook_active': false,
          'last_assistant_message':
              'I ran the echo command, which printed "hi" to the terminal.',
          'background_tasks': <Object?>[],
        }),
      );

      expect(report.status, AgentActivityStatus.idle);
      expect(report.evidence, [
        'I ran the echo command, which printed "hi" to the terminal.',
      ]);
    });

    test('a broken turn quotes the message it broke on', () {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'StopFailure',
        body: jsonEncode({
          'session_id': 's1',
          'hook_event_name': 'StopFailure',
          'error': 'rate_limit',
          'last_assistant_message': 'API Error: rate limit exceeded',
        }),
      );

      expect(report.status, AgentActivityStatus.failed);
      expect(report.evidence, ['API Error: rate limit exceeded']);
    });

    test('a Notification still quotes the key it has always quoted', () {
      // Both keys are declared; no event carries both, so the order is a
      // fallback rather than a precedence.
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: notification(
          'permission_prompt',
          'Claude needs your permission to use Bash',
        ),
      );

      expect(report.evidence, ['Claude needs your permission to use Bash']);
    });

    test('a finished turn is never read as an open prompt', () {
      // The prose rules exist to tell a permission request from an idle nudge,
      // and both are `awaitingApproval`. Run over a *summary* they would let an
      // agent claim an open prompt by writing a sentence about one — and the
      // wait kind is what puts an Enter-typing button on screen.
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: jsonEncode({
          'session_id': 's1',
          'hook_event_name': 'Stop',
          'last_assistant_message':
              'Done. Note that the next step needs your permission to run.',
        }),
      );

      expect(report.status, AgentActivityStatus.idle);
      expect(report.waiting, AgentWaitKind.unrecorded);
      expect(report.hasOpenPrompt, isFalse);
    });
  });

  group('a Stop that only paused the turn', () {
    /// A `Stop` payload as Claude Code 2.1.260 actually sends it, with
    /// [running] entries in `background_tasks`. The two captured on 2026-09-04
    /// differ in exactly this field: the mid-turn one lists the subagent it
    /// just launched, the closing one lists nothing.
    String stop({required bool running}) => jsonEncode({
      'session_id': 's1',
      'cwd': r'C:\src\demo',
      'hook_event_name': 'Stop',
      'stop_hook_active': false,
      'last_assistant_message': running
          ? 'Agent launched to run the command—waiting for completion.'
          : 'The subagent executed the command successfully.',
      'background_tasks': running
          ? [
              {
                'id': 'a8989a29ed73d4888',
                'type': 'subagent',
                'status': 'running',
                'description': 'Run echo subagent-ran command',
              },
            ]
          : <Object?>[],
      'session_crons': <Object?>[],
    });

    test('work still in flight is working, not finished', () {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: true),
      );

      expect(report.status, AgentActivityStatus.working);
      expect(
        reports.latest('claudeCode', 's1')!.status,
        isNot(AgentActivityStatus.idle),
      );
    });

    test('an empty list is the turn really ending', () {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: false),
      );

      expect(report.status, AgentActivityStatus.idle);
    });

    test('a payload with no such field is untouched', () {
      // Every CLI that predates `background_tasks`, and every other event of
      // the one that has it. Nothing said the session was busy, so `Stop` means
      // what its name means.
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: body('s1'),
      );

      expect(report.status, AgentActivityStatus.idle);
    });

    test('the field is only consulted for the event that declares it', () {
      // `SessionEnd` also ends a session and carries no such field. A spec that
      // named the path for every event would be reading a key that means
      // nothing there.
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'SessionEnd',
        body: jsonEncode({
          'session_id': 's1',
          'hook_event_name': 'SessionEnd',
          'reason': 'other',
          'background_tasks': [
            {'id': 'x', 'type': 'subagent', 'status': 'running'},
          ],
        }),
      );

      expect(report.status, AgentActivityStatus.idle);
    });

    test('it names the work still running', () {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: true),
      );

      expect(report.inFlight, ['Run echo subagent-ran command']);
    });

    // A phone's messages sat queued for hours behind a session whose
    // watchers always ran: the agent's own turn had ended each time.
    test('it says the turn itself ended; a new turn over the same work '
        'does not', () {
      final stopped = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: true),
      );
      expect(stopped.backgroundOnly, isTrue);
      expect(stopped.turnStatus, AgentActivityStatus.idle);

      final tool = receiver.handle(
        agentId: 'claudeCode',
        event: 'PreToolUse',
        body: body('s1'),
      );
      expect(tool.status, AgentActivityStatus.working);
      expect(tool.backgroundOnly, isFalse);
      expect(tool.turnStatus, AgentActivityStatus.working);
    });

    // The owner's report: subagents still working, the session filed under
    // Ready with a tick. Claude Code's 60-second "waiting for your input"
    // nudge checks only the main thread, so it fires mid-subagent.
    test('the idle nudge while it runs does not finish the session', () {
      receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: true),
      );
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: notification('idle_prompt', 'Claude is waiting for your input'),
      );

      expect(report.status, AgentActivityStatus.working);
      expect(report.inFlight, ['Run echo subagent-ran command']);
      expect(
        reports.latest('claudeCode', 's1')!.status,
        AgentActivityStatus.working,
      );
    });

    test('nor does the nudge after the subagent\'s own tool calls', () {
      receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: true),
      );
      final tool = receiver.handle(
        agentId: 'claudeCode',
        event: 'PreToolUse',
        body: body('s1'),
      );
      expect(tool.inFlight, ['Run echo subagent-ran command']);

      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: notification('idle_prompt', 'Claude is waiting for your input'),
      );

      expect(report.status, AgentActivityStatus.working);
    });

    test('a prompt opening meanwhile still needs you', () {
      receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: true),
      );
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: notification(
          'permission_prompt',
          'Claude needs your permission to use Bash',
        ),
      );

      expect(report.status, AgentActivityStatus.awaitingApproval);
    });

    test('the Stop that lists nothing lets the session rest', () {
      receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: true),
      );
      final ended = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: false),
      );
      expect(ended.status, AgentActivityStatus.idle);
      expect(ended.inFlight, isEmpty);

      final nudge = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: notification('idle_prompt', 'Claude is waiting for your input'),
      );
      expect(nudge.status, AgentActivityStatus.idle);
    });

    test('the session ending lets go of it too', () {
      receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: true),
      );
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'SessionEnd',
        body: jsonEncode({
          'session_id': 's1',
          'hook_event_name': 'SessionEnd',
          'reason': 'other',
        }),
      );

      expect(report.status, AgentActivityStatus.idle);
      expect(report.inFlight, isEmpty);
    });

    test('another session is not held by it', () {
      receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: stop(running: true),
      );
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: body('s2'),
      );

      expect(report.status, AgentActivityStatus.idle);
    });
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
    test('a nudge about an idle prompt is idle, not a prompt', () {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: body('s1', message: 'Claude is waiting for your input'),
      );

      expect(report.status, AgentActivityStatus.idle);
      expect(report.waiting, AgentWaitKind.unrecorded);
      expect(report.evidence, ['Claude is waiting for your input']);
    });

    test('the prose is read only on an event that stopped for the user', () {
      // A turn's own reply can say anything; only `Notification` is asked.
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: jsonEncode({
          'session_id': 's1',
          'hook_event_name': 'Stop',
          'last_assistant_message': 'Claude needs your permission to use Bash',
        }),
      );

      expect(report.status, AgentActivityStatus.idle);
      expect(report.waiting, AgentWaitKind.unrecorded);
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
          receiver
              .handle(agentId: 'claudeCode', event: event, body: body('s1'))
              .waiting,
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
      // The cause rides along: a usage limit and an overload are one event.
      expect(failed.failureReason, 'rate_limit');
      // A failure holds the user up but offers nothing to press.
      expect(failed.waiting, AgentWaitKind.unrecorded);
      expect(
        reports.latest('claudeCode', 's1')!.status,
        AgentActivityStatus.failed,
      );

      // And an ordinary finished turn is untouched by any of it.
      final stopped = receiver.handle(
        agentId: 'claudeCode',
        event: 'Stop',
        body: body('s1'),
      );
      expect(stopped.status, AgentActivityStatus.idle);
      expect(stopped.failureReason, isNull);
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
      for (final event in ['SessionStart', 'PreInvocation', 'PostInvocation']) {
        final report = receiver.handle(
          agentId: 'antigravity',
          event: event,
          body: jsonEncode({'conversationId': 'c1'}),
        );
        expect(report.status, AgentActivityStatus.working, reason: event);
        expect(report.detail, event, reason: event);
      }
    });

    test(
      'Antigravity Stop extracts error message as evidence when present',
      () {
        final report = receiver.handle(
          agentId: 'antigravity',
          event: 'Stop',
          body: jsonEncode({
            'conversationId': 'c1',
            'terminationReason': 'ERROR',
            'error': 'API quota limit exceeded',
          }),
        );
        expect(report.status, AgentActivityStatus.failed);
        expect(report.evidence, ['API quota limit exceeded']);
      },
    );

    test(
      'Antigravity Stop extracts finalModelOutput as evidence on success',
      () {
        final report = receiver.handle(
          agentId: 'antigravity',
          event: 'Stop',
          body: jsonEncode({
            'conversationId': 'c1',
            'terminationReason': 'NO_TOOL_CALL',
            'finalModelOutput': 'Task complete. All tests pass.',
          }),
        );
        expect(report.status, AgentActivityStatus.idle);
        expect(report.evidence, ['Task complete. All tests pass.']);
      },
    );

    test(
      'Antigravity Stop uses fallbackMessage when error and finalModelOutput are empty',
      () {
        final expectedFallbacks = {
          'MAX_INVOCATIONS': 'Maximum invocations reached',
          'MAX_FORCED_INVOCATIONS': 'Maximum forced invocations reached',
          'MAX_TOKEN_BUDGET_EXCEEDED': 'Maximum token budget exceeded',
          'ERROR': 'Execution failed',
        };
        for (final entry in expectedFallbacks.entries) {
          final report = receiver.handle(
            agentId: 'antigravity',
            event: 'Stop',
            body: jsonEncode({
              'conversationId': 'c1',
              'terminationReason': entry.key,
            }),
          );
          expect(report.status, AgentActivityStatus.failed, reason: entry.key);
          expect(report.evidence, [entry.value], reason: entry.key);
        }
      },
    );
  });

  test('clear() drops everything recorded', () {
    receiver.handle(agentId: 'claudeCode', event: 'Stop', body: body('s1'));
    reports.clear();
    expect(reports.latest('claudeCode', 's1'), isNull);
  });
}
