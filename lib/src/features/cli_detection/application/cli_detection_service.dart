import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/path_translator.dart';
import '../../agents/data/agent_installation_dao.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_ids.dart';
import '../../agents/domain/agent_registry.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../data/antigravity_store_sessions.dart';
import '../data/claude_store_reader.dart';
import '../data/codex_app_server_launch.dart';
import '../data/codex_app_server_reader.dart';
import '../data/codex_store_reader.dart';
import '../data/store_scan_slots.dart';
import '../data/store_session_reader.dart';
import '../domain/detected_project.dart';
import '../domain/detected_session.dart';
import 'detected_project_merger.dart';

/// The CLI store homes to scan for one environment, keyed by agent registry id.
class CliStore {
  const CliStore({
    required this.environmentId,
    required this.homesByAgentId,
    this.codexAppServer,
  });

  final String environmentId;

  /// How to reach this environment's `codex app-server`, when a Codex is
  /// installed there. Plain data, because it crosses to the worker isolate
  /// where the spawn has to happen — see [CodexAppServerLaunch].
  final CodexAppServerLaunch? codexAppServer;

  /// `AgentDescriptor.id` → the agent's store home in this environment, in a
  /// form the app can read directly (Windows-native or a `\\wsl.localhost\…`
  /// UNC path).
  final Map<String, String> homesByAgentId;

  String? get claudeHome => homesByAgentId['claudeCode'];
  String? get codexHome => homesByAgentId['codex'];
  String? get antigravityHome => homesByAgentId['antigravity'];
}

