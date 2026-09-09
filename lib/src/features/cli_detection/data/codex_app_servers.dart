import 'package:karmashala_core/logging.dart';
import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/path_translator.dart';
import '../../agents/data/agent_installation_dao.dart';
import '../../agents/domain/agent_ids.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import 'codex_app_server_client.dart';
import 'codex_app_server_launch.dart';

/// One live `codex app-server` per execution environment, opened on demand.
///
/// **Per environment, not per call and not per session.** A Windows Codex and a
/// WSL Codex are different executables over different stores, so they need
/// different connections — but every rename in one environment shares one, which
/// is what turns a ~1 s spawn into a one-off. Nothing is started until something
/// asks; a machine that never renames a Codex thread never runs `codex`.
///
/// Reuses the app's existing launch mechanism rather than inventing one:
/// `CommandRunnerFactory` picks the runner for the environment (`wsl.exe -d
/// $distro -- codex …` for WSL, the executable itself locally) and
/// `AgentInstallation` says where the binary is, exactly as `CodexAdapter` does
/// when it starts a session.
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
  ///
  /// [storeHome] is the store the caller means, spelled the way *this host* spells
  /// it — a Windows path, or the `\\wsl.localhost\…` UNC form. It is translated
  /// into the environment's own spelling and checked against what `initialize`
  /// reports, so a rename cannot land in another Codex's store. Omit it and any
  /// Codex that answers is accepted.
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
  /// expressed there — in which case no assertion is made rather than a wrong
  /// one.
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
