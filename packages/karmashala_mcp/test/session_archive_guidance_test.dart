import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala_mcp/instructions.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:test/test.dart';

/// Agents tidy up after themselves: the guides say when to archive a child,
/// and the tools are catalogued as the ungated, undoable writes they are.
void main() {
  final sessions = kMcpGuides.firstWhere((g) => g.topic == 'sessions');

  test('the sessions guide teaches archiving a finished child', () {
    final text = sessions.render();
    expect(text, contains('session_archive'));
    expect(text, contains('session_unarchive'));
    expect(text, contains('merged or handed back'));
    expect(sessions.tools, containsAll(['session_archive', 'session_unarchive']));
  });

  test('the server instructions say the same in a sentence', () {
    expect(kKarmashalaMcpInstructions, contains('session_archive'));
    expect(kKarmashalaMcpInstructions, contains('ended'));
  });

  test('a parent ends its child once the work is merged or handed back, '
      'then archives it', () {
    expect(
      kKarmashalaMcpInstructions,
      contains('end it with session_end, then archive it with session_archive'),
    );
    expect(
      sessions.render(),
      contains('end it with `session_end`, then archive it'),
    );
  });

  test('both are catalogued, need no operator grant, and are listed', () {
    for (final tool in ['session_archive', 'session_unarchive']) {
      final annotations = kMcpToolAnnotations[tool];
      expect(annotations, isNotNull, reason: tool);
      expect(annotations!.readOnly, isFalse);
      expect(annotations.destructive, isFalse, reason: 'it is undone');
      expect(annotations.idempotent, isTrue);
      expect(annotations.movesAttention, isFalse);
      expect(mcpToolNeedsOperatorGrant(tool), isFalse, reason: tool);
      expect(kMcpToolListings[tool]?.category, McpToolCategory.sessions);
    }
  });
}
