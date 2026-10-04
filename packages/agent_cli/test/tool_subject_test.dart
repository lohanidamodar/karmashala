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

  test('an input naming none of them has no subject', () {
    expect(toolSubjectEntryFor({'plan': 'x' * 400}), isNull);
    expect(toolSubjectEntryFor({'n': 3}), isNull);
  });
}
