import 'environment_kind.dart';

/// An environment in which commands run and paths are interpreted: Windows
/// native, or a specific WSL distribution.
///
/// Every [EnvironmentPath] references one of these by [id]. In Loop 1 these are
/// only persisted; actual discovery of available environments arrives in Loop 3.
class ExecutionEnvironment {
  const ExecutionEnvironment({
    required this.id,
    required this.kind,
    required this.name,
    required this.createdAt,
    this.wslDistribution,
  });

  /// Stable identifier, e.g. `windows` or `wsl:Ubuntu`.
  final String id;

  /// Whether this is Windows native or a WSL distribution.
  final EnvironmentKind kind;

  /// Human-readable display name.
  final String name;

  /// For [EnvironmentKind.wsl], the distribution name (e.g. `Ubuntu`); otherwise
  /// `null`.
  final String? wslDistribution;

  final DateTime createdAt;

  ExecutionEnvironment copyWith({
    String? id,
    EnvironmentKind? kind,
    String? name,
    String? wslDistribution,
    DateTime? createdAt,
  }) => ExecutionEnvironment(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    name: name ?? this.name,
    wslDistribution: wslDistribution ?? this.wslDistribution,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is ExecutionEnvironment &&
      other.id == id &&
      other.kind == kind &&
      other.name == name &&
      other.wslDistribution == wslDistribution &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, kind, name, wslDistribution, createdAt);

  @override
  String toString() => 'ExecutionEnvironment($id, $kind, $name)';
}
