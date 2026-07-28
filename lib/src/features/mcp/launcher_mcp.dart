import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'launcher_control_server.dart';

/// Prepares the `--mcp-config` file that points the launcher chat's agent at
/// Chitragupta's own tools (served by the MCP bridge, which in turn talks to the
/// in-app control server).
class LauncherMcp {
  const LauncherMcp();

  /// The MCP tool names to pre-approve for the launcher agent, derived from the
  /// control server's tool registry (server name is `chitragupta`).
  static List<String> get allowedTools => [
    for (final tool in LauncherControlServer.toolSchemas)
      'mcp__chitragupta__${tool['name']}',
  ];

  /// Resolves the bridge executable that ships next to the app, or `null` if it
  /// isn't present (e.g. a dev run without the compiled bridge).
  File? bridgeExecutable() {
    final dir = p.dirname(Platform.resolvedExecutable);
    final exe = File(p.join(dir, 'chitragupta_mcp.exe'));
    return exe.existsSync() ? exe : null;
  }

  /// Writes an MCP config file wiring the `chitragupta` server to the bridge and
  /// returns its path, or `null` when the bridge isn't available.
  Future<String?> ensureConfig() async {
    final bridge = bridgeExecutable();
    if (bridge == null) return null;
    final supportDir = await getApplicationSupportDirectory();
    final configFile = File(p.join(supportDir.path, 'launcher_mcp.json'));
    await configFile.writeAsString(
      jsonEncode({
        'mcpServers': {
          'chitragupta': {'command': bridge.path, 'args': <String>[]},
        },
      }),
      flush: true,
    );
    return configFile.path;
  }
}
