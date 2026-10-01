import 'dart:convert';

import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// A session showing an `AskUserQuestion` is **waiting on a question** — not
/// idle, and not an approval. Idle hid it from the phone; approval offered
/// Approve, which is Enter, which silently answers with the first option.
void main() {
  final registry = AgentRegistry.builtIn;
  final now = DateTime.utc(2026, 9, 19, 7);

  group('the hook', () {
    late AgentHookReceiver receiver;
    setUp(() {
      receiver = AgentHookReceiver(
        registry: registry,
        reports: AgentHookReports(),
        clock: FixedClockForTest(now),
      );
    });

    String preToolUse(String tool, Object? input) => jsonEncode({
      'session_id': 's1',
      'hook_event_name': 'PreToolUse',
      'tool_name': tool,
      'tool_input': input,
    });

    test('PreToolUse for AskUserQuestion is a question, quoting it', () {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'PreToolUse',
        body: preToolUse('AskUserQuestion', {
          'questions': [
            {
              'question': 'Pick a fruit',
              'header': 'Fruit',
              'options': [
                {'label': 'Apple'},
                {'label': 'Banana'},
              ],
            },
          ],
        }),
      );
      expect(report.status, AgentActivityStatus.awaitingApproval);
      expect(report.waiting, AgentWaitKind.question);
      expect(report.hasOpenQuestion, isTrue);
      expect(
        report.hasOpenPrompt,
        isFalse,
        reason: 'no Approve for a question',
      );
      expect(report.evidence, ['Pick a fruit']);
    });

    // Measured end to end, 2026-09-19: Claude Code follows the PreToolUse with
    // a Notification of type `permission_prompt` ("Claude needs your
    // permission"), which on its own reads as an approval — and Approve is
    // Enter, which answers the question with whatever is highlighted.
    test('the permission notice that follows a question does not turn it into '
        'an approval', () {
      receiver.handle(
        agentId: 'claudeCode',
        event: 'PreToolUse',
        body: preToolUse('AskUserQuestion', {
          'questions': [
            {
              'question': 'Pick a fruit',
              'options': [
                {'label': 'Apple'},
              ],
            },
          ],
        }),
      );
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: jsonEncode({
          'session_id': 's1',
          'hook_event_name': 'Notification',
          'notification_type': 'permission_prompt',
          'message': 'Claude needs your permission to use AskUserQuestion',
        }),
      );
      expect(report.waiting, AgentWaitKind.question);
      expect(report.hasOpenPrompt, isFalse);
      expect(report.evidence, ['Pick a fruit']);
    });

    test('but a permission notice after the question was answered is one', () {
      receiver.handle(
        agentId: 'claudeCode',
        event: 'PreToolUse',
        body: preToolUse('AskUserQuestion', {
          'questions': [
            {
              'question': 'Pick a fruit',
              'options': [
                {'label': 'Apple'},
              ],
            },
          ],
        }),
      );
      receiver.handle(
        agentId: 'claudeCode',
        event: 'PostToolUse',
        body: preToolUse('AskUserQuestion', const {}),
      );
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'Notification',
        body: jsonEncode({
          'session_id': 's1',
          'hook_event_name': 'Notification',
          'notification_type': 'permission_prompt',
          'message': 'Claude needs your permission to use Bash',
        }),
      );
      expect(report.waiting, AgentWaitKind.approval);
    });

    test('any other tool is still just work', () {
      final report = receiver.handle(
        agentId: 'claudeCode',
        event: 'PreToolUse',
        body: preToolUse('Bash', {'command': 'ls'}),
      );
      expect(report.status, AgentActivityStatus.working);
      expect(report.hasOpenQuestion, isFalse);
    });

    test('an agent with no question support is never waiting on one', () {
      final report = receiver.handle(
        agentId: 'codex',
        event: 'PreToolUse',
        body: preToolUse('AskUserQuestion', {'questions': []}),
      );
      expect(report.hasOpenQuestion, isFalse);
    });
  });

  group('the screen', () {
    const source = TerminalGridStatusSource();
    final claude = registry.byId('claudeCode')!;

    test("Claude Code's question footer is a question, not an approval", () {
      final report = source.read(
        claude,
        const [
          ' ☐ Fruit',
          'Pick a fruit',
          '❯ 1. Apple',
          '  2. Banana',
          '  3. Type something.',
          'Enter to select · ↑/↓ to navigate · Esc to cancel',
        ],
        now,
        sessionId: 's1',
      )!;
      expect(report.status, AgentActivityStatus.awaitingApproval);
      expect(report.waiting, AgentWaitKind.question);
      expect(report.hasOpenPrompt, isFalse);
      expect(report.hasOpenQuestion, isTrue);
    });

    test('and so is the multi-question one', () {
      final report = source.read(
        claude,
        const [
          '←  ☐ Colours  ☐ Size  ✔ Submit  →',
          '❯ 1. [ ] Red',
          '  2. [ ] Blue',
          'Enter to select · Tab/Arrow keys to navigate · Esc to cancel',
        ],
        now,
        sessionId: 's1',
      )!;
      expect(report.waiting, AgentWaitKind.question);
    });

    test('a permission modal is still an approval', () {
      final report = source.read(
        claude,
        // With no composer drawn, a prompt draws its choices.
        const [
          'Do you want to proceed?',
          '❯ 1. Yes',
          '  2. No',
          'Esc to cancel · Tab to amend',
        ],
        now,
        sessionId: 's1',
      )!;
      expect(report.waiting, AgentWaitKind.approval);
      expect(report.hasOpenPrompt, isTrue);
    });
  });
}

class FixedClockForTest implements Clock {
  FixedClockForTest(this.now);
  final DateTime now;
  @override
  DateTime nowUtc() => now;
}
