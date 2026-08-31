import 'package:chitragupta/src/features/mcp/launcher_control_server.dart';
import 'package:chitragupta/src/features/mcp/mcp_tool_catalogue.dart';
import 'package:flutter_test/flutter_test.dart';

/// The annotation table, held against the tools it describes.
///
/// The table's whole value is that it is complete. An annotation a client never
/// receives is worse than none at all — it reads as "this tool was considered
/// and found safe" when what happened is that nobody looked. So the coverage is
/// asserted in both directions, and a new tool cannot ship until someone has
/// decided whether it can be undone.
void main() {
  final servedNames = <String>{
    for (final schema in LauncherControlServer.toolSchemas)
      schema['name']! as String,
  };

  test('every served tool declares what it does', () {
    expect(
      servedNames.difference(kMcpToolAnnotations.keys.toSet()),
      isEmpty,
      reason: 'these tools are served with no annotations',
    );
  });

  test('the table describes no tool that is not served', () {
    expect(
      kMcpToolAnnotations.keys.toSet().difference(servedNames),
      isEmpty,
      reason: 'these annotations describe a tool that no longer exists',
    );
  });

  test('a read-only tool is never also destructive', () {
    for (final entry in kMcpToolAnnotations.entries) {
      if (!entry.value.readOnly) continue;
      expect(
        entry.value.destructive,
        isFalse,
        reason: '${entry.key} cannot both change nothing and destroy something',
      );
    }
  });

  test('the tools that end things say so', () {
    // Named individually rather than counted: the point is that *these* are
    // marked, and a rename of one must fail here rather than pass on a total.
    for (final name in const [
      'checkpoint_restore',
      'device_stop_emulator',
      'device_tap',
      'browser_evaluate',
    ]) {
      expect(
        kMcpToolAnnotations[name]?.destructive,
        isTrue,
        reason: '$name has no undo and must be annotated as destructive',
      );
    }
  });

  test('annotations reach the served schemas, and only add to them', () {
    final annotated = annotatedToolSchemas(LauncherControlServer.toolSchemas);
    expect(annotated, hasLength(LauncherControlServer.toolSchemas.length));
    for (var i = 0; i < annotated.length; i++) {
      final original = LauncherControlServer.toolSchemas[i];
      final hints = annotated[i]['annotations']! as Map<String, Object?>;
      expect(annotated[i]['name'], original['name']);
      expect(annotated[i]['description'], original['description']);
      expect(annotated[i]['inputSchema'], original['inputSchema']);
      // All four are written out. The spec defaults `destructiveHint` to true
      // and `openWorldHint` to true, so an omitted hint is a claim of its own.
      expect(hints.keys, <String>{
        'readOnlyHint',
        'destructiveHint',
        'idempotentHint',
        'openWorldHint',
      });
    }
  });
}
