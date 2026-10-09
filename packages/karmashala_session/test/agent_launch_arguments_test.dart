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

  test('a read-only Codex is not handed --add-dir, which it refuses with '
      'exit 1', () {
    PermissionSelection mode(String sandbox) =>
        PermissionSelection({'sandbox': sandbox, 'approval': 'on-request'});
    List<String> argv(String sandbox) => agentPaneArguments(
      registry.byId(AgentIds.codex),
      mode(sandbox),
      extraDirectoryPath: r'C:\data\handoff',
      prompt: 'Read the brief.',
    );
    expect(argv('read-only'), isNot(contains('--add-dir')));
    expect(argv('read-only'), containsAllInOrder(['--sandbox', 'read-only']));
    expect(argv('read-only').last, 'Read the brief.');
    expect(argv('workspace-write'), contains('--add-dir'));
  });

  test('Claude Code is granted it in one entry, so its prompt stays the '
      'prompt', () {
    final argv = agentPaneArguments(
      registry.byId(AgentIds.claudeCode),
      PermissionSelection.empty,
      extraDirectoryPath: r'C:\data\handoff',
      prompt: 'Read the brief.',
    );
    expect(argv, contains(r'--add-dir=C:\data\handoff'));
    expect(argv, isNot(contains('--add-dir')));
    expect(argv.last, 'Read the brief.');
  });

  test('an agent that declares no such option is granted nothing', () {
    final argv = agentPaneArguments(
      registry.byId(AgentIds.antigravity),
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

  test('a packet the command line carries rides inline, before the prompt', () {
    final argv = agentPaneArguments(
      registry.byId(AgentIds.claudeCode),
      PermissionSelection.empty,
      systemPromptText: '# brief\nline two',
      prompt: 'Carry on.',
    );
    final at = argv.indexOf('--append-system-prompt');
    expect(argv[at + 1], '# brief\nline two');
    expect(argv.last, 'Carry on.');
  });
}
