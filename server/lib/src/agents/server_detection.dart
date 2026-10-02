import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/sweep.dart';

import '../data/data_service.dart';

/// **Finding the agent CLIs, by the server** — in every environment it can
/// run a command in: this machine, its WSL distributions, and an SSH box
/// over its own connection. The rules are `AgentSweep`'s; the rows
/// it writes go through the data service's reconciliation (`planReconcile`)
/// and are told to every client.
///
/// At start it checks what it can on its own ([startup]): repairs a rotted
/// path, looks for agents nobody has searched for yet, re-reads aged
/// versions. A client asks for the rest — "Detect agents", one environment's
/// scan, the check a launch makes.
class ServerDetection {
  ServerDetection({
    required DataService data,
    required CommandRunner Function(ExecutionEnvironment environment) runnerFor,
    required IdGenerator ids,
    Clock clock = const SystemClock(),
    AgentRegistry registry = AgentRegistry.builtIn,
    AgentRegistry Function()? registryNow,
    PathProbe pathProbe = const LocalPathProbe(),
    Map<String, String> hostEnvironment = const {},
  }) : _data = data,
       sweep = AgentSweep(
         environments: () => data.environments,
         installations: () => data.installations,
         reconcile:
             ({
               required environmentId,
               required readAt,
               required found,
               required probed,
               required readings,
             }) async => data.reconcileProbe(
               environmentId: environmentId,
               readAt: readAt,
               found: found,
               probed: probed,
               readings: readings,
             ),
         recordVersion: (id, version, readAt) async =>
             data.recordInstallationVersion(id, version, readAt),
         runnerFor: runnerFor,
         probeLog: AgentProbeLog(
           read: () => data.serverValue(AgentProbeLog.key),
           write: (json) => data.setServerValue(AgentProbeLog.key, json),
         ),
         ids: ids,
         clock: clock,
         registry: registry,
         registryNow: registryNow,
         pathProbe: pathProbe,
         hostEnvironment: hostEnvironment,
       );

  final DataService _data;
  final AgentSweep sweep;

  Future<AgentPathRepairReport>? _repairing;
  Future<AgentDiscoveryReport>? _detecting;

  /// Probes every environment, or [environmentId] alone (add-only).
  Future<AgentDiscoveryReport> detect({String? environmentId}) {
    if (environmentId == null) {
      return _detecting ??= sweep.sweep().whenComplete(() => _detecting = null);
    }
    ExecutionEnvironment? environment;
    for (final candidate in _data.environments) {
      if (candidate.id == environmentId) environment = candidate;
    }
    if (environment == null) {
      return Future.error(
        DataRefused.notFound('no environment with id $environmentId'),
      );
    }
    return sweep.scan(environment);
  }

  /// Checks the recorded executables and repairs the rotted ones; [full]
  /// re-probes everything. Two asks at once share one check.
  Future<AgentPathRepairReport> repair({bool full = false}) {
    if (full) return sweep.repairBrokenPaths(full: true);
    return _repairing ??= sweep.repairBrokenPaths().whenComplete(
      () => _repairing = null,
    );
  }

  Future<List<AgentVersionChange>> refreshVersions() =>
      sweep.refreshStaleVersions();

  Future<List<AgentInstallation>> discoverUnprobed() =>
      sweep.discoverUnprobed();

  /// What the server checks on its own at start, in order: a rotted path is
  /// repaired before anything reads a version through it. Each step's
  /// failure is logged and leaves the rows as they were.
  Future<void> startup({void Function(String line)? log}) async {
    Future<void> step(String what, Future<Object?> Function() run) async {
      try {
        final result = await run();
        log?.call('agents: $what: $result');
      } on Object catch (error) {
        log?.call('agents: $what failed: $error');
      }
    }

    await step('paths', () async => (await repair()).summary);
    await step(
      'never searched',
      () async => '${(await discoverUnprobed()).length} found',
    );
    await step(
      'versions',
      () async => '${(await refreshVersions()).length} changed',
    );
  }
}
