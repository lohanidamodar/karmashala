import '../../environments/domain/environment_path.dart';

/// An agent executable installed in a specific execution environment.
///
/// An installation is the pair `(agentId, environment)` together with the
/// executable's location. [agentId] is an `AgentDescriptor.id` — a plain string,
/// so an agent that exists only as a registry entry is as persistable as the
/// ones with protocol adapters. The same agent installed in Windows and in WSL
/// are two independent installations with independent paths and versions.
class AgentInstallation {
  const AgentInstallation({
    required this.id,
    required this.agentId,
    required this.executable,
    required this.createdAt,
    this.version,
    this.executableByUser = false,
  });

  final String id;

  /// The `AgentDescriptor.id` of the agent this installs.
  final String agentId;

  /// Path to the executable, bound to the environment it is installed in.
  final EnvironmentPath executable;

  /// Detected version string, if known.
  final String? version;

  /// Whether a human chose [executable], rather than discovery finding it.
  ///
  /// Recorded rather than inferred, the way `Session.titleByUser` is: a sweep
  /// must not overwrite an explicit choice, and comparing the stored path
  /// against what discovery would find today is not a test that survives a
  /// restart.
  ///
  /// It does **not** protect a path that no longer works. A stale path helps
  /// nobody whoever set it, so the startup check repairs a broken hand-set path
  /// exactly as it repairs a broken detected one — and marks the result as
  /// detected, because at that point discovery is what chose it.
  final bool executableByUser;

  final DateTime createdAt;

  /// The environment this installation lives in (derived from [executable]).
  String get environmentId => executable.environmentId;

  AgentInstallation copyWith({
    String? id,
    String? agentId,
    EnvironmentPath? executable,
    String? version,
    DateTime? createdAt,
    bool? executableByUser,
  }) => AgentInstallation(
    id: id ?? this.id,
    agentId: agentId ?? this.agentId,
    executable: executable ?? this.executable,
    version: version ?? this.version,
    createdAt: createdAt ?? this.createdAt,
    executableByUser: executableByUser ?? this.executableByUser,
  );

  @override
  bool operator ==(Object other) =>
      other is AgentInstallation &&
      other.id == id &&
      other.agentId == agentId &&
      other.executable == executable &&
      other.version == version &&
      other.createdAt == createdAt &&
      other.executableByUser == executableByUser;

  @override
  int get hashCode =>
      Object.hash(id, agentId, executable, version, createdAt, executableByUser);

  @override
  String toString() => 'AgentInstallation($id, $agentId, $executable)';
}
