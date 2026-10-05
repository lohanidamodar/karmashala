import 'package:karmashala_host/src/acp/claude/claude_tools.dart';
import 'package:test/test.dart';

/// How a Claude tool result reads in a chat session's tool row.
void main() {
  test('a ToolSearch says which tools it loaded', () {
    expect(
      ClaudeTools.resultText([
        {'type': 'tool_reference', 'tool_name': 'WebFetch'},
        {'type': 'tool_reference', 'tool_name': 'mcp__docs__read'},
      ]),
      'Loaded tools: WebFetch, mcp__docs__read',
    );
  });
}
