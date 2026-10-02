import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';

import 'values_json.dart';

/// The agent kinds among [stored] that [registry] no longer knows — an ACP
/// agent whose row was removed. A probe judges them as asked about and
/// found nowhere, so their rows go on the next sweep.
Set<String> forgottenAgentKinds(
  AgentRegistry registry,
  Iterable<AgentInstallation> stored,
) => {
  for (final row in stored)
    if (registry.adapterFor(row.agentId) == null) row.agentId,
};

/// **The one reconciliation of a probe with the recorded installations** —
/// what the server applies to every sweep, the desktop's across its
/// environments and its own of this machine alike:
///
/// - the same agent at the same path is the same row: its version is
///   recorded as read now (a confirmed reading is a fresh reading);
/// - a path a person chose that is not *observed* broken is their answer,
///   and a probe finding the agent elsewhere does not overrule it;
/// - otherwise the agent found elsewhere is the row that moved: it follows,
///   **in place, keeping its id** — settings pin the default agent by id and
///   every session row points at it;
/// - else it is a new row;
/// - of the rows left over, only those of an agent this probe asked about are
///   judged: a pinned one stays, one whose route could not be established
///   (`unreachable`) is kept — no evidence of absence — and the rest are
///   **absent**: removed if nothing points at them, retained if something
///   does (the server decides which; the schema's `ON DELETE RESTRICT` is the
///   backstop).
///
/// Pure: [planReconcile] says what to write; the server writes it.
InstallationPlan planReconcile({
  required String environmentId,
  required List<AgentInstallation> stored,
  required List<AgentInstallation> found,
  required Set<String> probed,
  required Map<String, ExecutableReachability> readings,
  required DateTime readAt,
}) {
  final rows = [
    for (final row in stored)
      if (row.environmentId == environmentId) row,
  ];
  final plan = InstallationPlan._();
  final consumed = <String>{};

  // A hand-set path not *observed* broken is the person's answer. Unchecked
  // (a path on another machine's disk) counts as working.
  bool isPinned(AgentInstallation row) {
    if (!row.executableByUser) return false;
    final reading = readings[row.id];
    return reading == null || reading == ExecutableReachability.usable;
  }

  AgentInstallation asRead(AgentInstallation row, String? version) =>
      version == null
      ? row
      : row.copyWith(version: version, versionReadAt: readAt);

  for (final agent in found) {
    if (agent.environmentId != environmentId) continue;
    final agentId = agent.agentId;
    final path = agent.executable.path;
    final version = agent.version;

    AgentInstallation? atThisPath;
    for (final row in rows) {
      if (row.agentId == agentId && row.executable.path == path) {
        atThisPath = row;
        break;
      }
    }
    if (atThisPath != null) {
      // The same path found twice in one probe is one row, told once.
      if (!consumed.add(atThisPath.id)) continue;
      if (version != null) plan.versions[atThisPath.id] = version;
      if (version != null && atThisPath.version != version) {
        plan.versionChanges.add(
          InstallationVersionChange(agentId, atThisPath.version, version),
        );
      }
      // The runner's arguments follow what discovery found: a row written
      // before they were recorded, or an agent that moved into npx.
      if (!_sameArguments(
        atThisPath.leadingArguments,
        agent.leadingArguments,
      )) {
        plan.leadingArguments[atThisPath.id] = agent.leadingArguments;
      }
      plan.present.add(
        asRead(
          atThisPath,
          version,
        ).copyWith(leadingArguments: agent.leadingArguments),
      );
      continue;
    }

    // The same agent here at another path: the person pinned it there, or it
    // moved and this row follows it.
    final elsewhere = [
      for (final row in rows)
        if (row.agentId == agentId &&
            !consumed.contains(row.id) &&
            row.executable.path != path)
          row,
    ];
    final pinned = elsewhere.where(isPinned).toList();
    if (pinned.isNotEmpty) {
      consumed.add(pinned.first.id);
      plan.pinned.add(pinned.first);
      plan.present.add(pinned.first);
      continue;
    }
    if (elsewhere.isNotEmpty) {
      final moved = elsewhere.first;
      consumed.add(moved.id);
      plan.moves[moved.id] = path;
      rows[rows.indexOf(moved)] = moved.copyWith(executable: agent.executable);
      plan.pathChanges.add(
        InstallationPathChange(agentId, moved.executable.path, path),
      );
      if (version != null) plan.versions[moved.id] = version;
      if (version != null && moved.version != version) {
        plan.versionChanges.add(
          InstallationVersionChange(agentId, moved.version, version),
        );
      }
      if (!_sameArguments(moved.leadingArguments, agent.leadingArguments)) {
        plan.leadingArguments[moved.id] = agent.leadingArguments;
      }
      plan.present.add(
        asRead(moved, version).copyWith(
          executable: agent.executable,
          executableByUser: false,
          leadingArguments: agent.leadingArguments,
        ),
      );
      continue;
    }

    final installation = AgentInstallation(
      id: agent.id,
      agentId: agentId,
      executable: agent.executable,
      version: version,
      versionReadAt: version == null ? null : (agent.versionReadAt ?? readAt),
      createdAt: agent.createdAt,
      leadingArguments: agent.leadingArguments,
    );
    plan.inserts.add(installation);
    plan.present.add(installation);
    // A second find of the same path in one probe is the same row.
    rows.add(installation);
    consumed.add(installation.id);
  }

  for (final row in rows) {
    if (consumed.contains(row.id)) continue;
    if (!probed.contains(row.agentId)) {
      plan.present.add(row);
    } else if (isPinned(row)) {
      plan.pinned.add(row);
      plan.present.add(row);
    } else if (readings[row.id] == ExecutableReachability.unreachable) {
      plan.unreachable.add(row);
    } else {
      plan.absent.add(row);
    }
  }
  return plan;
}

