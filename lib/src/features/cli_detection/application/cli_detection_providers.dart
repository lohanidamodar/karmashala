import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../data/cli_session_mutator.dart';
import '../domain/detected_project.dart';
import '../domain/detected_session.dart';
import 'cli_detection_service.dart';

final cliDetectionServiceProvider = Provider<CliDetectionService>(
  (ref) => const CliDetectionService(),
);

final cliStoreLocatorProvider = Provider<CliStoreLocator>(
  (ref) =>
      CliStoreLocator(runnerFactory: ref.watch(commandRunnerFactoryProvider)),
);

final cliSessionMutatorProvider = Provider<CliSessionMutator>(
  (ref) => const CliSessionMutator(),
);

/// Detects projects/sessions from the Claude Code and Codex CLI stores, merges
/// them, and supports rename/delete. Runs on demand (it scans the filesystem).
class DetectedProjectsController extends AsyncNotifier<List<DetectedProject>> {
  @override
  Future<List<DetectedProject>> build() async => const [];

  /// Scans the CLI stores and rebuilds the detected-project list.
  Future<void> detect() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  Future<List<DetectedProject>> _load() async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    final stores = await ref.read(cliStoreLocatorProvider).locate(environments);
    final byId = {for (final e in environments) e.id: e};
    return ref.read(cliDetectionServiceProvider).detect(stores, byId);
  }

  Future<void> renameSession(DetectedSession session, String newTitle) async {
    await ref.read(cliSessionMutatorProvider).rename(session, newTitle);
    await detect();
  }

  Future<void> deleteSession(DetectedSession session) async {
    await ref.read(cliSessionMutatorProvider).delete(session);
    await detect();
  }
}

final detectedProjectsControllerProvider =
    AsyncNotifierProvider<DetectedProjectsController, List<DetectedProject>>(
      DetectedProjectsController.new,
    );
