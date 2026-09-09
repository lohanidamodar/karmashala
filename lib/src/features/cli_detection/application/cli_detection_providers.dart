import 'package:riverpod/riverpod.dart';

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
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../data/cli_session_mutator.dart';
import 'codex_app_server_providers.dart';
import '../data/conversation_index_dao.dart';
import '../data/conversation_store_index.dart';
import '../data/store_scan_worker.dart';
import '../data/imported_session_dao.dart';
import '../domain/conversation_presence.dart';
import '../domain/detected_project.dart';
import '../domain/detected_session.dart';
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

/// Keeps the conversation index in step with the transcripts on disk.
///
/// Nothing starts it. It is queued by the two triggers the app already fires —
/// `SessionAdoptionService` adopting a session and `SessionTitleSyncService`
/// renaming one — and drained by [cliStoreSyncRunnerProvider] on the store slot
/// that is already open. See the service's own doc for why there is no timer.
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
    locateTranscripts: () =>
        ref.read(sessionTranscriptLocatorProvider).index(),
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

/// Where every CLI-store walk in the app happens.
///
/// One long-lived worker isolate, shared by auto-import, "Detect CLI sessions"
/// and the status registry's store slot, so no two of them can be walking the
/// same 9p share on the isolate that draws. A test overrides this with an
/// inline runner (or a canned one) and never spawns anything.
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
    onAdopted: (session) {
      // A row appearing in the tree is exactly what the revision counter is
      // for.
      ref
          .read(sessionsRevisionProvider.notifier)
          .changed(SessionChange.created(session.id));
      // And a conversation entering the workspace is the first of the two
      // moments the index is built on. Queuing costs a map entry; the store
      // slot this adoption is running on drains it a line later.
      final conversation = session.externalSessionId;
      if (conversation != null) {
        ref.read(conversationIndexerProvider).want(conversation);
      }
    },
  );
});

