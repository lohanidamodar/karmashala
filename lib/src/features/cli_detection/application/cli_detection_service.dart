import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/path_translator.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../data/claude_store_reader.dart';
import '../data/codex_store_reader.dart';
import '../domain/detected_project.dart';
import '../domain/detected_session.dart';
import 'detected_project_merger.dart';

/// A pair of CLI store homes to scan for one environment.
class CliStore {
  const CliStore({
    required this.environmentId,
    this.claudeHome,
    this.codexHome,
  });
  final String environmentId;
  final String? claudeHome;
  final String? codexHome;
}

/// Resolves the on-disk CLI store homes for each environment. The Windows host
/// store lives under `%USERPROFILE%`; WSL stores are reached from Windows via
/// the `\\wsl.localhost\…` UNC form of the distribution's `$HOME`.
class CliStoreLocator {
  CliStoreLocator({
    required this.runnerFactory,
    this.translator = const PathTranslator(),
  });

  final CommandRunnerFactory runnerFactory;
  final PathTranslator translator;

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
          claudeHome: p.windows.join(userProfile, '.claude'),
          codexHome: p.windows.join(userProfile, '.codex'),
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
          CliStore(
            environmentId: env.id,
            claudeHome: p.windows.join(unc, '.claude'),
            codexHome: p.windows.join(unc, '.codex'),
          ),
        );
      }
    }
    return stores;
  }

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
    this.translator = const PathTranslator(),
  });

  final ClaudeStoreReader claudeReader;
  final CodexStoreReader codexReader;
  final PathTranslator translator;

  /// Reads every store and returns the flat list of detected sessions.
  Future<List<DetectedSession>> readStores(List<CliStore> stores) async {
    final all = <DetectedSession>[];
    for (final store in stores) {
      final claudeHome = store.claudeHome;
      final codexHome = store.codexHome;
      if (claudeHome != null) {
        all.addAll(await claudeReader.read(claudeHome, store.environmentId));
      }
      if (codexHome != null) {
        all.addAll(await codexReader.read(codexHome, store.environmentId));
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
