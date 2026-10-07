import 'package:agent_cli/stream.dart';
import 'package:test/test.dart';

/// What a running call is doing, in words a person reads — never its command.
void main() {
  test('a call that describes itself is named by its description', () {
    final tool = toolActivityFor('Bash', {
      'command': r'$sp = "$env:TEMP\x"; dart analyze > "$sp\a.txt"',
      'description': 'Run the analyzer',
    });
    expect(tool.description, 'Run the analyzer');
    expect(toolDoingPhrase(tool), 'Run the analyzer');
  });

  test('a command with no description has no phrase', () {
    final tool = toolActivityFor('Bash', {'command': 'flutter test'});
    expect(tool.description, isNull);
    expect(toolDoingPhrase(tool), isNull);
  });

  test('a file tool reads as a verb on the file name', () {
    expect(
      toolDoingPhrase(
        toolActivityFor('Edit', {'file_path': '/src/app/lib/overview.dart'}),
      ),
      'Editing overview.dart',
    );
    expect(
      toolDoingPhrase(toolActivityFor('Grep', {'pattern': 'sendMessage'})),
      'Searching for sendMessage',
    );
  });

  test('a subagent named by its description is not described twice', () {
    final tool = toolActivityFor('Task', {
      'description': 'Map the send path',
      'prompt': 'Read everything',
    });
    expect(tool.description, isNull);
    expect(toolDoingPhrase(tool), 'Subagent: Map the send path');
  });

  test('an ACP call reads by its kind', () {
    const tool = ToolActivity(
      name: 'tool',
      kind: 'read',
      subject: r'C:\src\app\pubspec.yaml',
    );
    expect(toolDoingPhrase(tool), 'Reading pubspec.yaml');
  });

  test('the description survives the wire and a result', () {
    final tool = toolActivityFor('Bash', {
      'command': 'k6 run load.js',
      'description': 'Load test the relay',
    });
    expect(ToolActivity.fromJson(tool.toJson()).description, tool.description);
    expect(tool.withResult(output: 'ok').description, 'Load test the relay');
  });
}
