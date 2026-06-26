import '../../environments/domain/environment_path.dart';

/// A Git repository found on disk by discovery, before it is persisted.
///
/// Carries only what discovery can know: a display [name] (the folder name) and
/// its [path], bound to the environment that was scanned.
class DiscoveredRepository {
  const DiscoveredRepository({required this.name, required this.path});

  final String name;
  final EnvironmentPath path;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredRepository && other.name == name && other.path == path;

  @override
  int get hashCode => Object.hash(name, path);

  @override
  String toString() => 'DiscoveredRepository($name, $path)';
}
