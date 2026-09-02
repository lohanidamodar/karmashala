import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/path_translator.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_registry.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../data/antigravity_store_sessions.dart';
import '../data/claude_store_reader.dart';
import '../data/codex_store_reader.dart';
import '../domain/detected_project.dart';
import '../domain/detected_session.dart';
import 'detected_project_merger.dart';

/// The CLI store homes to scan for one environment, keyed by agent registry id.
class CliStore {
  const CliStore({required this.environmentId, required this.homesByAgentId});

  final String environmentId;

  /// `AgentDescriptor.id` → the agent's store home in this environment, in a
  /// form the app can read directly (Windows-native or a `\\wsl.localhost\…`
  /// UNC path).
  final Map<String, String> homesByAgentId;

  String? get claudeHome => homesByAgentId['claudeCode'];
  String? get codexHome => homesByAgentId['codex'];
}

/// Resolves the on-disk CLI store homes for each environment. Which stores
/// exist comes from the agent registry; the local host's store lives under the
/// user's home directory, and WSL stores are reached from Windows via the
/// `\\wsl.localhost\…` UNC form of the distribution's `$HOME`.
class CliStoreLocator {
  CliStoreLocator({
    required this.runnerFactory,
    this.translator = const PathTranslator(),
    this.registry = AgentRegistry.builtIn,
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final CommandRunnerFactory runnerFactory;
  final PathTranslator translator;
  final AgentRegistry registry;

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

  /// One home per registry agent that declares a store, under [homeDirectory].
  Map<String, String> _homesUnder(String homeDirectory, p.Context context) => {
    for (final descriptor in registry.descriptors)
      if (descriptor.store != null)
        descriptor.id: context.join(
          homeDirectory,
          descriptor.store!.homeDirectoryName,
        ),
  };

  Future<String?> _wslHome(ExecutionEnvironment env) async {
    final runner = runnerFactory.forEnvironment(env);
    try {
      final result = await runner.run(
        const CommandRequest(
          executable: 'bash',
          arguments: ['-lc', r'printf %s "$HOME"'],
        ),
      );
      final home = result.stdout.trim();
      return result.ok && home.isNotEmpty ? home : null;
    } on CommandException {
      return null;
    }
  }
}

/// Reads CLI stores and merges their sessions into projects.
class CliDetectionService {
  CliDetectionService({
    ClaudeStoreReader? claudeReader,
    this.codexReader = const CodexStoreReader(),
    this.antigravityReader = const AntigravityStoreSessions(),
    this.translator = const PathTranslator(),
    this.registry = AgentRegistry.builtIn,
    // Not const any more: the Claude reader carries the cache that keeps a
    // scan proportional to what changed rather than to the whole store.
  }) : claudeReader = claudeReader ?? ClaudeStoreReader();

  final ClaudeStoreReader claudeReader;
  final CodexStoreReader codexReader;
  final AntigravityStoreSessions antigravityReader;
  final PathTranslator translator;
  final AgentRegistry registry;

  /// Reads every store and returns the flat list of detected sessions.
  ///
  /// Which stores are read, and in which order, comes from the registry; the
  /// descriptor's [AgentStoreFormat] picks the reader. A new agent using a
  /// known format needs no code here — only a genuinely new on-disk format
  /// needs a reader.
  Future<List<DetectedSession>> readStores(List<CliStore> stores) async {
    final all = <DetectedSession>[];
    for (final store in stores) {
      for (final descriptor in registry.descriptors) {
        final home = store.homesByAgentId[descriptor.id];
        if (home == null) continue;
        switch (descriptor.store!.format) {
          case AgentStoreFormat.claudeJsonl:
            all.addAll(await claudeReader.read(home, store.environmentId));
          case AgentStoreFormat.codexRollout:
            all.addAll(await codexReader.read(home, store.environmentId));
          case AgentStoreFormat.antigravityStore:
            all.addAll(
              await antigravityReader.read(home, store.environmentId),
            );
          case AgentStoreFormat.none:
            break; // Store located but not readable yet.
        }
      }
    }
    return all;
  }

  /// Reads [stores] and merges the sessions into projects, using
  /// [environmentsById] to canonicalize paths across environments.
  Future<List<DetectedProject>> detect(
    List<CliStore> stores,
    Map<String, ExecutionEnvironment> environmentsById,
  ) async {
    final sessions = await readStores(stores);
    return mergeDetectedProjects(
      sessions,
      environmentsById,
      translator: translator,
    );
  }
}
