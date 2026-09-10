import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/process.dart';
import '../../agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
import 'package:agent_cli/read.dart';

/// One live `codex app-server` per execution environment, opened on demand —
/// per environment, so a ~1 s spawn is paid once and never on an idle machine.
class CodexAppServers {
  CodexAppServers({
    required this.runnerFactory,
    required this.environments,
    required this.installations,
    this.translator = const PathTranslator(),
    this.clientVersion = '0.0.0',
    AppLogger? logger,
    this.onThreadNameUpdated,
  }) : _log = logger ?? AppLogger.named('codex.appServer');

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environments;
  final AgentInstallationDao installations;
  final PathTranslator translator;
  final String clientVersion;
  final void Function(CodexThreadNameUpdate update)? onThreadNameUpdated;

  final AppLogger _log;

  final Map<String, CodexAppServerClient> _byEnvironment = {};

  /// Connections handed out, whether or not they have spawned anything yet.
  /// A count, so "did this open a second one?" is answerable.
  int get openConnections => _byEnvironment.length;

  /// The app-server for [environmentId], or `null` when there is no Codex there.
  /// [storeHome] is checked against `initialize`, so a rename cannot go astray.
  CodexAppServerClient? forEnvironment(String environmentId, {String? storeHome}) {
    final cached = _byEnvironment[environmentId];
    if (cached != null) return cached;

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
    final executable = _codexExecutable(environmentId);
    if (executable == null) return null;

    final CommandRunner runner;
    try {
      runner = runnerFactory.forEnvironment(environment);
    } on Object catch (error) {
      // An SSH environment with no connection pool composed, most likely.
      _log.debug('No command runner for $environmentId: $error');
      return null;
    }

    final client = CodexAppServerClient(
      connect: () => runner.start(
        CommandRequest(
          executable: executable,
          arguments: codexAppServerArguments,
        ),
      ),
      clientVersion: clientVersion,
      expectedCodexHome: _expectedHomeIn(environment, storeHome),
      onThreadNameUpdated: onThreadNameUpdated,
    );
    _byEnvironment[environmentId] = client;
    return client;
  }

  /// Closes every connection. Called when the owning scope is disposed, so a
  /// quit leaves no `codex` behind.
  Future<void> closeAll() async {
    final open = _byEnvironment.values.toList(growable: false);
    _byEnvironment.clear();
    for (final client in open) {
      await client.close();
    }
  }

  String? _codexExecutable(String environmentId) {
    for (final installation in installations.getByEnvironment(environmentId)) {
      if (installation.agentId == AgentIds.codex) {
        return installation.executable.path;
      }
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
