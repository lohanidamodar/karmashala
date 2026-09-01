import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'launcher_control_server.dart';
import 'mcp_tool_catalogue.dart';

/// How an agent is told where Karmashala's own tools are.
///
/// There are two ways to say it, and the difference is which process ends up
/// speaking MCP:
///
/// * **`http`** — the agent dials `POST /mcp` on the app directly. Nothing is
///   spawned, the app is the server, and the URL carries the session's identity
///   (see [LauncherControlServer.mcpUrlFor]). This is the form to prefer.
/// * **`command`** — the agent spawns `karmashala_mcp.exe`, which translates
///   stdio MCP into the app's private `/rpc` envelope. Kept because it is what
///   exists on disk today, and because a config already written this way must
///   keep working; but the executable ships beside the Windows binary only, and
///   an agent in WSL or over SSH cannot name that path at all.
///
/// Nothing in the app calls [ensureConfig] yet. `LauncherMcp`'s only caller was
/// the launcher chat, deleted with mini mode, and the session-launch path has
/// no field to carry a config path — see `docs/MCP_CONTROL_SURFACE.md` §6.1.
/// What is here is the half of that seam this feature owns: given a URL, it
/// writes a config an agent CLI will accept.
class LauncherMcp {
  const LauncherMcp();

  /// The MCP tool names to pre-approve, derived from the one tool registry so a
  /// tool cannot be served and un-approved at the same time.
  static List<String> get allowedTools => [
    for (final tool in LauncherControlServer.toolSchemas)
      'mcp__karmashala__${tool['name']}',
  ];

  /// The tools that change nothing, for a caller that wants to pre-approve
  /// reads and leave everything else to be asked about.
  ///
  /// Read off the same annotation table `tools/list` serves, so this list and
  /// the `readOnlyHint` a client sees can never disagree.
  static List<String> get readOnlyTools => [
    for (final tool in LauncherControlServer.toolSchemas)
      if (kMcpToolAnnotations[tool['name']]?.readOnly ?? false)
        'mcp__karmashala__${tool['name']}',
  ];

  /// Resolves the bridge executable that ships next to the app, or `null` if it
  /// isn't present (e.g. a dev run without the compiled bridge).
  File? bridgeExecutable() {
    final dir = p.dirname(Platform.resolvedExecutable);
    final exe = File(p.join(dir, 'karmashala_mcp.exe'));
    return exe.existsSync() ? exe : null;
  }

  /// A Claude-Code-shaped `mcpServers` entry for the app's HTTP endpoint.
  ///
  /// The credential is in the URL rather than in `headers` on purpose: Claude
  /// Code has a standing bug in which configured headers are not attached to
  /// requests for a Streamable HTTP server (anthropics/claude-code#48514), and
  /// a URL is the one field every client sends verbatim. `type: http` is what
  /// the client expects; the spec's own name for the transport,
  /// `streamable-http`, is accepted as an alias.
  static Map<String, Object?> httpServerEntry(String url) => <String, Object?>{
    'type': 'http',
    'url': url,
  };

  /// A stdio entry pointing at the bridge executable.
  static Map<String, Object?> bridgeServerEntry(String executablePath) =>
      <String, Object?>{'command': executablePath, 'args': <String>[]};

  /// The `[mcp_servers.karmashala]` block Codex reads from its `config.toml`.
  ///
  /// A `url` key is what tells Codex to use Streamable HTTP; the token rides in
  /// the URL for the same reason it does above, which also avoids needing an
  /// environment variable named in `bearer_token_env_var` and set on the
  /// process. Nothing writes this file yet — see the class doc — but the
  /// formatting is here so the follow-up is a write, not a design.
  static String codexServerToml(String url) =>
      '[mcp_servers.karmashala]\nurl = "$url"\n';

  /// Writes an MCP config file and returns its path, or `null` when there is
  /// nothing to point an agent at.
  ///
  /// [url] is preferred; the bridge is the fallback. [directory] and [fileName]
  /// exist so a per-session config can live beside the session rather than
  /// overwriting one shared file — two sessions must not share a config,
  /// because the URL in it is what says which session is calling.
  Future<String?> ensureConfig({
    String? url,
    String? directory,
    String fileName = 'launcher_mcp.json',
  }) async {
    final Map<String, Object?> entry;
    if (url != null && url.isNotEmpty) {
      entry = httpServerEntry(url);
    } else {
      final bridge = bridgeExecutable();
      if (bridge == null) return null;
      entry = bridgeServerEntry(bridge.path);
    }
    final dir = directory ?? (await getApplicationSupportDirectory()).path;
    final configFile = File(p.join(dir, fileName));
    await configFile.parent.create(recursive: true);
    await configFile.writeAsString(
      jsonEncode({
        'mcpServers': {'karmashala': entry},
      }),
      flush: true,
    );
    return configFile.path;
  }
}
