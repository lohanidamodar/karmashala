import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_environments/karmashala_environments.dart'
    show forgottenAgentKinds;

import '../data/data_service.dart';
import 'agent_registry_holder.dart';

/// One installation as a server reports it: the row, and what the registry
/// calls its agent.
typedef ServerAgent = ({AgentInstallation installation, bool added});

/// What one probe of this machine found.
class ServerAgentScan {
  const ServerAgentScan({
    required this.agents,
    required this.missing,
    this.error,
  });

  /// Every installation recorded here after the probe, new ones marked.
  final List<ServerAgent> agents;

  /// Display names of the agents probed for and not found.
  final List<String> missing;

  /// Why the probe could not run at all, when it could not.
  final String? error;

  /// One sentence naming what was found and what was not.
  String get summary {
    if (error != null) return 'Could not look for agent CLIs: $error';
    final added = agents.where((a) => a.added).length;
    return [
      agents.isEmpty
          ? 'No agent CLIs found on this machine.'
          : 'Found ${agents.length} agent CLI${agents.length == 1 ? '' : 's'}'
                '${added == 0 ? '' : ' ($added new)'}.',
      if (missing.isNotEmpty) 'Not installed: ${missing.join(', ')}.',
    ].join(' ');
  }
}

/// The server finds the agent CLIs on its own machine — at every start, and
/// on `agents.refresh` — and records them where every agent launch looks them up
/// (`agent_installations`, under this machine's environment row), through its
/// data API: by the same reconciliation rule as a client's sweep
/// (`planReconcile`), and told to every client. Which agents, under which
/// names, and how to read a version all come from the registry's adapters:
/// nothing here names an agent.
class ServerAgents {
  ServerAgents({
    required DataService data,
    AgentRegistry registry = AgentRegistry.builtIn,
    AgentRegistryHolder? registryHolder,
    CommandRunner? runner,
    Clock? clock,
    IdGenerator? ids,
    Map<String, String>? hostEnvironment,
  }) : _data = data,
       _registry = registry,
       _registryHolder = registryHolder,
       _runner = runner ?? const LocalCommandRunner(),
       _clock = clock ?? const SystemClock(),
       _ids = ids ?? RandomIdGenerator(),
       _hostEnvironment = hostEnvironment;

  final AgentRegistry _registry;
  final AgentRegistryHolder? _registryHolder;

  /// The registry as it stands at each probe — with a holder, the one the
  /// person-added ACP agents are composed into.
  AgentRegistry get registry => _registryHolder?.current ?? _registry;

  final DataService _data;
  final CommandRunner _runner;
  final Clock _clock;
  final IdGenerator _ids;
  final Map<String, String>? _hostEnvironment;

  /// This machine, as the environment its installations are recorded under.
  /// The same id the app records its own machine under, so a store the app
  /// shares reads the server's rows as its own machine's.
  ExecutionEnvironment get environment => localHostEnvironment(_clock.nowUtc());

  /// What is recorded for this machine now, without probing.
  List<ServerAgent> recorded() => [
    for (final installation in _data.installationsIn(localHostEnvironmentId))
      (installation: installation, added: false),
  ];

  Future<ServerAgentScan>? _inFlight;

  /// Probes every agent the registry knows and records what answered. Two
  /// asks at once share one probe.
  Future<ServerAgentScan> refresh() =>
      _inFlight ??= _refresh().whenComplete(() => _inFlight = null);

  Future<ServerAgentScan> _refresh() async {
    final here = environment;
    final List<DiscoveredAgent> found;
    try {
      found = await AgentDiscoveryService(
        runner: _runner,
        environment: here,
        ids: _ids,
        clock: _clock,
        registry: registry,
        hostEnvironment: _hostEnvironment,
      ).probeAll();
    } on Object catch (error) {
      return ServerAgentScan(
        agents: recorded(),
        missing: const [],
        error: '$error',
      );
    }
    final now = _clock.nowUtc();
    final written = _data.recordAgentsFound(
      here,
      [
        for (final agent in found)
          AgentInstallation(
            id: _ids.newId(),
            agentId: agent.descriptor.id,
            executable: agent.executable,
            version: agent.version,
            versionReadAt: agent.version == null ? null : now,
            createdAt: now,
            leadingArguments: agent.leadingArguments,
          ),
      ],
      now,
      forgotten: forgottenAgentKinds(registry, _data.installationsIn(here.id)),
    );
    final addedIds = {for (final row in written.added) row.id};
    final foundIds = {for (final agent in found) agent.descriptor.id};
    return ServerAgentScan(
      agents: [
        for (final installation in _data.installationsIn(
          localHostEnvironmentId,
        ))
          (
            installation: installation,
            added: addedIds.contains(installation.id),
          ),
      ],
      missing: [
        for (final adapter in registry.adapters)
          if (!foundIds.contains(adapter.id)) adapter.descriptor.displayName,
      ],
    );
  }

  /// [agent] as the wire carries it.
  Map<String, Object?> toJson(ServerAgent agent) {
    final installation = agent.installation;
    return {
      'id': installation.id,
      'agent': installation.agentId,
      'name':
          registry.adapterFor(installation.agentId)?.descriptor.displayName ??
          installation.agentId,
      'path': installation.executable.path,
      'version': ?installation.version,
      'versionReadAt': ?installation.versionReadAt?.toIso8601String(),
      if (installation.leadingArguments.isNotEmpty)
        'leadingArguments': installation.leadingArguments,
      'added': agent.added,
    };
  }
}
