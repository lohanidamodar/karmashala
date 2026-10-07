import 'package:karmashala_mcp/protocol.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:test/test.dart';

/// Every MCP-capable agent learns to show what it made in its thread, and
/// doing so needs no operator grant: an artifact belongs to its own session.
void main() {
  test('the server instructions name artifact_show', () {
    expect(kKarmashalaMcpInstructions, contains('artifact_show'));
  });

  test('the server instructions say what the chat draws inline', () {
    for (final fence in ['mermaid', 'chart', 'diff', 'json', 'ansi', r'$$']) {
      expect(kKarmashalaMcpInstructions, contains(fence));
    }
  });

  test('showing and updating an artifact need no grant', () {
    expect(mcpToolNeedsOperatorGrant('artifact_show'), isFalse);
    expect(mcpToolNeedsOperatorGrant('artifact_update'), isFalse);
    expect(kMcpToolAnnotations['artifact_list']!.readOnly, isTrue);
  });

  test('the artifact tools are listed under their own heading', () {
    for (final tool in ['artifact_show', 'artifact_list', 'artifact_update']) {
      expect(kMcpToolListings[tool]!.category, McpToolCategory.artifacts);
    }
  });
}
