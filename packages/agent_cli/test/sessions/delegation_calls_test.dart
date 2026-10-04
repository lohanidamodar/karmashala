import 'package:agent_cli/stream.dart';
import 'package:test/test.dart';

/// A Karmashala launch call is recognised however the agent names it: a
/// terminal CLI's own tool name, or the title an ACP adapter reports.
void main() {
  test('every way an agent names a launch call is one', () {
    for (final name in const [
      // Claude Code's own record, and claude-agent-acp's title (the tool
      // name as is).
      'mcp__karmashala__subagent_run',
      'mcp__karmashala__open_new_session',
      // codex-acp: `format!("Tool: {}/{}", server, tool)`.
      'Tool: karmashala/subagent_run',
      'Tool: karmashala/open_new_session',
      // Codex's own record, and a bare name.
      'karmashala.subagent_run',
      'subagent_run',
    ]) {
      expect(isDelegationToolName(name), isTrue, reason: name);
    }
  });

  test('a near name is not one', () {
    for (final name in const [
      'Agent',
      'mcp__karmashala__subagent_runner',
      'Tool: karmashala/session_send',
      'my_subagent_run_notes',
      'Read subagent_run.dart',
    ]) {
      expect(isDelegationToolName(name), isFalse, reason: name);
    }
  });

  test('the child is read from the call\'s answer, either tool\'s key', () {
    expect(
      delegatedChildIdOf('{"state":"started","childSessionId":"c1"}'),
      'c1',
    );
    expect(delegatedChildIdOf('{"sessionId": "s9", "opened": "x"}'), 's9');
    expect(delegatedChildIdOf('Error: depth'), isNull);
    expect(delegatedChildIdOf(null), isNull);
  });
}
