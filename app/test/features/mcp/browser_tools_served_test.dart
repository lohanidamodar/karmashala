import 'package:karmashala/src/features/mcp/mcp_tool_dispatcher.dart';
import 'package:karmashala_browser/tools.dart';
import 'package:karmashala_host/mcp_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// The browser, the Flutter loop and builds are the server's since slice 3d:
/// `serverToolSchemas` serves every one of their tools, and this app serves
/// none of them — a tool in both would reach an agent twice, and one in
/// neither would quietly stop being offered.
void main() {
  test('the server serves the browser, Flutter and build tools; the app none '
      'of them', () {
    final server = [for (final s in serverToolSchemas) s['name']];
    final app = [for (final s in McpToolDispatcher.toolSchemas) s['name']];
    final moved = [
      for (final s in browserToolSchemas) s['name'],
      'flutter_apps',
      'flutter_attach',
      'flutter_reload',
      'flutter_logs',
      'flutter_pick_widget',
      'flutter_run',
      'project_build',
    ];

    expect(server, containsAll(moved));
    for (final name in moved) {
      expect(app, isNot(contains(name)), reason: '$name is the server\'s');
    }
    final all = [...server, ...app];
    expect(all.toSet(), hasLength(all.length));
  });
}
