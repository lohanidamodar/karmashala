import 'package:karmashala_agent_reporting/status.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// **Claude Code's plan prompt is a wait on the person**, read off its screen:
/// 2.1.287 draws it with no `Esc to cancel` footer, so the grid read the
/// session as still working and nothing offered the plan's answers without a
/// hook. The rows are the probe's own screen, 2026-10-04.
void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
  final now = DateTime.utc(2026, 10, 4, 13);

  const planPrompt = [
    ' Ready to code?',
    '',
    ' Here is Claude\'s plan:',
    ' Plan: Add NOTES.md',
    ' 1. Create NOTES.md at the root of the project folder.',
    ' 2. Commit it on a new branch.',
    '',
    ' Claude has written up a plan and is ready to execute. Would you like '
        'to proceed?',
    '',
    ' ❯ 1. Yes, and use auto mode',
    '   2. Yes, manually approve edits',
    '   3. Tell Claude what to change',
    '      shift+tab to approve with this feedback',
    '',
    ' ctrl+g to edit in Notepad · ~\\.claude\\plans\\deep-spinning-brooks.md',
  ];

  test('the plan prompt waits on an approval, quoting the screen', () {
    final report = const TerminalGridStatusSource().read(
      claude,
      planPrompt,
      now,
      sessionId: 's1',
    );
    expect(report?.status, AgentActivityStatus.awaitingApproval);
    expect(report?.waiting, AgentWaitKind.approval);
    expect(report?.evidence, contains(contains('Would you like to proceed?')));
  });

  test('the same words in a reply above a live composer are not a prompt', () {
    final report = const TerminalGridStatusSource().read(
      claude,
      const [
        ' I asked: Would you like to proceed?',
        '',
        ' ❯ ',
        ' ⏸ manual mode on',
      ],
      now,
      sessionId: 's1',
    );
    expect(report?.status, isNot(AgentActivityStatus.awaitingApproval));
  });
}
