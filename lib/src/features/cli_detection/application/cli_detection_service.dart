

import '../../../core/database/sqlite_row_reader.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'detected_project_merger.dart';

/// Reads CLI stores and merges their sessions into projects.
class CliDetectionService {
  CliDetectionService({
    ClaudeStoreReader? claudeReader,
    CodexStoreReader? codexReader,
    CodexAppServerReader? codexAppServerReader,
    this.antigravityReader = const AntigravityStoreSessions(
      // The app's SQLite binding, handed to the package's reader: it turns
      // Antigravity's store from "not recorded" into step counts and titles.
      reader: AntigravityStoreReader(
        countSteps: false,
        readRows: readSqliteRows,
      ),
    ),
    this.translator = const PathTranslator(),
    this.registry = AgentRegistry.builtIn,
    // Not const any more: both store readers carry the cache that keeps a scan
    // proportional to what changed rather than to the whole store.
  }) : claudeReader = claudeReader ?? ClaudeStoreReader(),
       codexReader = codexReader ?? CodexStoreReader() {
    this.codexAppServerReader =
        codexAppServerReader ?? CodexAppServerReader(fallback: this.codexReader);
  }

  final ClaudeStoreReader claudeReader;

  /// The rollout walk. Still reachable, and still the answer for a Codex whose
  /// app-server cannot be spawned or will not answer.
  final CodexStoreReader codexReader;

  /// What actually answers for `codexRollout`: `thread/list` when it can, the
  /// walk above when it cannot.
  late final CodexAppServerReader codexAppServerReader;

  final AntigravityStoreSessions antigravityReader;
  final PathTranslator translator;
  final AgentRegistry registry;

  /// Which reader answers for which on-disk layout. A lookup, not a branch: a
  /// new agent is a descriptor, and only a genuinely new layout is a reader.
  Map<AgentStoreFormat, StoreSessionReader> get _readersByFormat => {
    AgentStoreFormat.claudeJsonl: claudeReader,
    AgentStoreFormat.codexRollout: codexAppServerReader,
    AgentStoreFormat.antigravityStore: antigravityReader,
  };

  /// The store reads [stores] needs, agent-major and in registry order: Claude's
  /// store is cheap and Codex's opens every candidate, so Claude answers first.
  List<StoreScanJob> jobsFor(List<CliStore> stores) => [
    for (final descriptor in registry.descriptors)
      for (final store in stores)
        if (store.homesByAgentId[descriptor.id] case final home?)
          if (descriptor.store!.format != AgentStoreFormat.none)
            StoreScanJob(
              agentId: descriptor.id,
              format: descriptor.store!.format,
              storeHome: home,
              environmentId: store.environmentId,
            ),
  ];

  /// Runs one job. [directories], [slots] and [appServer] are passed straight
  /// through — see [StoreSessionReader.read].
  Future<List<DetectedSession>> runJob(
    StoreScanJob job, {
    Set<String>? directories,
    StoreScanSlots? slots,
    CodexAppServerLaunch? appServer,
  }) async {
    final reader = _readersByFormat[job.format];
    if (reader == null) return const [];
    return reader.read(
      job.storeHome,
      job.environmentId,
      directories: directories,
      slots: slots,
      appServer: appServer,
    );
  }

  /// The app-server launches in [stores], by environment id.
  static Map<String, CodexAppServerLaunch> codexAppServersIn(
    List<CliStore> stores,
  ) => {
    for (final store in stores)
      store.environmentId: ?store.codexAppServer,
  };

  /// Reads every store and returns the flat list; [onJob] sees each job as it
  /// finishes. No app-server here: `CreateProcessW` costs ~1 s on this isolate.
  Future<List<DetectedSession>> readStores(
    List<CliStore> stores, {
    Set<String>? claudeDirectories,
    int concurrency = kStoreScanConcurrency,
    void Function(StoreScanJob job, List<DetectedSession> sessions)? onJob,
  }) async {
    final all = <DetectedSession>[];
    for (final job in jobsFor(stores)) {
      final sessions = await runJob(
        job,
        directories: job.format == AgentStoreFormat.claudeJsonl
            ? claudeDirectories
            : null,
        slots: StoreScanSlots(concurrency: concurrency),
      );
      onJob?.call(job, sessions);
      all.addAll(sessions);
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

/// One CLI's store in one environment: the unit the scan queue processes.
/// Plain data, because it crosses to the worker isolate.
class StoreScanJob {
  const StoreScanJob({
    required this.agentId,
    required this.format,
    required this.storeHome,
    required this.environmentId,
  });

  final String agentId;
  final AgentStoreFormat format;
  final String storeHome;
  final String environmentId;
}
