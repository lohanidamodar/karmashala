part of '../data_request.dart';

/// The whole workspace domain: contexts, projects, checkouts, sections.
final class WorkspaceList extends DataRequest<WorkspaceSnapshot> {
  const WorkspaceList();

  static const String name = 'workspace.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(WorkspaceSnapshot result) => result.toJson();

  @override
  WorkspaceSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => WorkspaceSnapshot.fromJson(_object(json, kind)));
}

/// Keeps a context under the client's [id]: created when it is new, its name
/// and description rewritten when not (a blank description clears it).
/// Refused [DataRefusalCode.invalid] for a blank name or one another context
/// already has, whatever the case.
final class WorkspacePut extends _WorkspaceWrite {
  const WorkspacePut({
    required this.id,
    required this.workspaceName,
    this.description,
  });

  static const String name = 'workspaces.put';

  final String id;
  final String workspaceName;
  final String? description;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'name': workspaceName,
    'description': ?description,
  };
}

/// A context's colour by name, or none.
final class WorkspaceSetColor extends _WorkspaceWrite {
  const WorkspaceSetColor({required this.id, this.color});

  static const String name = 'workspaces.setColor';

  final String id;
  final String? color;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'color': ?color};
}

/// Deletes a context. Its projects are kept, unassigned — told as changes.
final class WorkspaceDelete extends _AckRequest {
  const WorkspaceDelete(this.id);

  static const String name = 'workspaces.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// Records a project called [projectName] at [root], filed under
/// [workspaceId], with what discovery [found] under it as its checkouts — or
/// its root, with nothing found. The server names the rows.
final class ProjectCreate extends DataRequest<ProjectCheckouts> {
  const ProjectCreate({
    required this.projectName,
    required this.root,
    this.workspaceId,
    this.found = const [],
    this.projectKind,
  });

  factory ProjectCreate._from(_Arguments args) => ProjectCreate(
    projectName: args.string('name'),
    root: args.value('root', environmentPathFromJson),
    workspaceId: args.optionalString('workspaceId'),
    found: args.found(),
    projectKind: args.optionalString('projectKind'),
  );

  static const String name = 'projects.create';

  final String projectName;
  final EnvironmentPath root;
  final String? workspaceId;
  final List<DiscoveredRepository> found;

  /// `Project.kind` of the new row; null makes an ordinary project.
  final String? projectKind;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'name': projectName,
    'root': environmentPathToJson(root),
    'workspaceId': ?workspaceId,
    'found': [for (final f in found) discoveredToJson(f)],
    'projectKind': ?projectKind,
  };

  @override
  Object? resultToJson(ProjectCheckouts result) => result.toJson();

  @override
  ProjectCheckouts resultFromJson(Object? json) =>
      _decode(kind, () => ProjectCheckouts.fromJson(_object(json, kind)));
}

/// Edits a project: its name, the checkout its one-click session runs in
/// (one it does not own falls back to none), and where its root is. A moved
/// root carries every checkout under it across, keeping their ids, and adds
/// what discovery [found] under the new root.
final class ProjectUpdate extends DataRequest<ProjectUpdated> {
  const ProjectUpdate({
    required this.id,
    this.projectName,
    this.root,
    this.defaultRepositoryId,
    this.clearDefaultRepository = false,
    this.found = const [],
  });

  factory ProjectUpdate._from(_Arguments args) => ProjectUpdate(
    id: args.string('id'),
    projectName: args.optionalString('name'),
    root: args.values['root'] == null
        ? null
        : args.value('root', environmentPathFromJson),
    defaultRepositoryId: args.optionalString('defaultRepositoryId'),
    clearDefaultRepository: args.boolean('clearDefault', orElse: false),
    found: args.found(),
  );

  static const String name = 'projects.update';

  final String id;
  final String? projectName;
  final EnvironmentPath? root;
  final String? defaultRepositoryId;
  final bool clearDefaultRepository;
  final List<DiscoveredRepository> found;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'name': ?projectName,
    if (root case final root?) 'root': environmentPathToJson(root),
    'defaultRepositoryId': ?defaultRepositoryId,
    'clearDefault': clearDefaultRepository,
    'found': [for (final f in found) discoveredToJson(f)],
  };

  @override
  Object? resultToJson(ProjectUpdated result) => result.toJson();

  @override
  ProjectUpdated resultFromJson(Object? json) =>
      _decode(kind, () => ProjectUpdated.fromJson(_object(json, kind)));
}

/// Files each project of [placements] under its context, or unassigns it
/// (null), in one transaction.
final class ProjectsFile extends _AckRequest {
  const ProjectsFile(this.placements);

