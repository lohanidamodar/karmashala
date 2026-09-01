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
/// exist comes from the agent registry; the Windows host store lives under
/// `%USERPROFILE%`, and WSL stores are reached from Windows via the
/// `\\wsl.localhost\…` UNC form of the distribution's `$HOME`.
class CliStoreLocator {
  CliStoreLocator({
    required this.runnerFactory,
    this.translator = const PathTranslator(),
    this.registry = AgentRegistry.builtIn,
  });

  final CommandRunnerFactory runnerFactory;
  final PathTranslator translator;
  final AgentRegistry registry;

  Future<List<CliStore>> locate(List<ExecutionEnvironment> environments) async {
    ExecutionEnvironment? windows;
    for (final env in environments) {
      if (env.kind == EnvironmentKind.windowsNative) {
        windows = env;
        break;
      }
    }

    final stores = <CliStore>[];
    final userProfile = Platform.environment['USERPROFILE'];
    if (windows != null && userProfile != null && userProfile.isNotEmpty) {
      stores.add(
        CliStore(
          environmentId: windows.id,
          homesByAgentId: _homesUnder(userProfile),
        ),
      );
    }

    if (windows != null) {
      for (final env in environments) {
        if (env.kind != EnvironmentKind.wsl) continue;
        final home = await _wslHome(env);
        if (home == null) continue;
        final unc = translator
            .translate(
              EnvironmentPath(environmentId: env.id, path: home),
              from: env,
              to: windows,
            )
            .path;
        stores.add(
          CliStore(environmentId: env.id, homesByAgentId: _homesUnder(unc)),
        );
      }
    }
    return stores;
  }

  /// One home per registry agent that declares a store, under [homeDirectory].
  Map<String, String> _homesUnder(String homeDirectory) => {
    for (final descriptor in registry.descriptors)
      if (descriptor.store != null)
        descriptor.id: p.windows.join(
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
  const CliDetectionService({
    this.claudeReader = const ClaudeStoreReader(),
    this.codexReader = const CodexStoreReader(),
    this.antigravityReader = const AntigravityStoreSessions(),
    this.translator = const PathTranslator(),
    this.registry = AgentRegistry.builtIn,
  });

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
