/// A filesystem path **bound to the execution environment that owns it**.
///
/// This type exists to enforce architecture constraints 7 & 8: a path is never
/// stored or passed as a bare string divorced from its environment, and a
/// Windows path is never treated as interchangeable with a WSL path. Two
/// [EnvironmentPath]s are equal only when they share the same [environmentId]
/// *and* [path] — the same textual path in two different environments is two
/// different locations.
///
/// Path *translation* between environments (e.g. `C:\x` ⇄ `/mnt/c/x`) is an
/// explicit, environment-aware operation introduced in a later loop; this type
/// deliberately offers no implicit conversion.
class EnvironmentPath {
  const EnvironmentPath({required this.environmentId, required this.path});

  /// Id of the owning [ExecutionEnvironment].
  final String environmentId;

  /// The path as written in that environment (not normalized across environments).
  final String path;

  EnvironmentPath copyWith({String? environmentId, String? path}) =>
      EnvironmentPath(
        environmentId: environmentId ?? this.environmentId,
        path: path ?? this.path,
      );

  @override
  bool operator ==(Object other) =>
      other is EnvironmentPath &&
      other.environmentId == environmentId &&
      other.path == path;

  @override
  int get hashCode => Object.hash(environmentId, path);

  @override
  String toString() => 'EnvironmentPath($environmentId: $path)';
}
