import 'package:karmashala_agent_reporting/status.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// **Claude Code's project-MCP checklist is a wait on the person.** Its
/// 2.1.287 footer is `Space to select · Esc to reject all`, which matched no
/// approval rule, so the session read as working while it sat at startup
/// waiting for a keypress (owner, 2026-10-08). The rows are a ConPTY probe's.
void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
  final now = DateTime.utc(2026, 10, 8, 9);

  const checklist = [
    '  2 new MCP servers found in this project',
    '  Select any you wish to enable.',
    '',
    '  MCP servers may execute code or access system resources. All tool '
        'calls require approval. Learn more in the MCP documentation.',
    '',
    '    [✔] dart',
    '    [✔] marionette',
    '  ❯    Enable selected',
    ' Space to select · Esc to reject all',
  ];

  test('it needs the person: an approval, quoting the screen', () {
    final report = const TerminalGridStatusSource().read(
      claude,
      checklist,
      now,
      sessionId: 's1',
    );
    expect(report?.status, AgentActivityStatus.awaitingApproval);
    expect(report?.waiting, AgentWaitKind.approval);
    expect(
      report?.evidence,
      contains(contains('2 new MCP servers found in this project')),
    );
  });

  test('the footer quoted above a live composer is not a prompt', () {
    final report = const TerminalGridStatusSource().read(
      claude,
      const [
        ' It said: Space to select · Esc to reject all',
        '',
        ' ❯ ',
        '  ⏸ manual mode on · ? for shortcuts',
      ],
      now,
      sessionId: 's1',
    );
    expect(report?.status, isNot(AgentActivityStatus.awaitingApproval));
  });
}
