import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// What the ask dock says of a call: the verb and the thing it acts on —
/// never the call's raw input as JSON.
void main() {
  AgentToolAsk ask(
    String toolName,
    Map<String, Object?> input, {
    String? kind,
  }) => AgentToolAsk(
    toolName: toolName,
    input: input,
    at: DateTime.utc(2026, 10, 4),
    kind: kind,
  );

  test('a call named by its ACP kind alone says what it does', () {
    final run = summarizeToolAsk(
      ask('sh -c "exit 3"', const {
        'command': 'sh -c "exit 3"',
      }, kind: 'execute'),
    );
    expect(run.action, 'run a command');
    expect(run.subject, 'sh -c "exit 3"');
    expect(run.isCommand, isTrue);

    final edit = summarizeToolAsk(
      ask('Edit notes.txt', const {'path': r'C:\w\notes.txt'}, kind: 'edit'),
    );
    expect(edit.action, 'edit a file');
    expect(edit.subject, r'C:\w\notes.txt');
  });

  test('a command given as argv reads as one command line', () {
    final run = summarizeToolAsk(
      ask('Run', const {
        'command': ['git', 'status'],
      }, kind: 'execute'),
    );
    expect(run.subject, 'git status');
  });

  test('an unknown tool shows its main argument, never JSON', () {
    final mcp = summarizeToolAsk(
      ask('mcp__karmashala__todo_add', const {
        'body': 'Buy milk',
        'priority': 2,
      }),
    );
    expect(mcp.action, 'use todo_add (karmashala)');
    expect(mcp.subject, 'Buy milk');

    final other = summarizeToolAsk(ask('Frobnicate', const {'n': 3}));
    expect(other.subject, isNot(contains('{')));
  });
}
