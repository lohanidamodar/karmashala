import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../environments/application/environment_providers.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../data/cli_session_mutator.dart';
import '../data/conversation_store_index.dart';
import '../data/imported_session_dao.dart';
import '../domain/conversation_presence.dart';
import '../domain/detected_project.dart';
import '../domain/detected_session.dart';
import 'cli_detection_service.dart';
import 'project_import_service.dart';
import 'session_adoption_service.dart';
import 'session_auto_import_service.dart';
import 'session_title_sync_service.dart';

final cliDetectionServiceProvider = Provider<CliDetectionService>(
  (ref) => CliDetectionService(registry: ref.watch(agentRegistryProvider)),
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
    sessionDao: ref.watch(sessionDaoProvider),
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

/// Adopts agent sessions the user started by hand in one of our own panes.
///
/// Cycled by `SessionStatusRegistry` (see `sessionStatusRegistryProvider`) and
/// poked by `/agent-hook`; it starts nothing itself.
final sessionAdoptionServiceProvider = Provider<SessionAdoptionService>((ref) {
  return SessionAdoptionService(
    sessionDao: ref.watch(sessionDaoProvider),
    importedSessionDao: ref.watch(importedSessionDaoProvider),
    repositoryDao: ref.watch(repositoryDaoProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
    installationDao: ref.watch(agentInstallationDaoProvider),
    linkDao: ref.watch(sessionRepositoryDaoProvider),
    agents: ref.watch(agentRegistryProvider),
    ids: ref.watch(idGeneratorProvider),
    clock: ref.watch(clockProvider),
    readPanes: () => adoptablePanes(ref),
    readPaneTail: (paneId, lines) {
      final instance = ref
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId);
      if (instance == null || !instance.liveness.value.isLive) return const [];
      return terminalTailLines(instance.terminal, lines: lines);
    },
    scanStores: () => scanCliStores(ref),
    // A row appearing in the tree is exactly what the revision counter is for.
    onAdopted: (_) => ref.read(sessionsRevisionProvider.notifier).bump(),
  );
});

/// Copies a CLI's own name for a conversation into the session row running it.
///
/// The rename the owner reported: `/rename` typed into `agy`, "New session"
/// still in the sidebar. Nothing in the app read a title *back* out of a CLI
/// store for any agent — see the service's own doc.
final sessionTitleSyncServiceProvider = Provider<SessionTitleSyncService>((ref) {
  return SessionTitleSyncService(
    sessionDao: ref.watch(sessionDaoProvider),
    agents: ref.watch(agentRegistryProvider),
    scanStores: () => scanCliStores(ref),
    // A row changing its name in the tree is what the revision counter is for.
    onRenamed: (_, _) => ref.read(sessionsRevisionProvider.notifier).bump(),
  );
});

/// Reconciles session rows against what the CLI stores now say.
///
/// Exposed as a function provider, like [autoImportRunnerProvider], so the
/// status registry's store slot has one line to run and a test can drive the
/// whole chain through the real providers. The order is stated here rather than
/// assumed at the call site: attribution learns a conversation id, and the title
/// sync can only match a row that has one.
final cliStoreSyncRunnerProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    await ref.read(sessionTitleSyncServiceProvider).sync();
  };
});

/// Every tracked pane, in the shape adoption reads them.
///
/// Read-only over the terminal workspace's own published state: adoption never
/// holds a pane, opens one or changes one.
List<AdoptablePane> adoptablePanes(Ref ref) {
  final controller = ref.read(terminalSessionsControllerProvider.notifier);
  final state = ref.read(terminalSessionsControllerProvider);
  return [
    for (final paneId in state.liveness.keys)
      if (controller.instanceFor(paneId) case final instance?)
        AdoptablePane(
          paneId: paneId,
          workingDirectory: instance.workingDirectory,
          isLive: instance.liveness.value.isLive,
          // A pane the app opened to run an agent already has a session row;
          // adopting it would be inventing a second one for the same process.
          hostsLaunchedSession: instance.agentLaunch != null,
          lastCommandId: instance.commandBlocks?.tracker.latest?.id,
          lastCommandLine: instance.commandBlocks?.tracker.latest?.command,
          // `latest` keeps reporting a finished block until the next prompt is
          // drawn, so without this a CLI that has already exited still looks
          // like one sitting at its prompt.
          lastCommandRunning:
              instance.commandBlocks?.tracker.latest?.isRunning ?? true,
        ),
  ];
}

/// One pass over every CLI store, flattened to the sessions it found.
Future<List<DetectedSession>> scanCliStores(Ref ref) async {
  final environments = ref.read(executionEnvironmentDaoProvider).getAll();
  final stores = await ref.read(cliStoreLocatorProvider).locate(environments);
  final byId = {for (final e in environments) e.id: e};
  final projects = await ref.read(cliDetectionServiceProvider).detect(
    stores,
    byId,
  );
  return [
    for (final project in projects) ...[
      ...project.sessions,
      ...project.subagentSessions,
    ],
  ];
}

final cliStoreLocatorProvider = Provider<CliStoreLocator>(
  (ref) => CliStoreLocator(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    registry: ref.watch(agentRegistryProvider),
  ),
);

final conversationStoreIndexProvider = Provider<ConversationStoreIndex>(
  (ref) => const ConversationStoreIndex(),
);

/// Asks an agent's own store whether it has ever held a conversation.
typedef ConversationPresenceProbe =
    Future<ConversationPresence> Function({
      required AgentDescriptor descriptor,
      required String environmentId,
      required String conversationId,
    });

/// The one place "does this conversation exist" is answered.
///
/// A seam, like `sessionDirectoryPresentProvider`: production reads the store,
/// tests substitute an answer. And like that one, **the safe answer is the
/// permissive one** — every failure below resolves to
/// [ConversationPresence.unknown], because a resume refused on a store we could
/// not read is a worse bug than the one this exists to catch.
///
/// [environmentId] is where the session runs, and only *that* environment's
/// store may say [ConversationPresence.absent]: it is the one the agent would
/// have written to. The other located stores are still asked, because finding
/// the conversation anywhere at all is proof it exists, and a user who moved a
/// repository between WSL and Windows should not have their history called
/// missing.
final conversationPresenceProvider = Provider<ConversationPresenceProbe>((ref) {
  return ({
    required AgentDescriptor descriptor,
    required String environmentId,
    required String conversationId,
  }) async {
    final spec = descriptor.store;
    if (spec == null || spec.format == AgentStoreFormat.none) {
      return ConversationPresence.unknown;
    }
    try {
      final environments = ref.read(executionEnvironmentDaoProvider).getAll();
      final stores = await ref
          .read(cliStoreLocatorProvider)
          .locate(environments);
      final index = ref.read(conversationStoreIndexProvider);
      var here = ConversationPresence.unknown;
      for (final store in stores) {
        final home = store.homesByAgentId[descriptor.id];
        if (home == null) continue;
        final answer = await index.presenceOf(
          storeHome: home,
          format: spec.format,
          conversationId: conversationId,
        );
        if (answer == ConversationPresence.present) return answer;
        if (store.environmentId == environmentId) here = answer;
      }
      return here;
    } on Object {
      return ConversationPresence.unknown;
    }
  };
});

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
