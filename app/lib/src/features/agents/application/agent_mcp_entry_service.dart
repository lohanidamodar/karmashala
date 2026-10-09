import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show CliStore;
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_mcp/access.dart';

import '../../../core/probe/probe_mode.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../settings/application/settings_controller.dart';
import 'agent_providers.dart';

export 'package:karmashala_agent_reporting/hooks.dart'
    show KarmashalaMcpEntryState;

/// Karmashala's entry in one agent's MCP file in one environment.
class AgentMcpEntry {
  const AgentMcpEntry({
    required this.agentId,
    required this.environmentId,
    required this.state,
    this.path,
    this.problem,
  });

  final String agentId;
  final String environmentId;
  final KarmashalaMcpEntryState state;

  /// The file, as this app reaches it.
  final String? path;

  /// Why it is not [KarmashalaMcpEntryState.current] when it should be.
  final String? problem;
}

/// What the last sweep found, and when.
class AgentMcpEntryReport {
  const AgentMcpEntryReport(this.entries, {this.checkedAt});

  /// Before any sweep has finished — not a sweep that found nothing.
  static const AgentMcpEntryReport unswept = AgentMcpEntryReport([]);

  final List<AgentMcpEntry> entries;
  final DateTime? checkedAt;

  bool get swept => checkedAt != null;
}

class AgentMcpEntryReportController extends Notifier<AgentMcpEntryReport> {
  @override
  AgentMcpEntryReport build() => AgentMcpEntryReport.unswept;

  void set(AgentMcpEntryReport next) => state = next;
}

final agentMcpEntryReportProvider =
    NotifierProvider<AgentMcpEntryReportController, AgentMcpEntryReport>(
      AgentMcpEntryReportController.new,
    );

/// The bridge beside this app, or null in a run that has not built one.
final karmashalaBridgePathProvider = Provider<String?>(
  (ref) => const LauncherMcp().bridgeExecutable()?.path,
);

/// The home a probe writes agent files under instead of the real one:
/// `<KARMASHALA_DATA_DIR>/probe-home`. Null outside a probe.
String? probeAgentHome(ProbeMode probe) {
  final data = probe.dataDirectory;
  if (!probe.enabled || data == null) return null;
  return p.join(data, 'probe-home');
}

/// **Keeps Karmashala's entry in the MCP file of each agent that takes no
/// server for one launch** — agy, today. Every run of that agent reads the
/// entry; the bridge it names serves only a run Karmashala started, which
/// carries `KARMASHALA_SESSION_ID`.
///
/// A probe never reaches the real stores: it writes under [probeAgentHome].
class AgentMcpEntryService {
  AgentMcpEntryService(this._ref, {AppLogger? logger, Duration? storeBudget})
    : _log = logger ?? AppLogger.named('agent-mcp-entry'),
      _storeBudget = storeBudget ?? const Duration(seconds: 10);

  final Ref _ref;
  final AppLogger _log;
  final Duration _storeBudget;

  /// Writes or updates the entry where the setting allows it, and reads the
  /// rest. Published to [agentMcpEntryReportProvider].
  Future<AgentMcpEntryReport> sweep() => _publish(
    install: _ref.read(settingsControllerProvider).agentMcpEntries,
    remove: false,
  );

  /// Takes the entry out everywhere and keeps it out on later launches.
  Future<AgentMcpEntryReport> removeAll() {
    _ref.read(settingsControllerProvider.notifier).setAgentMcpEntries(false);
    return _publish(install: false, remove: true);
  }

  /// Puts it back, and keeps it on later launches.
  Future<AgentMcpEntryReport> restore() {
    _ref.read(settingsControllerProvider.notifier).setAgentMcpEntries(true);
    return _publish(install: true, remove: false);
  }

  Future<AgentMcpEntryReport> _publish({
    required bool install,
    required bool remove,
  }) async {
    final entries = await _forEachStore(install: install, remove: remove);
    final report = AgentMcpEntryReport(
      entries,
      checkedAt: _ref.read(clockProvider).nowUtc(),
    );
    _ref.read(agentMcpEntryReportProvider.notifier).set(report);
    return report;
  }

