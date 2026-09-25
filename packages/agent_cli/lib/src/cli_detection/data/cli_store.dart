import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_registry.dart';
import '../../environments/environment_kind.dart';
import '../../environments/environment_path.dart';
import '../../environments/execution_environment.dart';
import '../../process/command_runner.dart';
import '../../process/command_runner_factory.dart';
import '../../process/path_translator.dart';
import '../../agents/adapter/store_server_launch.dart';

/// The CLI store homes to scan for one environment, keyed by agent registry id.
class CliStore {
  const CliStore({
    required this.environmentId,
    required this.homesByAgentId,
    this.storeServersByAgentId = const {},
  });

  final String environmentId;

  /// `AgentDescriptor.id` → how to reach that agent's store server in this
  /// environment, for an agent whose adapter declares one and that is
  /// installed here. Plain data, because it crosses to the worker isolate
  /// where the spawn has to happen — see [StoreServerLaunch].
  final Map<String, StoreServerLaunch> storeServersByAgentId;

  /// `AgentDescriptor.id` → the agent's store home in this environment, in a
  /// form the app can read directly (Windows-native or a `\\wsl.localhost\…`
  /// UNC path).
  final Map<String, String> homesByAgentId;

  /// [agentId]'s store home here, or null when it declares none.
  String? homeFor(String agentId) => homesByAgentId[agentId];

  /// How to reach [agentId]'s store server here, or null.
  StoreServerLaunch? storeServerFor(String agentId) =>
      storeServersByAgentId[agentId];
}

/// Resolves the on-disk CLI store homes for each environment. Which stores
/// exist comes from the agent registry; the local host's store lives under the
/// user's home directory, and WSL stores are reached from Windows via the
/// `\\wsl.localhost\…` UNC form of the distribution's `$HOME`.
class CliStoreLocator {
  CliStoreLocator({
    required this.runnerFor,
    this.translator = const PathTranslator(),
    this.registry = AgentRegistry.builtIn,
    this.installations = const [],
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  /// The runner that reaches one environment, by id.
  ///
  /// A function rather than a `CommandRunnerFactory`: this used to hold the
  /// factory itself, which reached an SSH connection pool and through it a
  /// database, for the sake of one `bash -lc 'printf %s "$HOME"'`
  /// (docs/PACKAGE_SPLIT.md §3).
  final RunnerResolver runnerFor;

  final PathTranslator translator;
  final AgentRegistry registry;

  /// Where each environment's agents are installed, so a store whose agent
  /// offers a store server can be read through it rather than by walking its
  /// files. Leave it empty and every store is walked.
  ///
  /// A list of values, not a DAO. The caller already holds the installations —
  /// asking it to pass them keeps a database out of the one class that has to
  /// run inside a worker isolate.
  final List<AgentInstallation> installations;

  /// The process environment the home directory is read from. Injected so the
  /// per-platform lookup is testable off the platform it describes.
  final Map<String, String> environment;

  Future<List<CliStore>> locate(List<ExecutionEnvironment> environments) async {
    // The machine this app is running on, whichever OS that is. Matching only
    // `windowsNative` here is what made session detection come up empty on a
    // Mac: the host is `localPosix`, so no store was located, and with no store
    // there are no sessions, no projects and no chat to adopt.
    ExecutionEnvironment? local;
    // The WSL translation below needs a genuinely Windows environment, which is
    // a different question and only ever has one answer on Windows.
    ExecutionEnvironment? windows;
    for (final env in environments) {
      // What this loop and the WSL pass below cover is what
      // `cliStoreIsReachable` promises; the two must not drift.
      if (local == null && isLocalHost(env.kind)) local = env;
      if (windows == null && env.kind == EnvironmentKind.windowsNative) {
        windows = env;
      }
    }

    final stores = <CliStore>[];
    final home = local == null ? null : _localHomeDirectory(local.kind);
    if (local != null && home != null) {
      stores.add(
        CliStore(
          environmentId: local.id,
          homesByAgentId: _homesUnder(
            home,
            usesWindowsPaths(local.kind) ? p.windows : p.posix,
          ),
          storeServersByAgentId: _storeServers(local),
        ),
      );
    }

    if (windows != null) {
      for (final env in environments) {
        if (env.kind != EnvironmentKind.wsl) continue;
        final wslHome = await _wslHome(env);
        if (wslHome == null) continue;
        // A UNC path into the distribution, so it is spelled the Windows way
        // even though what it names is a Linux home.
        final unc = translator
            .translate(
              EnvironmentPath(environmentId: env.id, path: wslHome),
              from: env,
              to: windows,
            )
            .path;
        stores.add(
          CliStore(
            environmentId: env.id,
            homesByAgentId: _homesUnder(unc, p.windows),
            storeServersByAgentId: _storeServers(env),
          ),
        );
      }
    }
    return stores;
  }

  /// This user's home directory: `%USERPROFILE%` on Windows, `$HOME` elsewhere.
  ///
  /// Windows sets `HOME` only sometimes (Git Bash and MSYS do, a plain session
  /// does not) and `USERPROFILE` is not set off Windows at all, so each host is
  /// asked for the variable it actually defines rather than one being tried as
  /// a fallback for the other.
  ///
  /// Keyed on [kind] rather than on `Platform`, because [kind] is already the
  /// answer to "which host is this" and taking it from there keeps both
  /// branches reachable from a test on either OS.
  String? _localHomeDirectory(EnvironmentKind kind) {
    final name = usesWindowsPaths(kind) ? 'USERPROFILE' : 'HOME';
    final value = environment[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// The store servers installed in [environment], one per agent whose
  /// adapter declares one, as something the worker can spawn.
  Map<String, StoreServerLaunch> _storeServers(
    ExecutionEnvironment environment,
  ) {
    final launches = <String, StoreServerLaunch>{};
    for (final installation in installations) {
      if (installation.environmentId != environment.id) continue;
      final agentId = installation.agentId;
      if (registry.adapterFor(agentId)?.storeServer == null) continue;
      launches.putIfAbsent(
        agentId,
        () => StoreServerLaunch(
          environment: environment,
          executable: installation.executable.path,
        ),
      );
    }
    return launches;
  }

  /// One home per registry agent that declares a store, under [homeDirectory].
  Map<String, String> _homesUnder(String homeDirectory, p.Context context) => {
    for (final descriptor in registry.descriptors)
      if (descriptor.store != null)
        descriptor.id: context.join(
          homeDirectory,
          descriptor.store!.homeDirectoryName,
        ),
  };

  final Map<String, String> _wslHomeCache = {};

  Future<String?> _wslHome(ExecutionEnvironment env) async {
    final cached = _wslHomeCache[env.id];
    if (cached != null) return cached;
    final runner = runnerFor(env.id);
    try {
      final result = await runner.run(
        const CommandRequest(
          executable: 'bash',
          arguments: ['-lc', r'printf %s "$HOME"'],
          timeout: kProbeTimeout,
        ),
      );
      final home = result.stdout.trim();
      if (result.ok && home.isNotEmpty) {
        _wslHomeCache[env.id] = home;
        return home;
      }
      return null;
    } on CommandException {
      return null;
    }
  }
}
