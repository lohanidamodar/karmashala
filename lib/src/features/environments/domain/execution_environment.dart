import 'environment_kind.dart';

/// An environment in which commands run and paths are interpreted: Windows
/// native, a specific WSL distribution, or a remote host reached over SSH.
///
/// Every [EnvironmentPath] references one of these by [id]. Discovery of the
/// local environments lives in `EnvironmentDiscoveryService`; SSH environments
/// are not discovered but configured — one is created per saved `SshHost`.
class ExecutionEnvironment {
  const ExecutionEnvironment({
    required this.id,
    required this.kind,
    required this.name,
    required this.createdAt,
    this.wslDistribution,
    this.sshHostId,
  });

  /// Stable identifier, e.g. `windows`, `wsl:Ubuntu` or `ssh:<hostId>`.
  final String id;

  /// Whether this is Windows native, a WSL distribution, or a remote SSH host.
  final EnvironmentKind kind;

  /// Human-readable display name.
  final String name;

  /// For [EnvironmentKind.wsl], the distribution name (e.g. `Ubuntu`); otherwise
  /// `null`.
  final String? wslDistribution;

  /// For [EnvironmentKind.ssh], the id of the `SshHost` row holding the address,
  /// user and auth method for this environment; otherwise `null`.
  final String? sshHostId;

  final DateTime createdAt;

  ExecutionEnvironment copyWith({
    String? id,
    EnvironmentKind? kind,
    String? name,
    String? wslDistribution,
    String? sshHostId,
    DateTime? createdAt,
  }) => ExecutionEnvironment(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    name: name ?? this.name,
    wslDistribution: wslDistribution ?? this.wslDistribution,
    sshHostId: sshHostId ?? this.sshHostId,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is ExecutionEnvironment &&
      other.id == id &&
      other.kind == kind &&
      other.name == name &&
      other.wslDistribution == wslDistribution &&
      other.sshHostId == sshHostId &&
      other.createdAt == createdAt;

  @override
  int get hashCode =>
      Object.hash(id, kind, name, wslDistribution, sshHostId, createdAt);

  @override
  String toString() => 'ExecutionEnvironment($id, $kind, $name)';
}
