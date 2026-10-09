import 'package:agent_cli/process.dart'
    show
        EnvironmentKind,
        EnvironmentPath,
        ExecutionEnvironment,
        PathTranslationException,
        PathTranslator;
import 'package:karmashala_acp/karmashala_acp.dart'
    show AcpRpcError, JsonRpcErrorCodes;
import 'package:path/path.dart' as p;

/// A path the agent named, resolved: [agent] as it spells it, [host] where
/// this server's filesystem has it.
typedef AcpResolvedPath = ({String agent, String host});

/// Where an agent's `fs/*` paths land. Checked under the working directory
/// or a checkout attached to the session, in the agent's own spelling, then
/// mapped to this machine: a WSL agent's `/tmp/x` is
/// `\\wsl.localhost\<distro>\tmp\x` here, and resolving it as a Windows path
/// would read and write the current drive's `\tmp\x` instead.
class AcpPathScope {
  AcpPathScope({
    required this.root,
    p.Context? context,
    String Function(String path)? toHost,
    this.hostSplitsBackslash = false,
    this.environmentId,
    List<EnvironmentPath> Function()? checkouts,
  }) : _context = context ?? p.context,
       _toHost = toHost ?? _same,
       _checkouts = checkouts;

  /// The agent's working directory, in its spelling.
  final String root;
  final p.Context _context;
  final String Function(String path) _toHost;

  /// Whether this machine reads `\` as a separator where the agent does not:
  /// a WSL agent's `..\..\x` is one name to it, and two steps up here.
  final bool hostSplitsBackslash;

  /// The environment [root] is in; a checkout elsewhere is a root only when
  /// the agent has a name for it.
  final String? environmentId;

  /// The checkouts the session spans now, asked on every resolve so an
  /// attach or detach holds from the next request.
  final List<EnvironmentPath> Function()? _checkouts;

  /// This machine's own paths for a local environment; the distribution's
  /// UNC share for a WSL one.
  factory AcpPathScope.forEnvironment(
    ExecutionEnvironment? environment,
    String root, {
    String? environmentId,
    List<EnvironmentPath> Function()? checkouts,
  }) {
    if (environment == null || environment.kind != EnvironmentKind.wsl) {
      return AcpPathScope(
        root: root,
        environmentId: environmentId,
        checkouts: checkouts,
      );
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
      hostSplitsBackslash: true,
      environmentId: environmentId ?? environment.id,
      checkouts: checkouts,
    );
  }

  /// The attached checkouts outside [root], in the agent's spelling: one in
  /// [root]'s environment as it is, a Windows one as its mount for a WSL
  /// agent. Empty when the store cannot say.
  List<String> get attachedRoots {
    final List<EnvironmentPath> checkouts;
    try {
      checkouts = _checkouts?.call() ?? const [];
    } on Object {
      return const [];
    }
    final normalRoot = _context.normalize(root);
    final roots = <String>[];
    for (final checkout in checkouts) {
      final spelled = _spell(checkout);
      if (spelled == null) continue;
      final normal = _context.normalize(spelled);
      if (!_context.isAbsolute(normal) ||
          _within(normalRoot, normal) ||
          roots.any((kept) => _within(kept, normal))) {
        continue;
      }
      roots.add(normal);
    }
    return roots;
  }

  String? _spell(EnvironmentPath checkout) {
    if (checkout.environmentId == environmentId) return checkout.path;
    if (!hostSplitsBackslash) return null;
    try {
      return const PathTranslator().windowsDriveToWslMount(checkout.path);
    } on PathTranslationException {
      return null;
    }
  }

  bool _within(String parent, String path) =>
      _context.equals(path, parent) || _context.isWithin(parent, path);

  /// [path] under [root] or an attached checkout, or -32602 in words with
  /// [verb] ("read", "written").
  AcpResolvedPath resolve(String path, {required String verb}) {
    final normalRoot = _context.normalize(root);
    final resolved = _context.normalize(
      _context.isAbsolute(path) ? path : _context.join(root, path),
    );
    final escapes = hostSplitsBackslash && path.contains(r'\');
    if (escapes ||
        (!_within(normalRoot, resolved) &&
            !attachedRoots.any((attached) => _within(attached, resolved)))) {
      throw AcpRpcError(
        JsonRpcErrorCodes.invalidParams,
        "the path $path is outside the session's working directory ($root) "
        'and the checkouts attached to it, so it was not $verb',
      );
    }
    return (agent: resolved, host: _toHost(resolved));
  }

  static String _same(String path) => path;
}
