import 'dart:convert';

import '../../permissions/permission_risk.dart';
import '../adapter/agent_adapter.dart';
import '../adapter/agent_presentation.dart';
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
    this.iconUrl,
    this.modeRungs = const {},
  });

  final String id;
  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final AcpAgentSource source;

  /// The registry entry's id when [source] is [AcpAgentSource.registry].
  final String? registryId;

  /// The registry entry's icon (an SVG's URL), when it named one.
  final String? iconUrl;
  final DateTime createdAt;

  /// The rung each of the agent's modes stands for, keyed by the mode's id
  /// or name as the person wrote it; empty when they placed none.
  final Map<String, PermissionRisk> modeRungs;

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
    String? iconUrl,
    bool clearIconUrl = false,
    DateTime? createdAt,
    Map<String, PermissionRisk>? modeRungs,
  }) => AcpAgentRow(
    id: id,
    name: name ?? this.name,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    source: source ?? this.source,
    registryId: clearRegistryId ? null : registryId ?? this.registryId,
    iconUrl: clearIconUrl ? null : iconUrl ?? this.iconUrl,
    createdAt: createdAt ?? this.createdAt,
    modeRungs: modeRungs ?? this.modeRungs,
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
      other.iconUrl == iconUrl &&
      other.createdAt == createdAt &&
      _sameMap(other.modeRungs, modeRungs);

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
    iconUrl,
    createdAt,
    Object.hashAllUnordered([
      for (final entry in modeRungs.entries)
        Object.hash(entry.key, entry.value),
    ]),
  );

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameMap<V>(Map<String, V> a, Map<String, V> b) {
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
/// command as given, on either platform, with the row's argv as its ACP mode,
/// drawn with the icon the registry gave it. Nothing terminal-shaped, and no
/// version probe — the command is a person's, and running it with
/// `--version` is not something the row promised is safe.
AgentAdapter acpAgentAdapter(AcpAgentRow row) => DataOnlyAgentAdapter(
  AgentDescriptor(
    id: row.agentId,
    displayName: row.name,
    binaries: AgentBinaries(windows: [row.command], posix: [row.command]),
    discovery: const AgentDiscoveryRules(probeVersion: false),
    acp: AcpLaunchSpec(
      arguments: row.args,
      environment: row.env,
      modeNames: {
        for (final rung in PermissionRisk.values)
          if (row.modeRungs.entries.where((e) => e.value == rung).isNotEmpty)
            rung: [
              for (final e in row.modeRungs.entries)
                if (e.value == rung) e.key,
            ],
      },
    ),
  ),
  presentation: AgentPresentation.of(row.name, iconUrl: row.iconUrl),
);

/// The words a person writes for each rung in a mode line, as in
/// `Plan = read-only`.
const Map<PermissionRisk, String> acpModeRungWords = {
  PermissionRisk.readOnly: 'read-only',
  PermissionRisk.ask: 'ask',
  PermissionRisk.acceptEdits: 'accept-edits',
  PermissionRisk.autoRun: 'auto',
  PermissionRisk.bypass: 'bypass',
};

/// `<mode id or name> = <rung>`, one per line, blank lines skipped; the rung
/// is one of [acpModeRungWords]. A line out of shape is refused in words.
({Map<String, PermissionRisk> rungs, String? refusal}) parseAcpModeRungLines(
  String text,
) {
  final byWord = {
    for (final entry in acpModeRungWords.entries) entry.value: entry.key,
  };
  final rungs = <String, PermissionRisk>{};
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final split = line.lastIndexOf('=');
    final mode = split < 0 ? '' : line.substring(0, split).trim();
    final word = split < 0
        ? ''
        : line.substring(split + 1).trim().toLowerCase();
    final rung = byWord[word];
    if (mode.isEmpty || rung == null) {
      return (
        rungs: const {},
        refusal:
            '"$line" is not a mode line: write <mode> = <rung>, where the '
            'rung is one of ${acpModeRungWords.values.join(', ')}.',
      );
    }
    rungs[mode] = rung;
  }
  return (rungs: rungs, refusal: null);
}

/// [parseAcpModeRungLines] undone.
String formatAcpModeRungLines(Map<String, PermissionRisk> rungs) => rungs
    .entries
    .map((e) => '${e.key} = ${acpModeRungWords[e.value]}')
    .join('\n');
