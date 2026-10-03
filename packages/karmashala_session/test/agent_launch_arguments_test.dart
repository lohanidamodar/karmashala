import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/launch.dart';
import 'package:test/test.dart';

/// A directory granted at launch rides where the agent reads top-level
/// options: left of Codex's `resume` subcommand, and only for an agent that
/// declares the option.
void main() {
  const registry = AgentRegistry.builtIn;

  test('Codex is granted the directory before its resume subcommand', () {
    final argv = agentPaneArguments(
      registry.byId(AgentIds.codex),
      PermissionSelection.empty,
      resumeSessionId: 'thread-1',
      extraDirectoryPath: r'C:\data\handoff',
      prompt: 'Read the brief.',
    );
    final at = argv.indexOf('--add-dir');
    expect(argv[at + 1], r'C:\data\handoff');
    expect(at, lessThan(argv.indexOf('resume')));
    expect(argv.last, 'Read the brief.');
  });

  test('an agent that declares no such option is granted nothing', () {
    final argv = agentPaneArguments(
      registry.byId(AgentIds.claudeCode),
      PermissionSelection.empty,
      extraDirectoryPath: r'C:\data\handoff',
    );
    expect(argv, isNot(contains(r'C:\data\handoff')));
  });

  test('no directory, no option', () {
    final argv = agentPaneArguments(
      registry.byId(AgentIds.codex),
      PermissionSelection.empty,
    );
    expect(argv, isNot(contains('--add-dir')));
  });
}
