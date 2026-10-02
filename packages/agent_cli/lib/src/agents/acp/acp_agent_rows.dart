import '../adapter/agent_adapter.dart';
import '../adapter/data_only_agent_adapter.dart';
import '../domain/agent_descriptor.dart';

/// Where an [AcpAgentRow] came from: typed in by hand, or picked from the
/// public ACP registry.
enum AcpAgentSource { custom, registry }

/// One ACP agent a person added, as the `acp_agents` table keeps it: the
/// command that speaks the protocol on its stdio, the argv that puts it in
/// that mode, and the variables layered over its environment.
class AcpAgentRow {
  const AcpAgentRow({
    required this.id,
    required this.name,
    required this.command,
    required this.createdAt,
    this.args = const [],
    this.env = const {},
    this.source = AcpAgentSource.custom,
    this.registryId,
  });

  final String id;
  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final AcpAgentSource source;

  /// The registry entry's id when [source] is [AcpAgentSource.registry].
  final String? registryId;
  final DateTime createdAt;

  /// The adapter id this row is known by everywhere an agent id is kept.
  String get agentId => acpAgentIdFor(id);

  AcpAgentRow copyWith({
    String? name,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    AcpAgentSource? source,
    String? registryId,
    bool clearRegistryId = false,
    DateTime? createdAt,
  }) => AcpAgentRow(
    id: id,
    name: name ?? this.name,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    source: source ?? this.source,
    registryId: clearRegistryId ? null : registryId ?? this.registryId,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is AcpAgentRow &&
      other.id == id &&
      other.name == name &&
      other.command == command &&
      _sameList(other.args, args) &&
      _sameMap(other.env, env) &&
      other.source == source &&
      other.registryId == registryId &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    command,
    Object.hashAll(args),
    Object.hashAllUnordered([
      for (final entry in env.entries) Object.hash(entry.key, entry.value),
    ]),
    source,
    registryId,
    createdAt,
  );

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  String toString() => 'AcpAgentRow($id, $name, $command)';
}

/// The prefix every row-backed agent's id carries. Code outside this package
/// asks `descriptor.acp != null`, never for the prefix.
const String acpAgentIdPrefix = 'acp:';

/// The adapter id for the row [rowId].
String acpAgentIdFor(String rowId) => '$acpAgentIdPrefix$rowId';

/// [row] as an agent: a data-only adapter whose descriptor says to run the
/// command as given, on either platform, with the row's argv as its ACP mode.
/// Nothing terminal-shaped, and no version probe — the command is a person's,
/// and running it with `--version` is not something the row promised is safe.
AgentAdapter acpAgentAdapter(AcpAgentRow row) => DataOnlyAgentAdapter(
  AgentDescriptor(
    id: row.agentId,
    displayName: row.name,
    binaries: AgentBinaries(windows: [row.command], posix: [row.command]),
    discovery: const AgentDiscoveryRules(probeVersion: false),
    acp: AcpLaunchSpec(arguments: row.args, environment: row.env),
  ),
);