/// Writes the Antigravity conversation id onto the session row that is on it.
///
/// `agy` neither accepts an id nor writes one anywhere a scan could match, so
/// without this an app-launched Antigravity session is a phantom: a row nothing
/// can resume, rename from the store, or find again.
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
        // **Deliberately not `adoptablePanes`' live-only rule.** `agy` prints
        // its resume hint as it *exits*, so the pane holding the strongest
        // signal is a dead one. A `restored` pane is still refused: its buffer
        // is the previous run's replayed history, and an id read out of that
        // describes a conversation from before the restart.
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
/// superseded, and onto the row itself.
///
/// A row learning its conversation id hides the imported record for that
/// conversation from every list (`ImportedSessionDao`) — but not from the
/// detail pane, which resolves a selection by id and would go on showing the
/// transcript. That is the state the owner's inbox notification left them in:
/// reading history for a session running in a pane behind it, with nothing on
/// screen saying so. Both records name the same repository, so the project and
/// repository selections are already right and only the leaf moves.
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
///
/// The rename the owner reported: `/rename` typed into `agy`, "New session"
/// still in the sidebar. Nothing in the app read a title *back* out of a CLI
/// store for any agent — see the service's own doc.
final sessionTitleSyncServiceProvider = Provider<SessionTitleSyncService>((ref) {
  return SessionTitleSyncService(
    sessionDao: ref.watch(sessionDaoProvider),
    agents: ref.watch(agentRegistryProvider),
    scanStores: () => ref.read(cliStoreScanPassProvider).read(),
    // **The bump that fires on a timer.** The store sweep runs whether or not
    // the user is doing anything, so this one narrow fact used to wake all
    // twenty-eight watchers of the revision counter — several of them with a
    // full `SELECT * FROM sessions` on the UI isolate. It says only what it
    // knows: this row is called something else now.
    onRenamed: (sessionId, _) {
      ref
          .read(sessionsRevisionProvider.notifier)
          .changed(SessionChange.renamed(sessionId));
      ref
          .read(terminalSessionsControllerProvider.notifier)
          .notifyTitleChanged();
      // The second moment the index is built on: the CLI wrote a name into its
      // own store, which is the app's existing evidence that the conversation's
      // transcript has moved. One row read, on a rename, which is rare — the
      // sync only reaches here for a row it actually changed.
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
/// that would not accept one.
///
/// Codex is that agent today: `SessionLauncher` records a null id and, in its
/// own words, the row "keep[s] a null id until something discovers it". Nothing
/// did — the store scan that could belongs to `SessionAdoptionService`, which
/// only ever looks at panes the app did *not* launch. See the service's own doc
/// for the three symptoms one missing id produced.
final launchedSessionAttributionServiceProvider =
    Provider<LaunchedSessionAttributionService>((ref) {
      return LaunchedSessionAttributionService(
        sessionDao: ref.watch(sessionDaoProvider),
        installationDao: ref.watch(agentInstallationDaoProvider),
        repositoryDao: ref.watch(repositoryDaoProvider),
        environmentDao: ref.watch(executionEnvironmentDaoProvider),
        agents: ref.watch(agentRegistryProvider),
        scanStores: () => ref.read(cliStoreScanPassProvider).read(),
        // A row that has just learned which conversation it is on changes what
        // the strip, the tree and the inbox each say about it.
        // Same tidy-up as the launched attributor's: a row that has just taken
        // over a conversation supersedes its history everywhere except a
        // selection already pointing at it.
        onAttributed: (session, conversationId) {
          followSupersededHistory(ref, session.id, conversationId);
          ref
              .read(sessionsRevisionProvider.notifier)
              .changed(SessionChange.moved(session.id));
        },
      );
    });

/// One store scan, shared by the passengers on a single store slot.
///
/// Attribution and the title sync ask the disk the same question —
/// [scanCliStores] lists and parses every session file in every store, which on
/// the owner's machine is a hundred-odd files over `\\wsl.localhost` — and on
/// the slot where a session learns its conversation, *both* want the answer.
/// Reading it twice for one slot would be pure waste, so the pass is opened and
/// closed around them by [cliStoreSyncRunnerProvider] and nothing outside that
/// holds it.
final cliStoreScanPassProvider = Provider<CliStoreScanPass>(
  (ref) => CliStoreScanPass(() => scanCliStores(ref)),
);

/// A store scan that is read once per pass. See [cliStoreScanPassProvider].
class CliStoreScanPass {
  CliStoreScanPass(this._scan);

  final Future<List<DetectedSession>> Function() _scan;

  /// The scan this pass has already started, if any. Held as the *future*, so
  /// two readers in one pass share the work rather than the result of it — a
  /// second caller that arrives before the first has finished still waits on
  /// the one read.
  Future<List<DetectedSession>>? _inFlight;

  Future<List<DetectedSession>> read() => _inFlight ??= _scan();

  /// Ends the pass, so the next slot reads the disk again.
  void end() => _inFlight = null;
}

/// Reconciles session rows against what the CLI stores now say.
///
/// Exposed as a function provider, like [autoImportRunnerProvider], so the
/// status registry's store slot has one line to run and a test can drive the
/// whole chain through the real providers. The order is stated here rather than
/// assumed at the call site: attribution learns a conversation id, and the title
/// sync can only match a row that has one.
final cliStoreSyncRunnerProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    // Attribution first: it is what gives a row the CLI id the title sync has
    // to match on, so a session learning its conversation this slot is renamed
    // in the same one rather than the next.
    //
    // Antigravity's needs no store scan — it reads one JSON file per store and
    // the pane's own screen — so it runs outside the pass.
    await ref.read(antigravityAttributionServiceProvider).attribute();
    final pass = ref.read(cliStoreScanPassProvider);
    try {
      await ref.read(launchedSessionAttributionServiceProvider).attribute();
      await ref.read(sessionTitleSyncServiceProvider).sync();
      // Last, and only for what the two above have queued. `drain` returns
      // before touching anything when nothing is wanted, so an idle slot pays
      // nothing — and when something is wanted it reads the pass rather than
      // opening a second walk.
      await ref.read(conversationIndexerProvider).drain(pass.read);
    } finally {
      // Whatever happened, the next slot must see the disk as it is then.
      pass.end();
    }
  };
});

/// Every tracked pane, in the shape adoption reads them.
///
/// Read-only over the terminal layout's own published state: adoption never
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
///
/// Reads through [storeScanRunnerProvider], so the status registry's slow slot
/// walks the stores on the worker isolate like everything else. Unnarrowed:
/// attribution and the title sync are looking for rows they have no path for.
Future<List<DetectedSession>> scanCliStores(Ref ref) async {
  final environments = ref.read(executionEnvironmentDaoProvider).getAll();
  final stores = await ref.read(cliStoreLocatorProvider).locate(environments);
  final sessions = <DetectedSession>[];
  await for (final chunk
      in ref.read(storeScanRunnerProvider).scan(
        StoreScanRequest(stores: stores),
      )) {
    sessions.addAll(chunk.sessions);
  }
  return sessions;
}

final cliStoreLocatorProvider = Provider<CliStoreLocator>(
  (ref) => CliStoreLocator(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    registry: ref.watch(agentRegistryProvider),
    // So a located Codex store carries how to reach its app-server: the two
    // DAO reads happen here, on the isolate that has a database, and cross to
    // the scan worker as plain data.
    installations: ref.watch(agentInstallationDaoProvider),
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

  /// Reads every store, unnarrowed and on the worker isolate: this door's whole
  /// job is to find projects the workspace has never heard of, so it is the one
  /// caller that must not narrow to the repositories it already has.
  Future<List<DetectedProject>> _load() async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    final sessions = await scanCliStores(ref);
    // Deliberately no freshness stamp. This listed the stores; it imported
    // nothing, and the stamp means "your session list was brought up to date",
    // not "somebody looked". Claiming otherwise is the §19 lie.
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
        .rename(
          session,
          newTitle,
          codex: ref.read(codexAppServersProvider),
        );
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
