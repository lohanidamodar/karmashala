import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/mcp/mcp_tool_catalogue.dart';
import 'package:flutter_test/flutter_test.dart';

/// The served tool list, frozen byte for byte.
///
/// `LauncherControlServer.toolSchemas` is composed from a dozen files by
/// spreading each family's const list in a fixed order, and that composition is
/// the whole wire contract: an MCP client receives these names, in this order,
/// with these descriptions and these annotations. Moving a family out of the
/// server is meant to change none of it, and every ordinary test here checks
/// one tool at a time — so nothing would have noticed a family arriving in a
/// different place in the list, or a description picking up a stray space on
/// the way across.
///
/// So the whole payload is committed. A refactor that does not touch behaviour
/// leaves this file alone; a change that does touch it has to be made
/// deliberately, and the diff says exactly what a caller will see differently.
///
/// Regenerate only when the change is intended, and never as a side effect of
/// `--update-goldens` (which is why this is its own variable):
///
/// ```
/// KARMASHALA_WRITE_TOOL_SCHEMA_GOLDEN=1 flutter test \
///   test/features/mcp/tool_schemas_golden_test.dart
/// ```
const _goldenPath = 'test/features/mcp/tool_schemas.golden.json';

/// Everything a caller can observe about the catalogue: the served list, and
/// the per-tool listing the settings page reads.
Map<String, Object?> _catalogue() {
  final served = annotatedToolSchemas(LauncherControlServer.toolSchemas);
  return <String, Object?>{
    'note':
        'The served MCP tool list, in order. Regenerate with '
        'KARMASHALA_WRITE_TOOL_SCHEMA_GOLDEN=1; see '
        'test/features/mcp/tool_schemas_golden_test.dart.',
    'served': served,
    'listings': <String, Object?>{
      for (final schema in served)
        if (kMcpToolListings[schema['name']] case final listing?)
          schema['name']! as String: <String, Object?>{
            'category': listing.category.name,
            'summary': listing.summary,
          },
    },
  };
}

void main() {
  test('the served tool list matches the committed golden', () {
    final encoded =
        '${const JsonEncoder.withIndent('  ').convert(_catalogue())}\n';
    final file = File(_goldenPath);

    if (Platform.environment['KARMASHALA_WRITE_TOOL_SCHEMA_GOLDEN'] == '1') {
      file.writeAsStringSync(encoded);
      // ignore: avoid_print
      print('wrote $_goldenPath');
    }

    expect(
      file.existsSync(),
      isTrue,
      reason: '$_goldenPath is missing; see the header of this file',
    );
    expect(
      encoded,
      file.readAsStringSync(),
      reason:
          'The served tool list changed. If that was intended, regenerate the '
          'golden; if it was a refactor, something moved that should not have.',
    );
  });
}
