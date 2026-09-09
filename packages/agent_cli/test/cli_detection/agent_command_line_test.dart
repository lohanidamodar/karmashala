import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_registry.dart';
import 'package:agent_cli/src/cli_detection/domain/agent_command_line.dart';
import 'package:test/test.dart';

/// Which typed command lines mean "an agent session just started here".
///
/// The rule is deliberately narrow: only what the shell is *running* counts,
/// because the alternative — matching an agent's name anywhere in the line —
/// cannot tell `claude` from `git commit -m "ask claude"`.
void main() {
  const registry = AgentRegistry.builtIn;

  String? id(String line) => agentIdForCommandLine(line, registry);

  test('a bare invocation names its agent', () {
    expect(id('claude'), AgentIds.claudeCode);
    expect(id('codex'), AgentIds.codex);
  });

  test('arguments do not change the answer', () {
    expect(id('claude --resume 0d1e --permission-mode plan'), AgentIds.claudeCode);
    expect(id('codex resume 01a0'), AgentIds.codex);
  });

  test('a path, a suffix and a quoted path all reduce to the binary', () {
    expect(id(r'C:\Users\me\.bin\claude.exe'), AgentIds.claudeCode);
    expect(id('./claude'), AgentIds.claudeCode);
    expect(id('/usr/local/bin/codex --help'), AgentIds.codex);
    expect(id(r'"C:\Program Files\bin\claude.cmd" --resume x'), AgentIds.claudeCode);
  });

  test('leading whitespace and case do not change the answer', () {
    expect(id('   CLAUDE  '), AgentIds.claudeCode);
  });

  test('an agent named anywhere but the front is not a session', () {
    expect(id('git commit -m "ask claude about it"'), isNull);
    expect(id('echo codex'), isNull);
    expect(id('ls -la'), isNull);
    expect(id(''), isNull);
    expect(id('   '), isNull);
  });

  test('an agent not in the registry is not recognised', () {
    expect(agentIdForCommandLine('claude', const AgentRegistry([])), isNull);
  });
}
