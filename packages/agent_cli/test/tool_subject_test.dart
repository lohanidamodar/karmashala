import 'package:agent_cli/stream.dart';
import 'package:test/test.dart';

/// The line a tool row shows under its name: what the call acts on.
void main() {
  test('a known key names the call', () {
    expect(toolSubjectEntryFor({'command': 'ls'})?.value, 'ls');
  });

  test('an MCP call with none of the known keys shows its main argument', () {
    expect(
      toolSubjectEntryFor({'body': 'Buy milk', 'priority': 2})?.value,
      'Buy milk',
    );
    expect(toolSubjectEntryFor({'id': 'todo-7'})?.value, 'todo-7');
    expect(
      toolSubjectEntryFor({'sessionId': 's1', 'note': 'ship it'})?.value,
      's1',
    );
  });

  test('the one-line form names a subject once', () {
    expect(const ToolActivity(name: 'Bash', subject: 'ls').summary, 'Bash(ls)');
    expect(
      const ToolActivity(name: 'echo hi', subject: 'echo hi').summary,
      'echo hi',
    );
  });

  test('a call proposing a plan carries it, over the wire too', () {
    final call = toolActivityFor('ExitPlanMode', {'plan': '# Plan\n- one'});
    expect(call.proposedPlan, '# Plan\n- one');
    expect(ToolActivity.fromJson(call.toJson()).proposedPlan, '# Plan\n- one');
    expect(call.withResult(output: 'ok').proposedPlan, '# Plan\n- one');
    expect(toolActivityFor('Bash', {'command': 'ls'}).proposedPlan, isNull);
  });

  test('a failed command\'s output does not say its exit code twice', () {
    ToolActivity run(String output) =>
        ToolActivity(name: 'Bash', output: output, isError: true);
    expect(run('Exit code 1\nexit 1').shownOutput, 'Exit code 1');
    expect(run('Exit code 3\n\nexit 3\n').shownOutput, 'Exit code 3');
    expect(run('Exit code 1\nboom').shownOutput, 'Exit code 1\nboom');
    expect(run('Exit code 1\nexit 2').shownOutput, 'Exit code 1\nexit 2');
    expect(run('ok').shownOutput, 'ok');
    expect(const ToolActivity(name: 'Bash').shownOutput, isNull);
  });

  test('an input naming none of them has no subject', () {
    expect(toolSubjectEntryFor({'plan': 'x' * 400}), isNull);
    expect(toolSubjectEntryFor({'n': 3}), isNull);
  });
}
