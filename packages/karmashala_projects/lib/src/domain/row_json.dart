import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';

/// The wire shape of the values this domain shares with others: where a
/// thing is, a checkout, and a checkout discovery found. Each reader throws
/// [FormatException] on a value out of shape.

Map<String, Object?> environmentPathToJson(EnvironmentPath path) => {
  'environmentId': path.environmentId,
  'path': path.path,
};

EnvironmentPath environmentPathFromJson(Object? json) {
  if (json is Map &&
      json['environmentId'] is String &&
      json['path'] is String) {
    return EnvironmentPath(
      environmentId: json['environmentId'] as String,
      path: json['path'] as String,
    );
  }
  throw const FormatException('not a path in an environment');
}

Map<String, Object?> repositoryToJson(Repository repository) => {
  'id': repository.id,
  'projectId': repository.projectId,
  'name': repository.name,
  'path': environmentPathToJson(repository.path),
  'createdAt': repository.createdAt.toUtc().toIso8601String(),
  'canonicalId': ?repository.canonicalId,
};

Repository repositoryFromJson(Object? json) {
  if (json is! Map ||
      json['id'] is! String ||
      json['projectId'] is! String ||
      json['name'] is! String ||
      json['createdAt'] is! String) {
    throw const FormatException('not a checkout');
  }
  return Repository(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    name: json['name'] as String,
    path: environmentPathFromJson(json['path']),
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    canonicalId: json['canonicalId'] as String?,
  );
}

Map<String, Object?> discoveredToJson(DiscoveredRepository found) => {
  'name': found.name,
  'path': environmentPathToJson(found.path),
};

DiscoveredRepository discoveredFromJson(Object? json) {
  if (json is! Map || json['name'] is! String) {
    throw const FormatException('not a discovered checkout');
  }
  return DiscoveredRepository(
    name: json['name'] as String,
    path: environmentPathFromJson(json['path']),
  );
}