bool _sameArguments(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What [planReconcile] decided: the writes, and what they amount to.
final class InstallationPlan {
  InstallationPlan._();

  /// New rows.
  final inserts = <AgentInstallation>[];

  /// Rows that move to a new path (by id), no longer a person's choice.
  final moves = <String, String>{};

  /// Versions read now, by row id.
  final versions = <String, String>{};

  /// Rows whose runner arguments (`AgentInstallation.leadingArguments`) now
  /// read differently, by row id.
  final leadingArguments = <String, List<String>>{};

  /// Rows of an agent the probe asked about that it did not find anywhere.
  final absent = <AgentInstallation>[];

  final present = <AgentInstallation>[];
  final pinned = <AgentInstallation>[];
  final unreachable = <AgentInstallation>[];
  final versionChanges = <InstallationVersionChange>[];
  final pathChanges = <InstallationPathChange>[];
}

/// One recorded version that no longer matches what the CLI says.
final class InstallationVersionChange {
  const InstallationVersionChange(this.agentId, this.from, this.to);

  final String agentId;
  final String? from;
  final String? to;

  Map<String, Object?> toJson() => {
    'agentId': agentId,
    'from': ?from,
    'to': ?to,
  };

  static InstallationVersionChange fromJson(Map<String, Object?> json) =>
      InstallationVersionChange(
        json['agentId']! as String,
        json['from'] as String?,
        json['to'] as String?,
      );
}

/// One installation found at a new path and followed to it.
final class InstallationPathChange {
  const InstallationPathChange(this.agentId, this.from, this.to);

  final String agentId;
  final String from;
  final String to;

  Map<String, Object?> toJson() => {'agentId': agentId, 'from': from, 'to': to};

  static InstallationPathChange fromJson(Map<String, Object?> json) =>
      InstallationPathChange(
        json['agentId']! as String,
        json['from']! as String,
        json['to']! as String,
      );
}

/// What reconciling one environment established, as the server wrote it.
/// A client names the agents (its registry's display names) when it reports.
final class InstallationsReconciled {
  const InstallationsReconciled({
    this.present = const [],
    this.added = const [],
    this.removed = const [],
    this.retained = const [],
    this.pinned = const [],
    this.unreachable = const [],
    this.versionChanges = const [],
    this.pathChanges = const [],
  });

  /// Installations present here after the sweep.
  final List<AgentInstallation> present;
  final List<AgentInstallation> added;
  final List<AgentInstallation> removed;

  /// Not found, but kept: something still points at them.
  final List<AgentInstallation> retained;
  final List<AgentInstallation> pinned;
  final List<AgentInstallation> unreachable;
  final List<InstallationVersionChange> versionChanges;
  final List<InstallationPathChange> pathChanges;

  Map<String, Object?> toJson() => {
    'present': [for (final i in present) installationToJson(i)],
    'added': [for (final i in added) installationToJson(i)],
    'removed': [for (final i in removed) installationToJson(i)],
    'retained': [for (final i in retained) installationToJson(i)],
    'pinned': [for (final i in pinned) installationToJson(i)],
    'unreachable': [for (final i in unreachable) installationToJson(i)],
    'versions': [for (final c in versionChanges) c.toJson()],
    'moves': [for (final c in pathChanges) c.toJson()],
  };

  static InstallationsReconciled fromJson(Map<String, Object?> json) {
    List<AgentInstallation> rows(String key) => [
      for (final item in json[key]! as List)
        installationFromJson((item as Map).cast<String, Object?>()),
    ];
    return InstallationsReconciled(
      present: rows('present'),
      added: rows('added'),
      removed: rows('removed'),
      retained: rows('retained'),
      pinned: rows('pinned'),
      unreachable: rows('unreachable'),
      versionChanges: [
        for (final item in json['versions']! as List)
          InstallationVersionChange.fromJson(
            (item as Map).cast<String, Object?>(),
          ),
      ],
      pathChanges: [
        for (final item in json['moves']! as List)
          InstallationPathChange.fromJson(
            (item as Map).cast<String, Object?>(),
          ),
      ],
    );
  }
}

/// [reading]'s wire name, and back.
String reachabilityToJson(ExecutableReachability reading) => reading.name;

ExecutableReachability reachabilityFromJson(Object? json) {
  for (final value in ExecutableReachability.values) {
    if (value.name == json) return value;
  }
  throw FormatException('not a reachability: $json');
}

/// Whether [path] is taken by another row of [rows] for the same agent in
/// the same environment as [row] — the table's identity.
bool installationPathTaken(
  List<AgentInstallation> rows,
  AgentInstallation row,
  String path,
) => rows.any(
  (other) =>
      other.id != row.id &&
      other.agentId == row.agentId &&
      other.environmentId == row.environmentId &&
      other.executable.path == path,
);

/// [row] at [path], as a person chose it.
AgentInstallation installationAt(
  AgentInstallation row,
  String path, {
  required bool byUser,
}) => row.copyWith(
  executable: EnvironmentPath(environmentId: row.environmentId, path: path),
  executableByUser: byUser,
);
