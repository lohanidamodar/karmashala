import 'package:karmashala/src/features/mcp/instructions_tools.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/mcp/mcp_tool_catalogue.dart';
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
      'session_end',
      'session_answer',
      'terminal_run',
      'terminal_close',
      'note_delete',
      'inbox_dismiss',
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

  group('a destructive family names its guide', () {
    // The table above says which tools cannot be undone. That is the right
    // answer to "should a client confirm this", and the wrong answer to "what
    // should I have known before calling it" — an annotation has no room to
    // say that a successful `terminal_run` may carry no exit code, or that
    // `checkpoint_restore` saves the tree it is about to overwrite. The guides
    // in `instructions_tools.dart` are where that goes, and this is what makes
    // writing one non-optional: a tool with no undo whose family nobody
    // documented fails here rather than shipping with a description and a
    // shrug.
    final claimed = <String, String>{
      for (final guide in kMcpGuides)
        for (final tool in guide.tools) tool: guide.topic,
    };

    test('every destructive tool is covered by a guide', () {
      final uncovered = <String>[
        for (final entry in kMcpToolAnnotations.entries)
          if (entry.value.destructive && !claimed.containsKey(entry.key))
            entry.key,
      ];
      expect(
        uncovered,
        isEmpty,
        reason:
            'these tools have no undo and no guide: add them to a family in '
            'instructions_tools.dart, or write a new one',
      );
    });

    test('no two guides claim the same tool', () {
      // Membership is computed from name prefixes, so an overlap is silent —
      // and an agent that reads one guide would be told a tool is somebody
      // else's problem while the other guide says the opposite.
      for (final tool in kMcpToolAnnotations.keys) {
        final owners = <String>[
          for (final guide in kMcpGuides)
            if (guide.claims(tool)) guide.topic,
        ];
        expect(
          owners.length,
          lessThan(2),
          reason: '$tool is claimed by ${owners.join(' and ')}',
        );
      }
    });

    test('a guide claims nothing that is not served', () {
      // Against the *declared* names, not the computed roster: the roster is
      // filtered through this table and so cannot disagree with it, while a
      // hand-written `extraTools` entry for a renamed tool would just quietly
      // stop covering anything.
      for (final guide in kMcpGuides) {
        expect(
          guide.extraTools.toSet().difference(kMcpToolAnnotations.keys.toSet()),
          isEmpty,
          reason: '${guide.topic} names a tool that no longer exists',
        );
      }
    });

    test('the guides tool is itself in the table', () {
      // It is served, so by the two assertions at the top of this file it has
      // to be here — this names it so the reason is visible.
      expect(kMcpToolAnnotations['instructions']?.readOnly, isTrue);
    });
  });
}