/// Resolves the on-disk CLI store homes for each environment. Which stores
/// exist comes from the agent registry; the local host's store lives under the
/// user's home directory, and WSL stores are reached from Windows via the
/// `\\wsl.localhost\…` UNC form of the distribution's `$HOME`.
class CliStoreLocator {
  CliStoreLocator({
    required this.runnerFactory,
    this.translator = const PathTranslator(),
    this.registry = AgentRegistry.builtIn,
    this.installations,
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final CommandRunnerFactory runnerFactory;
  final PathTranslator translator;
  final AgentRegistry registry;

  /// Where each environment's Codex executable is, so a store can be read
  /// through `thread/list` rather than by walking its rollouts. Omit it and
  /// every Codex store is walked, which is what it did before.
  final AgentInstallationDao? installations;

  /// The process environment the home directory is read from. Injected so the
  /// per-platform lookup is testable off the platform it describes.
  final Map<String, String> environment;

  Future<List<CliStore>> locate(List<ExecutionEnvironment> environments) async {
    // The machine this app is running on, whichever OS that is. Matching only
    // `windowsNative` here is what made session detection come up empty on a
    // Mac: the host is `localPosix`, so no store was located, and with no store
    // there are no sessions, no projects and no chat to adopt.
    ExecutionEnvironment? local;
    // The WSL translation below needs a genuinely Windows environment, which is
    // a different question and only ever has one answer on Windows.
    ExecutionEnvironment? windows;
    for (final env in environments) {
      if (local == null && isLocalHost(env.kind)) local = env;
      if (windows == null && env.kind == EnvironmentKind.windowsNative) {
        windows = env;
      }
    }

    final stores = <CliStore>[];
    final home = local == null ? null : _localHomeDirectory(local.kind);
    if (local != null && home != null) {
      stores.add(
        CliStore(
          environmentId: local.id,
          homesByAgentId: _homesUnder(
            home,
            usesWindowsPaths(local.kind) ? p.windows : p.posix,
          ),
          codexAppServer: _codexAppServer(local),
        ),
      );
    }

    if (windows != null) {
      for (final env in environments) {
        if (env.kind != EnvironmentKind.wsl) continue;
        final wslHome = await _wslHome(env);
        if (wslHome == null) continue;
        // A UNC path into the distribution, so it is spelled the Windows way
        // even though what it names is a Linux home.
        final unc = translator
            .translate(
              EnvironmentPath(environmentId: env.id, path: wslHome),
              from: env,
              to: windows,
            )
            .path;
        stores.add(
          CliStore(
            environmentId: env.id,
            homesByAgentId: _homesUnder(unc, p.windows),
            codexAppServer: _codexAppServer(env),
          ),
        );
      }
    }
    return stores;
  }

  /// This user's home directory: `%USERPROFILE%` on Windows, `$HOME` elsewhere.
  ///
  /// Windows sets `HOME` only sometimes (Git Bash and MSYS do, a plain session
  /// does not) and `USERPROFILE` is not set off Windows at all, so each host is
  /// asked for the variable it actually defines rather than one being tried as
  /// a fallback for the other.
  ///
  /// Keyed on [kind] rather than on `Platform`, because [kind] is already the
  /// answer to "which host is this" and taking it from there keeps both
  /// branches reachable from a test on either OS.
  String? _localHomeDirectory(EnvironmentKind kind) {
    final name = usesWindowsPaths(kind) ? 'USERPROFILE' : 'HOME';
    final value = environment[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// The Codex install in [environment], as something the worker can spawn.
  CodexAppServerLaunch? _codexAppServer(ExecutionEnvironment environment) {
    final dao = installations;
    if (dao == null) return null;
    for (final installation in dao.getByEnvironment(environment.id)) {
      if (installation.agentId == AgentIds.codex) {
        return CodexAppServerLaunch(
          environment: environment,
          executable: installation.executable.path,
        );
      }
    }
    return null;
  }

  /// One home per registry agent that declares a store, under [homeDirectory].
  Map<String, String> _homesUnder(String homeDirectory, p.Context context) => {
    for (final descriptor in registry.descriptors)
      if (descriptor.store != null)
        descriptor.id: context.join(
          homeDirectory,
          descriptor.store!.homeDirectoryName,
        ),
  };

  final Map<String, String> _wslHomeCache = {};

  Future<String?> _wslHome(ExecutionEnvironment env) async {
    final cached = _wslHomeCache[env.id];
    if (cached != null) return cached;
    final runner = runnerFactory.forEnvironment(env);
    try {
      final result = await runner.run(
        const CommandRequest(
          executable: 'bash',
          arguments: ['-lc', r'printf %s "$HOME"'],
        ),
      );
      final home = result.stdout.trim();
      if (result.ok && home.isNotEmpty) {
        _wslHomeCache[env.id] = home;
        return home;
      }
      return null;
    } on CommandException {
      return null;
    }
  }
}

/// Reads CLI stores and merges their sessions into projects.
class CliDetectionService {
  CliDetectionService({
    ClaudeStoreReader? claudeReader,
    CodexStoreReader? codexReader,
    CodexAppServerReader? codexAppServerReader,
    this.antigravityReader = const AntigravityStoreSessions(),
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

  /// The store reads [stores] needs, **agent-major**: every Claude home, then
  /// every Codex home, then every Antigravity one.
  ///
  /// The order is the registry's own — `builtInAgentDescriptors` already lists
  /// them that way — and it is the order that matters. Claude's store is
  /// addressable and cheap; Codex's is the one whose every candidate file has
  /// to be opened because its paths carry a date rather than a working
  /// directory. Claude first means the common case is answered while the slow
  /// store is still walking.
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

  /// Reads every store and returns the flat list of detected sessions.
  ///
  /// [onJob] sees each job's sessions as that job finishes, so Claude's are
  /// usable while Codex is still walking. Callers that only want the total can
  /// ignore it.
  ///
  /// **No app-server is asked here, on purpose.** This is the path the *main*
  /// isolate takes — `detect()`, and the transcript index the status registry
  /// runs on its slow slot — and starting `codex app-server` costs a ~1 s
  /// `CreateProcessW` charged to the isolate that calls it. The protocol is
  /// reached through `runStoreScanJobs`, which the store-scan worker runs; a
  /// main-isolate read walks the files.
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
///
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
