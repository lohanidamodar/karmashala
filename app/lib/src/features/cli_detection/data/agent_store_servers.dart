import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/process.dart';
import '../../agents/data/agents_data.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/environments_data.dart';

/// Told of a name an agent's store server gave a conversation on its own.
typedef ConversationNameListener =
    void Function(String agentId, ConversationNameUpdate update);

/// One live store server per (environment, agent), opened on demand — for an
/// agent whose adapter declares an `AgentStoreServer`. Per environment, so a
/// ~1 s spawn is paid once and never on an idle machine.
class AgentStoreServers {
  AgentStoreServers({
    required this.runnerFactory,
    required this.environments,
    required this.installations,
    this.registry = AgentRegistry.builtIn,
    this.translator = const PathTranslator(),
    this.clientVersion = '0.0.0',
    AppLogger? logger,
    this.onNameUpdated,
  }) : _log = logger ?? AppLogger.named('agents.storeServer');

  final CommandRunnerFactory runnerFactory;
  final EnvironmentsData environments;
  final AgentInstallationsData installations;
  final AgentRegistry registry;
  final PathTranslator translator;
  final String clientVersion;
  final ConversationNameListener? onNameUpdated;

  final AppLogger _log;

  final Map<(String, String), AgentStoreServerClient> _open = {};

  /// Connections handed out, whether or not they have spawned anything yet.
  /// A count, so "did this open a second one?" is answerable.
  int get openConnections => _open.length;

  /// [agentId]'s store server in [environmentId], or `null` when its adapter
  /// declares none or it is not installed there. [storeHome] is checked against
  /// the server's own idea of its store, so a rename cannot go astray.
  AgentStoreServerClient? forEnvironment(
    String environmentId,
    String agentId, {
    String? storeHome,
  }) {
    final cached = _open[(environmentId, agentId)];
    if (cached != null) return cached;

    final server = registry.adapterFor(agentId)?.storeServer;
    if (server == null) return null;

    // The one resolver, so an SSH environment with no pool composed is a
    // refusal with words rather than a throw out of the factory below.
    final resolved = ExecutionEnvironmentResolver(
      environments: environments,
      runners: runnerFactory,
    ).resolve(environmentId);
    final environment = resolved.environment;
    if (environment == null) {
      _log.debug('No environment for $environmentId: ${resolved.reason}');
      return null;
    }
    final executable = _executable(environmentId, agentId);
    if (executable == null) return null;

    final CommandRunner runner;
    try {
      runner = runnerFactory.forEnvironment(environment);
    } on Object catch (error) {
      // An SSH environment with no connection pool composed, most likely.
      _log.debug('No command runner for $environmentId: $error');
      return null;
    }

    final listener = onNameUpdated;
    final client = server.open(
      connect: () => runner.start(
        CommandRequest(executable: executable, arguments: server.arguments),
      ),
      clientVersion: clientVersion,
      expectedHome: _expectedHomeIn(environment, storeHome),
      onNameUpdated: listener == null
          ? null
          : (update) => listener(agentId, update),
    );
    _open[(environmentId, agentId)] = client;
    return client;
  }

  /// Closes every connection. Called when the owning scope is disposed, so a
  /// quit leaves no store server behind.
  Future<void> closeAll() async {
    final open = _open.values.toList(growable: false);
    _open.clear();
    for (final client in open) {
      await client.close();
    }
  }

  String? _executable(String environmentId, String agentId) {
    for (final installation in installations.getByEnvironment(environmentId)) {
      if (installation.agentId == agentId) return installation.executable.path;
    }
    return null;
  }

  /// [storeHome] in the environment's own spelling, or `null` when it cannot be
  /// expressed there — better no assertion than a wrong one.
  String? _expectedHomeIn(ExecutionEnvironment environment, String? storeHome) {
    if (storeHome == null || storeHome.isEmpty) return null;
    if (environment.kind != EnvironmentKind.wsl) return storeHome;
    ExecutionEnvironment? windows;
    for (final candidate in environments.getAll()) {
      if (candidate.kind == EnvironmentKind.windowsNative) {
        windows = candidate;
        break;
      }
    }
    if (windows == null) return null;
    try {
      return translator
          .translate(
            EnvironmentPath(environmentId: windows.id, path: storeHome),
            from: windows,
            to: environment,
          )
          .path;
    } on PathTranslationException {
      return null;
    }
  }
}
