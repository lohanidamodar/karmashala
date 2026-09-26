import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import '../../workspaces/data/workspace_data.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import '../data/cli_session_mutator.dart';
import 'agent_store_server_providers.dart';
import 'package:agent_cli/read.dart';
import '../data/store_scan_worker.dart';
import 'cli_detection_service.dart';
import 'detected_project_merger.dart';
import 'pane_facts_reporter.dart';
import 'project_import_service.dart';
import 'session_auto_import_service.dart';

final cliDetectionServiceProvider = Provider<CliDetectionService>(
  (ref) => CliDetectionService(registry: ref.watch(agentRegistryProvider)),
);

final projectImportServiceProvider = Provider<ProjectImportService>(
  (ref) => ProjectImportService(
    workspace: ref.watch(workspaceDataProvider),
    importedSessionDao: ref.watch(importedSessionsProvider),
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
    environmentDao: ref.watch(environmentsDataProvider),
    importedSessionDao: ref.watch(importedSessionsProvider),
    sessionDao: ref.watch(sessionsDataProvider),
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

/// Tells the server this app's terminal panes as facts, over the host link:
/// the server adopts what a person started by hand in one, and reads the
/// resume line an agent printed there. Reported on each status cycle.
final paneFactsReporterProvider = Provider<PaneFactsReporter>(
  (ref) => PaneFactsReporter(
    readPanes: () => adoptablePanes(ref),
    // Not the live-only rule of arming: an agent may print its resume hint
    // as it exits. `restored` is refused — that buffer is replayed history.
    readTail: (paneId, lines) {
      if (!ref.exists(terminalSessionsControllerProvider)) return null;
      final instance = ref
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId);
      if (instance == null) return null;
      if (instance.liveness.value == PaneLiveness.restored) return null;
      return terminalTailLines(instance.terminal, lines: lines);
    },
  ),
);

/// Every tracked pane, as facts — read-only over the terminal layout's
/// published state.
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
/// a hook callback (the launched-session rebind). Callable, not cached: the pane list changes every frame.
final adoptablePanesProvider = Provider<List<AdoptablePane> Function()>(
  (ref) =>
      () => adoptablePanes(ref),
);

/// One pass over every CLI store, flattened to the sessions it found. Walks on
/// the worker isolate, and unnarrowed: callers have no path to narrow by.
Future<List<DetectedSession>> scanCliStores(Ref ref) async {
  final environments = ref.read(environmentsDataProvider).getAll();
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
    final store = ref
        .read(agentRegistryProvider)
        .adapterFor(descriptor.id)
        ?.store;
    if (descriptor.store == null || store == null) {
      return ConversationPresence.unknown;
    }
    try {
      final environments = ref.read(environmentsDataProvider).getAll();
      final stores = await ref
          .read(cliStoreLocatorProvider)
          .locate(environments);
      final index = ref.read(conversationStoreIndexProvider);
      var here = ConversationPresence.unknown;
      for (final cliStore in stores) {
        final home = cliStore.homeFor(descriptor.id);
        if (home == null) continue;
        final answer = await index.presenceOf(
          storeHome: home,
          store: store,
          conversationId: conversationId,
        );
        if (answer == ConversationPresence.present) return answer;
        if (cliStore.environmentId == environmentId) here = answer;
      }
      return here;
    } on Object {
      return ConversationPresence.unknown;
    }
  };
});

final cliSessionMutatorProvider = Provider<CliSessionMutator>(
  (ref) => CliSessionMutator(registry: ref.watch(agentRegistryProvider)),
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
    final environments = ref.read(environmentsDataProvider).getAll();
    final sessions = await scanCliStores(ref);
    // Deliberately no freshness stamp: this listed the stores and imported
    // nothing, and the stamp means "brought up to date", not "somebody looked".
    return mergeDetectedProjects(sessions, {
      for (final e in environments) e.id: e,
    });
  }

  /// Imports every detected project/session into the workspace, ignoring
  /// duplicates. Returns what was added.
  Future<ImportSummary> importAll() => ref
      .read(projectImportServiceProvider)
      .importAll(state.asData?.value ?? const []);

  Future<void> renameSession(DetectedSession session, String newTitle) async {
    await ref
        .read(cliSessionMutatorProvider)
        .rename(
          session,
          newTitle,
          servers: ref.read(agentStoreServersProvider),
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
