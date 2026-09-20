import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import '../data/cli_session_mutator.dart';
import 'codex_app_server_providers.dart';
import '../data/conversation_index_dao.dart';
import 'package:agent_cli/read.dart';
import '../data/store_scan_worker.dart';
import '../data/imported_session_dao.dart';
import 'antigravity_attribution_service.dart';
import 'cli_detection_service.dart';
import 'conversation_index_backfill.dart';
import 'conversation_indexer.dart';
import 'detected_project_merger.dart';
import 'launched_session_attribution_service.dart';
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

final conversationIndexDaoProvider = Provider<ConversationIndexDao>(
  (ref) => ConversationIndexDao(ref.watch(databaseProvider)),
);

/// Keeps the conversation index in step with the transcripts on disk. Nothing
/// starts it: it is queued by adoption and rename, drained on the store slot.
final conversationIndexerProvider = Provider<ConversationIndexer>(
  (ref) => ConversationIndexer(
    dao: ref.watch(conversationIndexDaoProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// The one-off catch-up over the conversations the workspace already had.
final conversationIndexBackfillProvider = Provider<ConversationIndexBackfill>(
  (ref) => ConversationIndexBackfill(
    db: ref.watch(databaseProvider),
    dao: ref.watch(conversationIndexDaoProvider),
    indexer: ref.watch(conversationIndexerProvider),
    clock: ref.watch(clockProvider),
    locateTranscripts: () => ref.read(sessionTranscriptLocatorProvider).index(),
  ),
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

/// Where every CLI-store walk in the app happens: one long-lived worker
/// isolate, so nothing walks a 9p share on the isolate that draws.
final storeScanRunnerProvider = Provider<StoreScanRunner>(
  (ref) => sharedStoreScanRunner,
);

final sessionAutoImportServiceProvider = Provider<SessionAutoImportService>(
  (ref) => SessionAutoImportService(
    locator: ref.watch(cliStoreLocatorProvider),
    scan: ref.watch(storeScanRunnerProvider).scan,
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
/// Cycled by `SessionStatusRegistry` and poked by `/agent-hook`; starts nothing.
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
    onAdopted: (session) {
      ref
          .read(sessionsRevisionProvider.notifier)
          .changed(SessionChange.created(session.id));
      // A conversation entering the workspace is one of the two moments the
      // index is built on; queuing costs a map entry.
      final conversation = session.externalSessionId;
      if (conversation != null) {
        ref.read(conversationIndexerProvider).want(conversation);
      }
    },
  );
});

/// Writes the Antigravity conversation id onto the session row that is on it.
/// `agy` neither accepts an id nor writes one where a scan could match it.
final antigravityAttributionServiceProvider =
    Provider<AntigravitySessionAttributionService>((ref) {
      return AntigravitySessionAttributionService(
        sessionDao: ref.watch(sessionDaoProvider),
        installationDao: ref.watch(agentInstallationDaoProvider),
        repositoryDao: ref.watch(repositoryDaoProvider),
        agents: ref.watch(agentRegistryProvider),
        locateStores: () async => ref
            .read(cliStoreLocatorProvider)
            .locate(ref.read(executionEnvironmentDaoProvider).getAll()),
        // Not `adoptablePanes`' live-only rule: `agy` prints its resume hint
        // as it exits. `restored` is refused — that buffer is replayed history.
        readPaneTail: (paneId, lines) {
          final instance = ref
              .read(terminalSessionsControllerProvider.notifier)
              .instanceFor(paneId);
          if (instance == null) return const [];
          if (instance.liveness.value == PaneLiveness.restored) return const [];
          return terminalTailLines(instance.terminal, lines: lines);
        },
        onAttributed: (session, conversationId) {
          followSupersededHistory(ref, session.id, conversationId);
          // Which conversation this row is on — a placement. Its name did not
          // change, so nothing that only draws names is woken.
          ref
              .read(sessionsRevisionProvider.notifier)
              .changed(SessionChange.moved(session.id));
        },
      );
    });

/// Moves the selection off the read-only history a native row has just
/// superseded — the detail pane resolves by id and would go on showing it.
void followSupersededHistory(Ref ref, String sessionId, String conversationId) {
  final selected = ref.read(selectedImportedSessionIdProvider);
  if (selected == null) return;
  final record = ref.read(importedSessionDaoProvider).getById(selected);
  // Only the record this row just took over. Another conversation's history is
  // what the user asked to look at.
  if (record == null || record.externalId != conversationId) return;
  ref.read(selectedImportedSessionIdProvider.notifier).select(null);
  ref.read(selectedSessionIdProvider.notifier).select(sessionId);
}

/// Copies a CLI's own name for a conversation into the session row running it.
final sessionTitleSyncServiceProvider = Provider<SessionTitleSyncService>((
  ref,
) {
  return SessionTitleSyncService(
    sessionDao: ref.watch(sessionDaoProvider),
    agents: ref.watch(agentRegistryProvider),
    scanStores: () => ref.read(cliStoreScanPassProvider).read(),
    // This fires on a timer, so it says only what it knows: a narrow rename
    // bump, not a wake of every watcher of the revision counter.
    onRenamed: (sessionId, _) {
      ref
          .read(sessionsRevisionProvider.notifier)
          .changed(SessionChange.renamed(sessionId));
      ref
          .read(terminalSessionsControllerProvider.notifier)
          .notifyTitleChanged();
      // The other moment the index is built on: a CLI writing a name is the
      // app's evidence that the transcript moved. One row read, on a rename.
      final conversation = ref
          .read(sessionDaoProvider)
          .getById(sessionId)
          ?.externalSessionId;
      if (conversation != null) {
        ref.read(conversationIndexerProvider).want(conversation);
      }
    },
  );
});

/// Writes the CLI's conversation id onto a session we launched for an agent
/// that would not accept one — Codex today, launched with a null id.
final launchedSessionAttributionServiceProvider =
    Provider<LaunchedSessionAttributionService>((ref) {
      return LaunchedSessionAttributionService(
        sessionDao: ref.watch(sessionDaoProvider),
        installationDao: ref.watch(agentInstallationDaoProvider),
        repositoryDao: ref.watch(repositoryDaoProvider),
        environmentDao: ref.watch(executionEnvironmentDaoProvider),
        agents: ref.watch(agentRegistryProvider),
        scanStores: () => ref.read(cliStoreScanPassProvider).read(),
        // A row that just took over a conversation supersedes its history
        // everywhere except a selection already pointing at it.
        onAttributed: (session, conversationId) {
          followSupersededHistory(ref, session.id, conversationId);
          ref
              .read(sessionsRevisionProvider.notifier)
              .changed(SessionChange.moved(session.id));
        },
      );
    });

/// One store scan shared by the passengers on a single store slot: attribution
/// and the title sync ask the disk the same expensive question.
final cliStoreScanPassProvider = Provider<CliStoreScanPass>(
  (ref) => CliStoreScanPass(() => scanCliStores(ref)),
);

/// A store scan that is read once per pass. See [cliStoreScanPassProvider].
class CliStoreScanPass {
  CliStoreScanPass(this._scan);

  final Future<List<DetectedSession>> Function() _scan;

  /// The scan this pass started, held as the *future* so a second caller that
  /// arrives before the first finishes still waits on the one read.
  Future<List<DetectedSession>>? _inFlight;

  Future<List<DetectedSession>> read() => _inFlight ??= _scan();

  /// Ends the pass, so the next slot reads the disk again.
  void end() => _inFlight = null;
}

/// Reconciles session rows against what the CLI stores now say. The order is
/// load-bearing: attribution learns an id, the title sync can only match one.
final cliStoreSyncRunnerProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    // Antigravity's attribution needs no store scan — one JSON file per store
    // and the pane's own screen — so it runs outside the pass.
    await ref.read(antigravityAttributionServiceProvider).attribute();
    final pass = ref.read(cliStoreScanPassProvider);
    try {
      await ref.read(launchedSessionAttributionServiceProvider).attribute();
      await ref.read(sessionTitleSyncServiceProvider).sync();
      // Only for what the two above queued; `drain` returns before touching
      // anything when nothing is wanted, and reads the pass when it is.
      await ref.read(conversationIndexerProvider).drain(pass.read);
    } finally {
      // Whatever happened, the next slot must see the disk as it is then.
      pass.end();
    }
  };
});