  Future<List<AgentMcpEntry>> _forEachStore({
    required bool install,
    required bool remove,
  }) async {
    final descriptors = [
      for (final d in _ref.read(agentRegistryProvider).descriptors)
        if (d.mcpConfig.installsKarmashalaEntry) d,
    ];
    if (descriptors.isEmpty) return const [];
    final environments = _ref.read(environmentsDataProvider).getAll();
    final stores = await _stores(environments, descriptors);
    final bridge = _ref.read(karmashalaBridgePathProvider);
    const installer = AgentMcpEntryInstaller();
    final pending = <Future<AgentMcpEntry>>[];
    for (final (environment, store) in stores) {
      for (final descriptor in descriptors) {
        final home = store.homesByAgentId[descriptor.id];
        if (home == null) continue;
        pending.add(
          _one(
            installer,
            descriptor,
            environment,
            home,
            bridge: bridge,
            install: install,
            remove: remove,
            windows: environments
                .where((e) => e.kind == EnvironmentKind.windowsNative)
                .firstOrNull,
          ).timeout(
            _storeBudget,
            onTimeout: () => AgentMcpEntry(
              agentId: descriptor.id,
              environmentId: environment.id,
              state: KarmashalaMcpEntryState.absent,
              problem: 'the store did not answer in time',
            ),
          ),
        );
      }
    }
    return Future.wait(pending);
  }

  /// The located stores, or in a probe one local store under its own home.
  Future<List<(ExecutionEnvironment, CliStore)>> _stores(
    List<ExecutionEnvironment> environments,
    List<AgentDescriptor> descriptors,
  ) async {
    final byId = {for (final e in environments) e.id: e};
    final probe = _ref.read(probeModeProvider);
    if (probe.enabled) {
      final home = probeAgentHome(probe);
      final local = environments.where((e) => isLocalHost(e.kind)).firstOrNull;
      if (home == null || local == null) {
        _log.info('Probe: no data folder or local machine; no MCP entry.');
        return const [];
      }
      final homes = <String, String>{};
      for (final descriptor in descriptors) {
        final store = descriptor.store;
        if (store == null) continue;
        final storeHome = p.joinAll([
          home,
          ...store.homeDirectoryName.split('/'),
        ]);
        // The probe's own throwaway home, so the agent counts as installed.
        await Directory(storeHome).create(recursive: true);
        homes[descriptor.id] = storeHome;
      }
      return [
        (local, CliStore(environmentId: local.id, homesByAgentId: homes)),
      ];
    }
    final located = await _ref
        .read(cliStoreLocatorProvider)
        .locate(environments);
    return [
      for (final store in located)
        if (byId[store.environmentId] case final environment?)
          (environment, store),
    ];
  }

  Future<AgentMcpEntry> _one(
    AgentMcpEntryInstaller installer,
    AgentDescriptor descriptor,
    ExecutionEnvironment environment,
    String home, {
    required String? bridge,
    required bool install,
    required bool remove,
    required ExecutionEnvironment? windows,
  }) async {
    final path = installer.fileFor(descriptor, home)?.path;
    AgentMcpEntry row(KarmashalaMcpEntryState state, [String? problem]) =>
        AgentMcpEntry(
          agentId: descriptor.id,
          environmentId: environment.id,
          state: state,
          path: path,
          problem: problem,
        );
    try {
      if (remove) return row(await installer.remove(descriptor, home));
      final entry = bridge == null
          ? null
          : _entryFor(environment, bridge, windows: windows);
      if (!install || entry == null) {
        final state = await installer.stateOf(descriptor, home, entry: entry);
        return row(
          state,
          !install
              ? null
              : bridge == null
              ? 'karmashala_mcp is not beside this app, so there is nothing '
                    'to point the entry at'
              : 'the bridge cannot be reached from this machine',
        );
      }
      final state = await installer.install(descriptor, home, entry);
      // A foreign entry needs no problem line: its row already says so.
      return row(state);
    } on Object catch (error, stack) {
      _log.warning(
        'Could not keep the ${descriptor.id} MCP entry in '
        '${describeEnvironmentId(environment.id)}; $path is untouched.',
        error,
        stack,
      );
      return row(KarmashalaMcpEntryState.absent, '$error');
    }
  }

  /// The entry for [environment], or null where the bridge cannot be reached
  /// from it: a WSL agent needs the Windows bridge's `/mnt` path.
  Map<String, Object?>? _entryFor(
    ExecutionEnvironment environment,
    String bridge, {
    required ExecutionEnvironment? windows,
  }) {
    if (isLocalHost(environment.kind)) {
      return karmashalaMcpEntry(kind: environment.kind, bridgePath: bridge);
    }
    if (environment.kind != EnvironmentKind.wsl || windows == null) return null;
    final translated = _ref
        .read(pathTranslatorProvider)
        .translate(
          EnvironmentPath(environmentId: windows.id, path: bridge),
          from: windows,
          to: environment,
        )
        .path;
    return karmashalaMcpEntry(kind: environment.kind, bridgePath: translated);
  }
}

final agentMcpEntryServiceProvider = Provider<AgentMcpEntryService>(
  (ref) => AgentMcpEntryService(ref),
);
