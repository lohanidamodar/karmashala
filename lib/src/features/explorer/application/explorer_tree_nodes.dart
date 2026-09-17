import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/rows.dart' show abbreviatePath;

import '../../projects/domain/project.dart';
import '../../workspaces/domain/workspace.dart';
import 'environment_grouping.dart';
import 'environment_terminals.dart';

/// One row of the Explorer, as a value rather than a widget. The panel
/// inflates only the rows on screen, so a node carries what its row draws and
/// nothing it has to go and ask for.
sealed class ExplorerNode {
  const ExplorerNode({required this.id, required this.depth});

  /// Stable across rebuilds: the row's widget key, and for a collapsible row
  /// the id held in `Settings.collapsedExplorerNodes`.
  final String id;

  final int depth;
}

/// A machine. Drawn even when it holds nothing — it is where a terminal is
/// opened, and an absent row would say the machine is not there (§19).
final class EnvironmentNode extends ExplorerNode {
  EnvironmentNode({
    required this.environmentId,
    required this.environment,
    required this.projectCount,
    required this.expanded,
  }) : super(id: 'env:$environmentId', depth: 0);

  final String environmentId;

  /// Null when a project names an environment the workspace no longer has.
  /// Shown as the bare id rather than folded into this machine.
  final ExecutionEnvironment? environment;

  final int projectCount;
  final bool expanded;

  String get label => environment?.name ?? environmentId;
  EnvironmentKind? get kind => environment?.kind;

  @override
  bool operator ==(Object other) =>
      other is EnvironmentNode &&
      other.environmentId == environmentId &&
      other.environment == environment &&
      other.projectCount == projectCount &&
      other.expanded == expanded;

  @override
  int get hashCode =>
      Object.hash(environmentId, environment, projectCount, expanded);
}

enum EnvironmentSection {
  projects,
  terminals;

  String get slug => name;
  String get label => this == projects ? 'Projects' : 'Terminals';
}

/// `Projects` or `Terminals` under one machine.
final class EnvironmentSectionNode extends ExplorerNode {
  EnvironmentSectionNode({
    required this.environmentId,
    required this.section,
    required this.expanded,
    this.count,
    this.detail,
  }) : super(id: 'env:$environmentId/${section.name}', depth: 1);

  final String environmentId;
  final EnvironmentSection section;
  final bool expanded;

  /// How many the section holds, or **null for not asked**. A terminals
  /// section that has not dialled must not read as empty (§19).
  final int? count;

  /// The muted line on the right — an age, a refusal. Null where there is
  /// nothing measured to say.
  final String? detail;

  String get label => section.label;

  @override
  bool operator ==(Object other) =>
      other is EnvironmentSectionNode &&
      other.environmentId == environmentId &&
      other.section == section &&
      other.expanded == expanded &&
      other.count == count &&
      other.detail == detail;

  @override
  int get hashCode =>
      Object.hash(environmentId, section, expanded, count, detail);
}

/// A context, inside the machine its projects run on. One spanning two
/// machines is drawn under each: that is the truth, not a duplicate.
final class ContextNode extends ExplorerNode {
  ContextNode({
    required this.environmentId,
    required this.workspace,
    required this.projectCount,
    required this.expanded,
  }) : super(id: 'env:$environmentId/ctx:${workspace.id}', depth: 2);

  final String environmentId;
  final Workspace workspace;
  final int projectCount;
  final bool expanded;

  String get label => workspace.name;

  @override
  bool operator ==(Object other) =>
      other is ContextNode &&
      other.environmentId == environmentId &&
      other.workspace == workspace &&
      other.projectCount == projectCount &&
      other.expanded == expanded;

  @override
  int get hashCode =>
      Object.hash(environmentId, workspace, projectCount, expanded);
}

/// A project, at depth 2 loose under its machine or 3 inside a context.
final class ProjectNode extends ExplorerNode {
  ProjectNode({
    required this.project,
    required this.expanded,
    required super.depth,
    this.environmentBadge,
  }) : pathCandidates = _abbreviated(project.root.path),
       super(id: 'project:${project.id}');

  final Project project;
  final bool expanded;

  /// The project's path as its row may shorten it, longest first — cut here,
  /// once, so no build of the row cuts it again.
  final List<String> pathCandidates;

  /// The machine, for the path's tooltip. The row draws no badge: it already
  /// stands under its machine's row.
  final String? environmentBadge;

  @override
  bool operator ==(Object other) =>
      other is ProjectNode &&
      other.project == project &&
      other.expanded == expanded &&
      other.depth == depth &&
      other.environmentBadge == environmentBadge;

  @override
  int get hashCode => Object.hash(project, expanded, depth, environmentBadge);
}

/// A tree is rebuilt whole on every fold, and a path cuts to the same strings
/// every time. Bounded: a workspace that outgrows it starts over.
final _abbreviations = <String, List<String>>{};