/// Every tracked pane, in the shape adoption reads them — read-only over the
/// terminal layout's published state.
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
          // drawn, so without this an exited CLI looks like one at its prompt.
          lastCommandRunning:
              instance.commandBlocks?.tracker.latest?.isRunning ?? true,
        ),
  ];
}

/// [adoptablePanes] for a reader that holds a container rather than a `Ref` —
/// a hook callback. Callable, not cached: the pane list changes every frame.
final adoptablePanesProvider = Provider<List<AdoptablePane> Function()>(
  (ref) =>
      () => adoptablePanes(ref),
);

/// One pass over every CLI store, flattened to the sessions it found. Walks on
/// the worker isolate, and unnarrowed: callers have no path to narrow by.
Future<List<DetectedSession>> scanCliStores(Ref ref) async {
  final environments = ref.read(executionEnvironmentDaoProvider).getAll();
  final stores = await ref.read(cliStoreLocatorProvider).locate(environments);
  final sessions = <DetectedSession>[];
  await for (final chunk
      in ref
          .read(storeScanRunnerProvider)
          .scan(StoreScanRequest(stores: stores))) {
    sessions.addAll(chunk.sessions);
  }
  return sessions;
}

final cliStoreLocatorProvider = Provider<CliStoreLocator>(
  (ref) => CliStoreLocator(
    runnerFor: ref.watch(runnerResolverProvider),
    registry: ref.watch(agentRegistryProvider),
    // So a located Codex store carries how to reach its app-server. Watching
    // the controller, not the DAO, keeps a later Codex from being missed.
    installations: ref.watch(agentInstallationsControllerProvider),
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

/// The one place "does this conversation exist" is answered. Failure and every
/// other environment's store say `unknown`: a wrongly refused resume is worse.
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
  (ref) => CliSessionMutator(),
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

  /// Reads every store, unnarrowed: this door's job is to find projects the
  /// workspace has never heard of, so it must not narrow to what it has.
  Future<List<DetectedProject>> _load() async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    final sessions = await scanCliStores(ref);
    // Deliberately no freshness stamp: this listed the stores and imported
    // nothing, and the stamp means "brought up to date", not "somebody looked".
    return mergeDetectedProjects(sessions, {
      for (final e in environments) e.id: e,
    });
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
    await ref
        .read(cliSessionMutatorProvider)
        .rename(session, newTitle, codex: ref.read(codexAppServersProvider));
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
