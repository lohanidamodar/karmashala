import '../../../core/database/sqlite_row_reader.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'detected_project_merger.dart';

/// Reads CLI stores and merges their sessions into projects.
///
/// Whose store is whose is the registry's business: each agent's adapter hands
/// out the reader for its own store (`AgentStore.sessionReader`), so a new
/// agent is read without a line here.
class CliDetectionService {
  CliDetectionService({
    this.translator = const PathTranslator(),
    this.registry = AgentRegistry.builtIn,
    Map<String, StoreSessionReader>? readers,
  }) : _readers = readers ?? {};

  final PathTranslator translator;
  final AgentRegistry registry;

  /// One reader per agent for this service's life, so the caches behind them —
  /// the whole reason a second scan costs what changed rather than the whole
  /// store — outlive a single scan. Created on first use; [readers] seeds it,
  /// for a test that needs to hold one.
  final Map<String, StoreSessionReader> _readers;

  /// The reader for [agentId]'s store, or null when its adapter declares none.
  StoreSessionReader? readerFor(String agentId) {
    final cached = _readers[agentId];
    if (cached != null) return cached;
    final store = registry.adapterFor(agentId)?.store;
    if (store == null) return null;
    // The app's SQLite binding, handed to the package's reader: it turns a
    // database-backed store from "not recorded" into step counts and titles.
    return _readers[agentId] = store.sessionReader(readRows: readSqliteRows);
  }

  /// The store reads [stores] needs, agent-major and in registry order: Claude's
  /// store is cheap and Codex's opens every candidate, so Claude answers first.
  List<StoreScanJob> jobsFor(List<CliStore> stores) => [
    for (final adapter in registry.adapters)
      if (adapter.store != null)
        for (final store in stores)
          if (store.homeFor(adapter.id) case final home?)
            StoreScanJob(
              agentId: adapter.id,
              storeHome: home,
              environmentId: store.environmentId,
              storeServer: store.storeServerFor(adapter.id),
            ),
  ];

  /// Runs one job. [workingDirectories] narrows a store whose layout is
  /// addressable from one to the directories they encode to — see
  /// [StoreSessionReader.read] — and [slots] is passed straight through; the
  /// job carries its own store server.
  Future<List<DetectedSession>> runJob(
    StoreScanJob job, {
    Set<String>? workingDirectories,
    StoreScanSlots? slots,
  }) async {
    final reader = readerFor(job.agentId);
    if (reader == null) return const [];
    return reader.read(
      job.storeHome,
      job.environmentId,
      directories: _directoriesFor(job.agentId, workingDirectories),
      slots: slots,
      storeServer: job.storeServer,
    );
  }

  /// Reads every store and returns the flat list; [onJob] sees each job as it
  /// finishes. No store server here: `CreateProcessW` costs ~1 s on this
  /// isolate.
  Future<List<DetectedSession>> readStores(
    List<CliStore> stores, {
    Set<String>? workingDirectories,
    int concurrency = kStoreScanConcurrency,
    void Function(StoreScanJob job, List<DetectedSession> sessions)? onJob,
  }) async {
    final all = <DetectedSession>[];
    for (final job in jobsFor(stores)) {
      final sessions = await runJob(
        job.withoutStoreServer(),
        workingDirectories: workingDirectories,
        slots: StoreScanSlots(concurrency: concurrency),
      );
      onJob?.call(job, sessions);
      all.addAll(sessions);
    }
    return all;
  }

  /// The store directories [workingDirectories] encode to in [agentId]'s
  /// store, or null — read everything — when there are none to narrow to or
  /// the store cannot be narrowed.
  Set<String>? _directoriesFor(
    String agentId,
    Set<String>? workingDirectories,
  ) {
    if (workingDirectories == null) return null;
    final store = registry.adapterFor(agentId)?.store;
    if (store == null) return null;
    final names = {
      for (final directory in workingDirectories)
        ?store.directoryNameFor(directory),
    };
    return names.isEmpty ? null : names;
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
    required this.storeHome,
    required this.environmentId,
    this.storeServer,
  });

  final String agentId;
  final String storeHome;
  final String environmentId;

  /// How to reach the agent's store server here, when it has one installed.
  final StoreServerLaunch? storeServer;

  StoreScanJob withoutStoreServer() => StoreScanJob(
    agentId: agentId,
    storeHome: storeHome,
    environmentId: environmentId,
  );
}
