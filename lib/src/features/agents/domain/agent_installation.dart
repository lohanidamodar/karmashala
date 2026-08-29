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
  });

  final String id;

  /// The `AgentDescriptor.id` of the agent this installs.
  final String agentId;

  /// Path to the executable, bound to the environment it is installed in.
  final EnvironmentPath executable;

  /// Detected version string, if known.
  final String? version;

  final DateTime createdAt;

  /// The environment this installation lives in (derived from [executable]).
  String get environmentId => executable.environmentId;

  AgentInstallation copyWith({
    String? id,
    String? agentId,
    EnvironmentPath? executable,
    String? version,
    DateTime? createdAt,
  }) => AgentInstallation(
    id: id ?? this.id,
    agentId: agentId ?? this.agentId,
    executable: executable ?? this.executable,
    version: version ?? this.version,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is AgentInstallation &&
      other.id == id &&
      other.agentId == agentId &&
      other.executable == executable &&
      other.version == version &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, agentId, executable, version, createdAt);

  @override
  String toString() => 'AgentInstallation($id, $agentId, $executable)';
}
