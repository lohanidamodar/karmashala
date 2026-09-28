import 'dart:io';

import 'package:path/path.dart' as p;

import '../../cli_detection/data/cli_store.dart';
import '../../environments/environment_kind.dart';
import '../../environments/execution_environment.dart';
import '../../process/command_runner.dart';
import 'auth_file_io.dart';

/// One agent's home in one environment, and the [io] that reads it.
class AgentHome {
  const AgentHome({
    required this.environmentId,
    required this.path,
    required this.paths,
    required this.io,
    this.localMacHost = false,
    this.fromVariable = false,
  });

  final String environmentId;

  /// The agent's home, spelled so [io] reaches it, or null when this
  /// environment has none for the agent.
  final String? path;

  /// The path rules [path] is spelled in.
  final p.Context paths;

  /// Whether the home is this machine's and this machine is a Mac, where a CLI
  /// may keep its credential in the login Keychain instead of a file.
  final bool localMacHost;

  /// Whether the host moved the home with the agent's own variable
  /// (`AgentStoreSpec.homeVariable`) rather than it being the default.
  final bool fromVariable;

  final AuthFileIo io;
}

/// Where an agent's files are in an installation's environment, and how to
/// reach them — the one answer the Accounts page and usage readings share.
///
/// The local host and WSL are the homes [CliStoreLocator] already maps for this
/// host to open. An SSH host's home is on its own disk: asked of the host
/// itself, remembered per environment once it answers, and read over that
/// environment's runner.
class AgentHomeLocator {
  AgentHomeLocator(this._stores, {bool? hostIsMacOS})
    : _hostIsMacOS = hostIsMacOS ?? Platform.isMacOS;

  final CliStoreLocator _stores;
  final bool _hostIsMacOS;

  final Map<String, RemoteAgentHomes> _remoteHomes = {};

  /// [agentId]'s home in [environmentId], or null when that environment's
  /// store could not be located.
  ///
  /// An SSH host that cannot be asked still gets a home, whose
  /// [RefusingAuthFileIo] says why.
  Future<AgentHome?> homeFor(
    String agentId,
    String environmentId,
    List<ExecutionEnvironment> environments,
  ) async {
    final environment = environments
        .where((e) => e.id == environmentId)
        .firstOrNull;
    if (environment != null && environment.kind == EnvironmentKind.ssh) {
      return _remoteHome(agentId, environment);
    }
    for (final store in await _stores.locate(environments)) {
      if (store.environmentId != environmentId) continue;
      final kind = environment?.kind;
      return AgentHome(
        environmentId: environmentId,
        path: store.homeFor(agentId),
        // The separator has to match the path the store locator produced.
        paths: storePathContextFor(kind),
        localMacHost: _hostIsMacOS && kind != null && isLocalHost(kind),
        io: environment == null
            ? const LocalAuthFileIo()
            : storeAuthFileIo(
                environment: environment,
                environments: environments,
                runnerFor: _stores.runnerFor,
                translator: _stores.translator,
              ),
      );
    }
    return null;
  }

  Future<AgentHome> _remoteHome(
    String agentId,
    ExecutionEnvironment environment,
  ) async {
    final store = _stores.registry.byId(agentId)?.store;
    AgentHome refused(String reason) => AgentHome(
      environmentId: environment.id,
      path: store == null ? null : p.posix.join('~', store.homeDirectoryName),
      paths: p.posix,
      io: RefusingAuthFileIo(reason),
    );

    final CommandRunner runner;
    try {
      runner = _stores.runnerFor(environment.id);
    } on Object catch (e) {
      return refused(
        'Karmashala has no connection to ${environment.name} ($e).',
      );
    }
    final io = RemoteAuthFileIo(
      runner: runner,
      environmentName: environment.name,
    );
    if (store == null) {
      return AgentHome(
        environmentId: environment.id,
        path: null,
        paths: p.posix,
        io: io,
      );
    }
    var homes = _remoteHomes[environment.id];
    if (homes == null) {
      try {
        homes = await resolveRemoteAgentHomes(
          runner,
          environmentName: environment.name,
        );
      } on AuthFileIoException catch (e) {
        // Not cached, so a host that comes back is picked up on the next read.
        return refused(e.message);
      }
      _remoteHomes[environment.id] = homes;
    }
    final variable = store.homeVariable;
    final moved = variable == null ? null : homes.variable(variable);
    return AgentHome(
      environmentId: environment.id,
      path: moved ?? p.posix.join(homes.home, store.homeDirectoryName),
      paths: p.posix,
      fromVariable: moved != null,
      io: io,
    );
  }
}
