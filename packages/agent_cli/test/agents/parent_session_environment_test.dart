import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// Karmashala started from inside a Claude Code session inherited that
/// session's variables, and every Claude it launched became a child session
/// with transcript saving off — so none of them could ever be resumed.
void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode);

  test("a running Claude's session variables are withheld", () {
    final withheld = inheritedParentSession(claude, {
      'CLAUDECODE': '1',
      'CLAUDE_CODE_CHILD_SESSION': '1',
      'CLAUDE_CODE_SESSION_ID': 'abc',
      'CLAUDE_CODE_MESSAGING_TOKEN': 'secret',
      'PATH': '/usr/bin',
    });
    expect(withheld, {
      'CLAUDECODE',
      'CLAUDE_CODE_CHILD_SESSION',
      'CLAUDE_CODE_SESSION_ID',
      'CLAUDE_CODE_MESSAGING_TOKEN',
    });
  });

  test('configuration a person sets on purpose stays', () {
    expect(
      inheritedParentSession(claude, {
        'CLAUDE_CODE_USE_BEDROCK': '1',
        'CLAUDE_EFFORT': 'high',
      }),
      isEmpty,
    );
  });

  test('another agent, or none, withholds nothing', () {
    final env = {'CLAUDECODE': '1'};
    expect(
      inheritedParentSession(AgentRegistry.builtIn.byId(AgentIds.codex), env),
      isEmpty,
    );
    expect(inheritedParentSession(null, env), isEmpty);
  });
}
