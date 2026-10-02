import 'package:agent_cli/process.dart'
    show EnvironmentKind, EnvironmentPath, ExecutionEnvironment, PathTranslator;
import 'package:karmashala_acp/karmashala_acp.dart'
    show AcpRpcError, JsonRpcErrorCodes;
import 'package:path/path.dart' as p;

/// A path the agent named, resolved: [agent] as it spells it, [host] where
/// this server's filesystem has it.
typedef AcpResolvedPath = ({String agent, String host});

/// Where an agent's `fs/*` paths land. Checked under the working directory
/// in the agent's own spelling, then mapped to this machine: a WSL agent's
/// `/tmp/x` is `\\wsl.localhost\<distro>\tmp\x` here, and resolving it as a
/// Windows path would read and write the current drive's `\tmp\x` instead.
class AcpPathScope {
  AcpPathScope({
    required this.root,
    p.Context? context,
    String Function(String path)? toHost,
  }) : _context = context ?? p.context,
       _toHost = toHost ?? _same;

  /// The agent's working directory, in its spelling.
  final String root;
  final p.Context _context;
  final String Function(String path) _toHost;

  /// This machine's own paths for a local environment; the distribution's
  /// UNC share for a WSL one.
  factory AcpPathScope.forEnvironment(
    ExecutionEnvironment? environment,
    String root,
  ) {
    if (environment == null || environment.kind != EnvironmentKind.wsl) {
      return AcpPathScope(root: root);
    }
    final windows = ExecutionEnvironment(
      id: 'windows',
      kind: EnvironmentKind.windowsNative,
      name: 'Windows',
      createdAt: environment.createdAt,
    );
    const translator = PathTranslator();
    return AcpPathScope(
      root: root,
      context: p.posix,
      toHost: (path) => translator
          .translate(
            EnvironmentPath(environmentId: environment.id, path: path),
            from: environment,
            to: windows,
          )
          .path,
    );
  }

  /// [path] under [root], or -32602 in words with [verb] ("read",
  /// "written").
  AcpResolvedPath resolve(String path, {required String verb}) {
    final normalRoot = _context.normalize(root);
    final resolved = _context.normalize(
      _context.isAbsolute(path) ? path : _context.join(root, path),
    );
    if (!_context.equals(resolved, normalRoot) &&
        !_context.isWithin(normalRoot, resolved)) {
      throw AcpRpcError(
        JsonRpcErrorCodes.invalidParams,
        "the path $path is outside the session's working directory ($root), "
        'so it was not $verb',
      );
    }
    return (agent: resolved, host: _toHost(resolved));
  }

  static String _same(String path) => path;
}