List<String> _abbreviated(String path) {
  if (_abbreviations.length > 4096) _abbreviations.clear();
  return _abbreviations[path] ??= List.unmodifiable(abbreviatePath(path));
}

/// A session started here, under the project it belongs to.
final class SessionRowNode extends ExplorerNode {
  SessionRowNode({
    required super.depth,
    required this.projectId,
    required this.session,
    this.subPath,
    this.pinned = false,
    this.link,
    this.parentTitle,
    this.lineageBroken = false,
  }) : super(id: 'session:${session.id}');

  final String projectId;
  final Session session;

  /// Where inside the project this session works, when that is not the root.
  final String? subPath;
  final bool pinned;

  /// Why this session names a parent — spawned, handed off, forked.
  final SessionLink? link;
  final String? parentTitle;
  final bool lineageBroken;

  @override
  bool operator ==(Object other) =>
      other is SessionRowNode &&
      other.depth == depth &&
      other.projectId == projectId &&
      other.session.id == session.id &&
      other.subPath == subPath &&
      other.pinned == pinned &&
      other.link == link &&
      other.parentTitle == parentTitle &&
      other.lineageBroken == lineageBroken;

  @override
  int get hashCode => Object.hash(
    depth,
    projectId,
    session.id,
    subPath,
    pinned,
    link,
    parentTitle,
    lineageBroken,
  );
}

/// A conversation read out of a CLI's own store rather than started here.
final class ImportedRowNode extends ExplorerNode {
  ImportedRowNode({
    required super.depth,
    required this.projectId,
    required this.session,
    this.subPath,
    this.pinned = false,
  }) : super(id: 'imported:${session.id}');

  final String projectId;
  final ImportedSession session;
  final String? subPath;
  final bool pinned;

  @override
  bool operator ==(Object other) =>
      other is ImportedRowNode &&
      other.depth == depth &&
      other.projectId == projectId &&
      other.subPath == subPath &&
      other.pinned == pinned &&
      _sameImported(other.session, session);

  @override
  int get hashCode =>
      Object.hash(depth, projectId, session.id, subPath, pinned);
}

/// Field by field: [ImportedSession] has no `==`, and every re-read is a new
/// instance, so identity would call every recompute a change.
bool _sameImported(ImportedSession a, ImportedSession b) =>
    a.id == b.id &&
    a.repositoryId == b.repositoryId &&
    a.cli == b.cli &&
    a.externalId == b.externalId &&
    a.environmentId == b.environmentId &&
    a.filePath == b.filePath &&
    a.storeHome == b.storeHome &&
    a.isSubagent == b.isSubagent &&
    a.title == b.title &&
    a.preview == b.preview &&
    a.updatedAt == b.updatedAt &&
    a.createdAt == b.createdAt;

/// One row under a machine's `Terminals`.
final class TerminalRowNode extends ExplorerNode {
  TerminalRowNode({required this.environmentId, required this.terminal})
    : super(id: 'terminal:$environmentId:${terminal.id}', depth: 2);

  final String environmentId;
  final EnvironmentTerminal terminal;

  @override
  bool operator ==(Object other) =>
      other is TerminalRowNode &&
      other.environmentId == environmentId &&
      other.terminal.id == terminal.id &&
      other.terminal.label == terminal.label &&
      other.terminal.running == terminal.running &&
      other.terminal.paneId == terminal.paneId &&
      other.terminal.hostSessionId == terminal.hostSessionId;

  @override
  int get hashCode =>
      Object.hash(environmentId, terminal.id, terminal.label, terminal.running);
}

/// A line of prose at [depth] — "nothing here yet", "could not look".
final class HintNode extends ExplorerNode {
  HintNode({required super.id, required super.depth, required this.message});

  final String message;

  @override
  bool operator ==(Object other) =>
      other is HintNode &&
      other.id == id &&
      other.depth == depth &&
      other.message == message;

  @override
  int get hashCode => Object.hash(id, depth, message);
}

/// The collapse ids that must be open for a project on [environmentId] — and
/// filed under [workspaceId], when it is — to be drawn at all.
///
/// One spelling of these strings: a reveal that built them itself would drift
/// from the tree that reads them, and the row would stay hidden.
List<String> explorerAncestorsOf({
  required String environmentId,
  String? workspaceId,
}) => [
  'env:$environmentId',
  'env:$environmentId/${EnvironmentSection.projects.name}',
  if (workspaceId != null) 'env:$environmentId/ctx:$workspaceId',
];