  static const String name = 'projects.file';

  final Map<String, String?> placements;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'placements': placements};
}

/// Deletes a project, and with it its checkouts and everything recorded
/// against them; its notes and todos are kept, unfiled — all told as changes.
final class ProjectDelete extends _AckRequest {
  const ProjectDelete(this.id);

  static const String name = 'projects.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// The names of the projects that keep an environment from being removed:
/// rooted there, with a checkout there, or with a session run by an agent
/// installed there. Sorted.
final class ProjectsUsingEnvironment extends DataRequest<List<String>> {
  const ProjectsUsingEnvironment(this.environmentId);

  static const String name = 'projects.usingEnvironment';

  final String environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'environmentId': environmentId};

  @override
  Object? resultToJson(List<String> result) => result;

  @override
  List<String> resultFromJson(Object? json) =>
      _decode(kind, () => (json! as List).cast<String>().toList());
}

/// Records each of [found] the project does not have yet (by where it is),
/// and — with [orRoot], when it would still have nowhere to run — its root.
/// Answers the checkouts added.
final class CheckoutsAdd extends _CheckoutsRequest {
  const CheckoutsAdd({
    required this.projectId,
    this.found = const [],
    this.orRoot = true,
  });

  static const String name = 'repositories.add';

  final String projectId;
  final List<DiscoveredRepository> found;
  final bool orRoot;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'projectId': projectId,
    'found': [for (final f in found) discoveredToJson(f)],
    'orRoot': orRoot,
  };
}

/// Deletes the checkouts of [ids] that nothing recorded points at. Answers,
/// per id, how many records kept it — 0 for one that went.
final class CheckoutsRetire extends DataRequest<Map<String, int>> {
  const CheckoutsRetire(this.ids);

  static const String name = 'repositories.retire';

  final List<String> ids;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'ids': ids};

  @override
  Object? resultToJson(Map<String, int> result) => result;

  @override
  Map<String, int> resultFromJson(Object? json) =>
      _decode(kind, () => (json! as Map).cast<String, int>());
}

/// Records [canonicalId] — what `origin` says — on every checkout whose
/// working tree is [path]. Answers the checkouts that changed.
final class CheckoutsIdentify extends _CheckoutsRequest {
  const CheckoutsIdentify({required this.path, this.canonicalId});

  static const String name = 'repositories.identify';

  final EnvironmentPath path;
  final String? canonicalId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'path': environmentPathToJson(path),
    'canonicalId': ?canonicalId,
  };
}

/// Keeps a saved section whole — created or rewritten. Refused for a blank
/// name, and for a change to the built-in Pinned section beyond folding it.
final class SectionPut extends DataRequest<StoredSection> {
  const SectionPut(this.section);

  static const String name = 'sections.put';

  final StoredSection section;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'section': section.toJson()};

  @override
  Object? resultToJson(StoredSection result) => result.toJson();

  @override
  StoredSection resultFromJson(Object? json) =>
      _decode(kind, () => StoredSection.fromJson(_object(json, kind)));
}

/// Renumbers the sections in the order [ids] gives; answers every section.
final class SectionsReorder extends DataRequest<List<StoredSection>> {
  const SectionsReorder(this.ids);

  static const String name = 'sections.reorder';

  final List<String> ids;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'ids': ids};

  @override
  Object? resultToJson(List<StoredSection> result) => [
    for (final section in result) section.toJson(),
  ];

  @override
  List<StoredSection> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final item in _objects(json, kind)) StoredSection.fromJson(item),
    ];
  });
}

/// Deletes a saved section; the Pinned one is refused.
final class SectionDelete extends _AckRequest {
  const SectionDelete(this.id);

  static const String name = 'sections.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// A request answered with the context it wrote.
sealed class _WorkspaceWrite extends DataRequest<Workspace> {
  const _WorkspaceWrite();

  @override
  Object? resultToJson(Workspace result) => result.toJson();

  @override
  Workspace resultFromJson(Object? json) =>
      _decode(kind, () => Workspace.fromJson(_object(json, kind)));
}

/// A request answered with the checkouts it wrote.
sealed class _CheckoutsRequest extends DataRequest<List<Repository>> {
  const _CheckoutsRequest();

  @override
  Object? resultToJson(List<Repository> result) => [
    for (final repository in result) repositoryToJson(repository),
  ];

  @override
  List<Repository> resultFromJson(Object? json) => _decode(kind, () {
    return [for (final item in _objects(json, kind)) repositoryFromJson(item)];
  });
}

/// A change answered with nothing more.
sealed class _AckRequest extends DataRequest<DataAck> {
  const _AckRequest();

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
