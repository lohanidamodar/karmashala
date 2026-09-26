import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';

/// Everything in the workspace domain, as one snapshot: the contexts, the
/// projects, their checkouts and the saved Explorer sections.
final class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    this.workspaces = const [],
    this.projects = const [],
    this.repositories = const [],
    this.sections = const [],
  });

  final List<Workspace> workspaces;
  final List<Project> projects;
  final List<Repository> repositories;
  final List<StoredSection> sections;

  Map<String, Object?> toJson() => {
    'workspaces': [for (final w in workspaces) w.toJson()],
    'projects': [for (final p in projects) p.toJson()],
    'repositories': [for (final r in repositories) repositoryToJson(r)],
    'sections': [for (final s in sections) s.toJson()],
  };

  static WorkspaceSnapshot fromJson(Map<String, Object?> json) =>
      WorkspaceSnapshot(
        workspaces: _list(json['workspaces'], Workspace.fromJson),
        projects: _list(json['projects'], Project.fromJson),
        repositories: _list(json['repositories'], repositoryFromJson),
        sections: _list(json['sections'], StoredSection.fromJson),
      );
}

/// A project as written, with the checkouts it was given.
final class ProjectCheckouts {
  const ProjectCheckouts(this.project, this.repositories);

  final Project project;
  final List<Repository> repositories;

  Map<String, Object?> toJson() => {
    'project': project.toJson(),
    'repositories': [for (final r in repositories) repositoryToJson(r)],
  };

  static ProjectCheckouts fromJson(Map<String, Object?> json) =>
      ProjectCheckouts(
        Project.fromJson(_map(json['project'])),
        _list(json['repositories'], repositoryFromJson),
      );
}

/// What editing a project did. [rebased] and [leftBehind] are only ever
/// non-empty when the root moved.
final class ProjectUpdated {
  const ProjectUpdated({
    required this.project,
    this.rebased = const [],
    this.leftBehind = const [],
    this.discovered = const [],
  });

  final Project project;

  /// Checkouts whose recorded path was rewritten under the new root — the same
  /// rows, keeping their ids, so every session that references one still does.
  final List<Repository> rebased;

  /// Checkouts that were not under the old root, reported rather than guessed.
  final List<Repository> leftBehind;

  /// Checkouts found under the new root that the project did not have.
  final List<Repository> discovered;

  Map<String, Object?> toJson() => {
    'project': project.toJson(),
    'rebased': [for (final r in rebased) repositoryToJson(r)],
    'leftBehind': [for (final r in leftBehind) repositoryToJson(r)],
    'discovered': [for (final r in discovered) repositoryToJson(r)],
  };

  static ProjectUpdated fromJson(Map<String, Object?> json) => ProjectUpdated(
    project: Project.fromJson(_map(json['project'])),
    rebased: _list(json['rebased'], repositoryFromJson),
    leftBehind: _list(json['leftBehind'], repositoryFromJson),
    discovered: _list(json['discovered'], repositoryFromJson),
  );
}

Map<String, Object?> _map(Object? json) => json is Map
    ? json.cast<String, Object?>()
    : throw const FormatException('expected an object');

List<T> _list<T>(Object? json, T Function(Map<String, Object?>) read) =>
    json is List
    ? [for (final item in json) read(_map(item))]
    : throw const FormatException('expected a list');
