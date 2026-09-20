import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_browser/tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one case from `browser_tools_test` that could not move into
/// `karmashala_browser` with the rest of it.
///
/// Everything else in that suite is about the tools themselves and runs under
/// `dart test` in the package now. This asserts that the app actually *serves*
/// them — that `browserToolSchemas` is wired into the control server's
/// catalogue beside the session tools, and that adding it collided with no
/// existing name. The package cannot know either fact, and losing it would
/// mean the browser tools could quietly stop being offered while every browser
/// test stayed green.
void main() {
  test('the control server serves the browser tools alongside its own', () {
    final names = [
      for (final s in LauncherControlServer.toolSchemas) s['name'],
    ];
    expect(names, containsAll(['list_sessions', 'browser_click']));
    expect(names.toSet(), hasLength(names.length));
    // The package's own list is the source: every schema it publishes has to
    // reach a client, not just the one named above.
    expect(names, containsAll([for (final s in browserToolSchemas) s['name']]));
  });
}
