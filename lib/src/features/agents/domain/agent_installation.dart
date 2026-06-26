import '../../environments/domain/environment_path.dart';
import 'agent_kind.dart';

/// An agent executable installed in a specific execution environment.
///
/// An installation is the pair `(agentKind, environment)` together with the
/// executable's location. The same [AgentKind] installed in Windows and in WSL
/// are two independent installations with independent paths and versions.
class AgentInstallation {
  const AgentInstallation({
    required this.id,
    required this.agentKind,
    required this.executable,
    required this.createdAt,
    this.version,
  });

  final String id;
  final AgentKind agentKind;

  /// Path to the executable, bound to the environment it is installed in.
  final EnvironmentPath executable;

  /// Detected version string, if known.
  final String? version;

  final DateTime createdAt;

  /// The environment this installation lives in (derived from [executable]).
  String get environmentId => executable.environmentId;

  AgentInstallation copyWith({
    String? id,
    AgentKind? agentKind,
    EnvironmentPath? executable,
    String? version,
    DateTime? createdAt,
  }) => AgentInstallation(
    id: id ?? this.id,
    agentKind: agentKind ?? this.agentKind,
    executable: executable ?? this.executable,
    version: version ?? this.version,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is AgentInstallation &&
      other.id == id &&
      other.agentKind == agentKind &&
      other.executable == executable &&
      other.version == version &&
      other.createdAt == createdAt;

  @override
  int get hashCode =>
      Object.hash(id, agentKind, executable, version, createdAt);

  @override
  String toString() => 'AgentInstallation($id, $agentKind, $executable)';
}
