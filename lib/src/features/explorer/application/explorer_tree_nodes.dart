import 'package:agent_cli/process.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/rows.dart' show abbreviatePath;

import '../../projects/domain/project.dart';
import '../../workspaces/domain/workspace.dart';
import '../../workspaces/domain/workspace_scope.dart';
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

/// One machine the scope bar can narrow the Explorer to, with how many
/// projects run there. Listed even when it holds nothing — it is where a
/// terminal is opened, and leaving it out would say it is not there (§19).
@immutable
final class EnvironmentChoice {
  const EnvironmentChoice({
    required this.environmentId,
    required this.environment,
    required this.projectCount,
  });

  final String environmentId;

  /// Null when a project names an environment the workspace no longer has.
  /// Shown as the bare id rather than folded into this machine.
  final ExecutionEnvironment? environment;

  final int projectCount;

  String get label => environment?.name ?? environmentId;
  EnvironmentKind? get kind => environment?.kind;

  @override
  bool operator ==(Object other) =>
      other is EnvironmentChoice &&
      other.environmentId == environmentId &&
      other.environment == environment &&
      other.projectCount == projectCount;

  @override
  int get hashCode => Object.hash(environmentId, environment, projectCount);
}

/// A sticky group label at depth zero: a context, or a machine's terminals.
/// The rows under it are not indented — the header is a label over the list,
/// not a level of it.
sealed class ExplorerHeaderNode extends ExplorerNode {
  const ExplorerHeaderNode({required super.id, required this.expanded})
    : super(depth: 0);

  final bool expanded;
}

/// A context, over the projects filed in it — or, with no [workspace], over
/// the projects filed nowhere. Drawn only while it holds a project.
final class ContextHeaderNode extends ExplorerHeaderNode {
  ContextHeaderNode({
    required this.workspace,
    required this.projectCount,
    required super.expanded,
  }) : super(id: contextHeaderId(workspace?.id));

  /// Null for the projects in no context.
  final Workspace? workspace;
  final int projectCount;

  String get label => workspace?.name ?? noContextLabel;

  static const noContextLabel = 'No context';

  @override
  bool operator ==(Object other) =>
      other is ContextHeaderNode &&
      other.workspace == workspace &&
      other.projectCount == projectCount &&
      other.expanded == expanded;

  @override
  int get hashCode => Object.hash(workspace, projectCount, expanded);
}

/// What one machine is running, asked for when opened and never before.
final class TerminalsHeaderNode extends ExplorerHeaderNode {
  TerminalsHeaderNode({
    required this.environmentId,
    required this.environment,
    required this.named,
    required super.expanded,
    this.count,
    this.detail,
  }) : super(id: 'env:$environmentId/terminals');

  final String environmentId;
  final ExecutionEnvironment? environment;

  /// Whether the label names its machine — only while the scope bar does not.
  final bool named;

  /// How many are running, or **null for not asked**. A machine that has not
  /// been dialled must not read as idle (§19).
  final int? count;

  /// The muted clause after the label — an age, "asking…".
  final String? detail;

  String get environmentLabel => environment?.name ?? environmentId;

  /// The machine first: it is what tells three of these apart, so it is what
  /// a narrow pane must not cut.
  String get label => named ? '$environmentLabel · Terminals' : 'Terminals';

  @override
  bool operator ==(Object other) =>
      other is TerminalsHeaderNode &&
      other.environmentId == environmentId &&
      other.environment == environment &&
      other.named == named &&
      other.expanded == expanded &&
      other.count == count &&
      other.detail == detail;

  @override
  int get hashCode =>
      Object.hash(environmentId, environment, named, expanded, count, detail);
}

/// A project, at depth zero under its context's header.
final class ProjectNode extends ExplorerNode {
  ProjectNode({
    required this.project,
    required this.expanded,
    super.depth = 0,
    this.environmentBadge,
    this.environmentLabel,
    this.environmentKind,
  }) : pathCandidates = _abbreviated(project.root.path),
       super(id: 'project:${project.id}');

  final Project project;
  final bool expanded;

