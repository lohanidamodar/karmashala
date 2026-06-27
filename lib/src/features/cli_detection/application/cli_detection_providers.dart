import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../data/cli_session_mutator.dart';
import '../data/imported_session_dao.dart';
import '../domain/detected_project.dart';
import '../domain/detected_session.dart';
import 'cli_detection_service.dart';
import 'project_import_service.dart';
import 'session_auto_import_service.dart';

final cliDetectionServiceProvider = Provider<CliDetectionService>(
  (ref) => const CliDetectionService(),
);

final importedSessionDaoProvider = Provider<ImportedSessionDao>(
  (ref) => ImportedSessionDao(ref.watch(databaseProvider)),
);

final projectImportServiceProvider = Provider<ProjectImportService>(
  (ref) => ProjectImportService(
    projectDao: ref.watch(projectDaoProvider),
    repositoryDao: ref.watch(repositoryDaoProvider),
    importedSessionDao: ref.watch(importedSessionDaoProvider),
    ids: ref.watch(idGeneratorProvider),
    clock: ref.watch(clockProvider),
  ),
);

final sessionAutoImportServiceProvider = Provider<SessionAutoImportService>(
  (ref) => SessionAutoImportService(
    locator: ref.watch(cliStoreLocatorProvider),
    detectionService: ref.watch(cliDetectionServiceProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
    importedSessionDao: ref.watch(importedSessionDaoProvider),
    ids: ref.watch(idGeneratorProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// Runs auto-import for a project's repositories. Exposed as a function provider
/// so callers (and tests) can substitute it without touching the filesystem.
typedef AutoImportRunner =
    Future<ImportSummary> Function(List<Repository> repos);

final autoImportRunnerProvider = Provider<AutoImportRunner>(
  (ref) => ref.read(sessionAutoImportServiceProvider).importForRepositories,
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

  /// Imports every detected project/session into the workspace, ignoring
  /// duplicates. Returns what was added.
  ImportSummary importAll() {
    final projects = state.asData?.value ?? const [];
    final summary = ref.read(projectImportServiceProvider).importAll(projects);
    // Refresh the workspace project list so imports appear immediately.
    ref.invalidate(projectsControllerProvider);
    return summary;
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