/// **The Explorer's shape, as a flat list.** Machine, then its `Projects` and
/// `Terminals`, then contexts before loose projects — each row appearing only
/// when everything above it is expanded, so the list is exactly what is drawn.
///
/// [childrenOf] and [terminalsOf] are asked **only for an expanded node**,
/// which is what keeps a collapsed machine free of both a session query and a
/// dial.
List<ExplorerNode> buildExplorerTree({
  required List<Project> projects,
  required List<ExecutionEnvironment> environments,
  required List<Workspace> contexts,
  required Set<String> collapsed,
  required Set<String> expandedProjects,
  Set<String> expandedTerminals = const {},
  List<ExplorerNode> Function(ProjectNode node)? childrenOf,
  List<ExplorerNode> Function(EnvironmentNode node)? terminalsOf,
  int? Function(String environmentId)? terminalCountOf,
  String? Function(String environmentId)? terminalDetailOf,
  bool includeEmptyEnvironments = true,
}) {
  final contextsById = {for (final context in contexts) context.id: context};
  final nodes = <ExplorerNode>[];

  for (final group in groupProjectsByEnvironment(
    projects,
    environments,
    includeEmpty: includeEmptyEnvironments,
  )) {
    final environment = EnvironmentNode(
      environmentId: group.environmentId,
      environment: group.environment,
      projectCount: group.projects.length,
      expanded: !collapsed.contains('env:${group.environmentId}'),
    );
    nodes.add(environment);
    if (!environment.expanded) continue;

    nodes.addAll(
      _projectsSection(
        group: group,
        contextsById: contextsById,
        collapsed: collapsed,
        expandedProjects: expandedProjects,
        childrenOf: childrenOf,
      ),
    );

    final terminals = EnvironmentSectionNode(
      environmentId: group.environmentId,
      section: EnvironmentSection.terminals,
      // Not from [collapsed], and deliberately not persisted: opening this
      // dials a machine, and a fold restored at launch would dial every host
      // on the first frame (§19).
      expanded: expandedTerminals.contains(group.environmentId),
      count: terminalCountOf?.call(group.environmentId),
      detail: terminalDetailOf?.call(group.environmentId),
    );
    nodes.add(terminals);
    if (terminals.expanded && terminalsOf != null) {
      nodes.addAll(terminalsOf(environment));
    }
  }
  return nodes;
}

List<ExplorerNode> _projectsSection({
  required EnvironmentGroup group,
  required Map<String, Workspace> contextsById,
  required Set<String> collapsed,
  required Set<String> expandedProjects,
  List<ExplorerNode> Function(ProjectNode node)? childrenOf,
}) {
  final section = EnvironmentSectionNode(
    environmentId: group.environmentId,
    section: EnvironmentSection.projects,
    expanded: !collapsed.contains('env:${group.environmentId}/projects'),
    count: group.projects.length,
  );
  final nodes = <ExplorerNode>[section];
  if (!section.expanded) return nodes;
  final badge = switch (group.environment) {
    final ExecutionEnvironment environment => environmentBadge(environment),
    null => null,
  };
  if (group.projects.isEmpty) {
    nodes.add(
      HintNode(
        id: 'env:${group.environmentId}/projects/empty',
        depth: 2,
        message: 'No projects on this machine yet.',
      ),
    );
    return nodes;
  }

  // A project whose context row has gone reads as loose rather than vanishing.
  final filed = <String, List<Project>>{};
  final loose = <Project>[];
  for (final project in group.projects) {
    final context = project.workspaceId;
    if (context != null && contextsById.containsKey(context)) {
      filed.putIfAbsent(context, () => []).add(project);
    } else {
      loose.add(project);
    }
  }

  // Contexts before loose projects, the way folders sort above files.
  final ordered = filed.keys.toList()
    ..sort(
      (a, b) => contextsById[a]!.name.toLowerCase().compareTo(
        contextsById[b]!.name.toLowerCase(),
      ),
    );
  for (final id in ordered) {
    final context = ContextNode(
      environmentId: group.environmentId,
      workspace: contextsById[id]!,
      projectCount: filed[id]!.length,
      expanded: !collapsed.contains('env:${group.environmentId}/ctx:$id'),
    );
    nodes.add(context);
    if (!context.expanded) continue;
    for (final project in filed[id]!) {
      nodes.addAll(
        _project(
          project,
          depth: 3,
          environmentBadge: badge,
          expandedProjects: expandedProjects,
          childrenOf: childrenOf,
        ),
      );
    }
  }
  for (final project in loose) {
    nodes.addAll(
      _project(
        project,
        depth: 2,
        environmentBadge: badge,
        expandedProjects: expandedProjects,
        childrenOf: childrenOf,
      ),
    );
  }
  return nodes;
}

List<ExplorerNode> _project(
  Project project, {
  required int depth,
  required String? environmentBadge,
  required Set<String> expandedProjects,
  required List<ExplorerNode> Function(ProjectNode node)? childrenOf,
}) {
  // Expansion is the panel's, not the collapse set's: a project's tree is
  // session state and is deliberately not persisted.
  final expanded = expandedProjects.contains(project.id);
  final node = ProjectNode(
    project: project,
    expanded: expanded,
    depth: depth,
    environmentBadge: environmentBadge,
  );
  if (!expanded || childrenOf == null) return [node];
  return [node, ...childrenOf(node)];
}