  /// The project's path as its row may shorten it, longest first — cut here,
  /// once, so no build of the row cuts it again.
  final List<String> pathCandidates;

  /// The machine, for the path's tooltip.
  final String? environmentBadge;

  /// The machine's name, for the row's second line — set only while the scope
  /// bar does not already say it: every machine is listed together, or this
  /// project was kept from another one.
  final String? environmentLabel;
  final EnvironmentKind? environmentKind;

  @override
  bool operator ==(Object other) =>
      other is ProjectNode &&
      other.project == project &&
      other.expanded == expanded &&
      other.depth == depth &&
      other.environmentBadge == environmentBadge &&
      other.environmentLabel == environmentLabel &&
      other.environmentKind == environmentKind;

  @override
  int get hashCode => Object.hash(
    project,
    expanded,
    depth,
    environmentBadge,
    environmentLabel,
    environmentKind,
  );
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
    : super(id: 'terminal:$environmentId:${terminal.id}', depth: 0);

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

/// A context header's collapse id; [workspaceId] null is *No context*.
///
/// One spelling: a reveal that built the string itself would drift from the
/// tree that reads it, and the row would stay hidden.
String contextHeaderId(String? workspaceId) => 'ctx:${workspaceId ?? 'none'}';

/// The collapse ids that must be open for a project filed under
/// [workspaceId] — or under nothing — to be drawn at all.
List<String> explorerAncestorsOf({String? workspaceId}) => [
  contextHeaderId(workspaceId),
];

/// **The Explorer's shape, as a flat list**: contexts by name over their
/// projects, then the projects in none, then each machine's `Terminals`. A row
/// appears only while its header is expanded.
///
/// [projects] is what the search left. [keepProjectId] survives both scopes: a
/// filter must not hide the project the session pane is showing.
/// [childrenOf] and [terminalsOf] are asked only for an expanded node, which
/// keeps a folded group free of both a session query and a dial.
List<ExplorerNode> buildExplorerTree({
  required List<Project> projects,
  required List<EnvironmentChoice> environments,
  required List<Workspace> contexts,
  required Set<String> collapsed,
  required Set<String> expandedProjects,
  Set<String> expandedTerminals = const {},
  String? environmentScope,
  WorkspaceScope contextScope = WorkspaceScope.all,
  String? keepProjectId,
  bool searching = false,
  List<ExplorerNode> Function(ProjectNode node)? childrenOf,
  List<ExplorerNode> Function(TerminalsHeaderNode node)? terminalsOf,
  int? Function(String environmentId)? terminalCountOf,
  String? Function(String environmentId)? terminalDetailOf,
}) {
  final contextsById = {for (final context in contexts) context.id: context};
  final environmentsById = {
    for (final choice in environments) choice.environmentId: choice,
  };
  // The scope bar names the machine, so a row repeats it only when it cannot:
  // every machine is listed together, or the row was kept from another one.
  final severalListed = environmentScope == null && environments.length > 1;
  final nodes = <ExplorerNode>[];

  // A project whose context row has gone reads as loose rather than vanishing.
  String? contextOf(Project project) {
    final id = project.workspaceId;
    return id != null && contextsById.containsKey(id) ? id : null;
  }

  final filed = <String, List<Project>>{};
  final loose = <Project>[];
  for (final project in projects) {
    final context = contextOf(project);
    final inScope =
        (environmentScope == null ||
            project.root.environmentId == environmentScope) &&
        (contextScope.isAll ||
            (contextScope.unassignedOnly
                ? context == null
                : context == contextScope.workspaceId));
    if (!inScope && project.id != keepProjectId) continue;
    if (context == null) {
      loose.add(project);
    } else {
      filed.putIfAbsent(context, () => []).add(project);
    }
  }

  List<ExplorerNode> rows(List<Project> group) => [
    for (final project in group)
      ..._project(
        project,
        environment: environmentsById[project.root.environmentId],
        showEnvironment:
            severalListed ||
            (environmentScope != null &&
                project.root.environmentId != environmentScope),
        expandedProjects: expandedProjects,
        childrenOf: childrenOf,
      ),
  ];

  final ordered = filed.keys.toList()
    ..sort(
      (a, b) => contextsById[a]!.name.toLowerCase().compareTo(
        contextsById[b]!.name.toLowerCase(),
      ),
    );
  for (final id in ordered) {
    final header = ContextHeaderNode(
      workspace: contextsById[id],
      projectCount: filed[id]!.length,
      expanded: !collapsed.contains(contextHeaderId(id)),
    );
    nodes.add(header);
    if (header.expanded) nodes.addAll(rows(filed[id]!));
  }
  if (loose.isNotEmpty) {
    // With no contexts at all there is nothing to tell these apart from, and a
    // header would be a label over the whole list.
    if (contexts.isEmpty) {
      nodes.addAll(rows(loose));
    } else {
      final header = ContextHeaderNode(
        workspace: null,
        projectCount: loose.length,
        expanded: !collapsed.contains(contextHeaderId(null)),
      );
      nodes.add(header);
      if (header.expanded) nodes.addAll(rows(loose));
    }
  }

  // A search is for projects: nothing here could match it.
  if (searching) return nodes;

  if (nodes.isEmpty) {
    nodes.add(
      HintNode(
        id: 'hint-scope-empty',
        depth: 0,
        message: _emptyScopeMessage(
          environment: environmentsById[environmentScope],
          context: contextsById[contextScope.workspaceId],
          unassignedOnly: contextScope.unassignedOnly,
        ),
      ),
    );
  }

  for (final choice in environments) {
    if (environmentScope != null && choice.environmentId != environmentScope) {
      continue;
    }
    final terminals = TerminalsHeaderNode(
      environmentId: choice.environmentId,
      environment: choice.environment,
      named: severalListed,
      // Never from [collapsed], and deliberately not persisted: opening this
      // dials a machine, and a fold restored at launch would dial every host
      // on the first frame (§19).
      expanded: expandedTerminals.contains(choice.environmentId),
      count: terminalCountOf?.call(choice.environmentId),
      detail: terminalDetailOf?.call(choice.environmentId),
    );
    nodes.add(terminals);
    if (terminals.expanded && terminalsOf != null) {
      nodes.addAll(terminalsOf(terminals));
    }
  }
  return nodes;
}

String _emptyScopeMessage({
  required EnvironmentChoice? environment,
  required Workspace? context,
  required bool unassignedOnly,
}) {
  final where = environment == null ? '' : ' on ${environment.label}';
  if (context != null) return 'No projects in ${context.name}$where yet.';
  if (unassignedOnly) return 'Every project$where is in a context.';
  return environment == null
      ? 'No projects yet.'
      : 'No projects on this machine yet.';
}

/// The machines the scope bar lists, in the order a person reads them — see
/// [groupProjectsByEnvironment] — counted over [projects], which is every
/// project rather than what a search left.
List<EnvironmentChoice> environmentChoices(
  List<Project> projects,
  List<ExecutionEnvironment> environments,
) => [
  for (final group in groupProjectsByEnvironment(
    projects,
    environments,
    includeEmpty: true,
  ))
    EnvironmentChoice(
      environmentId: group.environmentId,
      environment: group.environment,
      projectCount: group.projects.length,
    ),
];

List<ExplorerNode> _project(
  Project project, {
  required EnvironmentChoice? environment,
  required bool showEnvironment,
  required Set<String> expandedProjects,
  required List<ExplorerNode> Function(ProjectNode node)? childrenOf,
}) {
  // Expansion is the panel's, not the collapse set's: a project's tree is
  // session state and is deliberately not persisted.
  final expanded = expandedProjects.contains(project.id);
  final node = ProjectNode(
    project: project,
    expanded: expanded,
    environmentBadge: switch (environment?.environment) {
      final ExecutionEnvironment row => environmentBadge(row),
      null => null,
    },
    // A machine whose row is gone is named by its id, never folded into this
    // one.
    environmentLabel: showEnvironment
        ? environment?.label ?? project.root.environmentId
        : null,
    environmentKind: environment?.kind,
  );
  if (!expanded || childrenOf == null) return [node];
  return [node, ...childrenOf(node)];
}
