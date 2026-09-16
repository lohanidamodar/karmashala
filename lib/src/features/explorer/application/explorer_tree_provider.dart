import 'package:agent_cli/process.dart';
import 'package:flutter/foundation.dart' show immutable, listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/session.dart';

import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/domain/project.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_last_active_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../workspaces/application/workspaces_controller.dart';
import 'checkout.dart';
import 'environment_terminals_providers.dart';
import 'explorer_agent_filter.dart';
import 'explorer_tree_nodes.dart';
import 'explorer_tree_state.dart';
import 'project_tree.dart';
import 'session_forest.dart';

/// The Explorer's rows, compared by value so a recompute that changed nothing
/// the tree draws — a status tick, a pane's liveness — rebuilds no panel.
@immutable
class ExplorerTree {
  const ExplorerTree(this.nodes);

  final List<ExplorerNode> nodes;

  @override
  bool operator ==(Object other) =>
      other is ExplorerTree && listEquals(other.nodes, nodes);

  @override
  int get hashCode => Object.hashAll(nodes);
}

/// Projects matching the search field, in the sidebar's order.
final explorerFilteredProjectsProvider = Provider<List<Project>>((ref) {
  final all = ref.watch(sortedProjectsProvider);
  final query = ref.watch(explorerSearchQueryProvider).trim().toLowerCase();
  if (query.isEmpty) return all;
  return [
    for (final p in all)
      if (p.name.toLowerCase().contains(query) ||
          p.root.path.toLowerCase().contains(query))
        p,
  ];
});

/// Native sessions of one project by id, so a row can select its own and
/// rebuild alone when only that session moved.
final explorerProjectNativeSessionsProvider = Provider.autoDispose
    .family<Map<String, Session>, String>((ref, projectId) {
      final sessions = ref.watch(projectSessionsProvider(projectId));
      return {for (final session in sessions.native) session.id: session};
    });

/// **The Explorer's shape.** Everything the tree watches lives here, so the
/// panel watches one value instead of every reading behind it.
final explorerTreeProvider = Provider.autoDispose<ExplorerTree>((ref) {
  final query = ref.watch(explorerSearchQueryProvider).trim();
  final expandedTerminals = ref.watch(explorerExpandedTerminalsProvider);
  // Selected rather than watched whole: an unrelated settings write — a pane
  // width, a theme — must not rebuild the tree.
  final collapsed = ref
      .watch(settingsControllerProvider.select((s) => s.collapsedExplorerNodes))
      .toSet();

  int? terminalCount(String environmentId) =>
      expandedTerminals.contains(environmentId)
      ? ref.watch(environmentTerminalsProvider(environmentId)).runningCount
      : null;

  String? terminalDetail(String environmentId) {
    if (!expandedTerminals.contains(environmentId)) return null;
    final reading = ref.watch(environmentTerminalsProvider(environmentId));
    if (reading.busy) return 'asking…';
    final readAt = reading.readAt;
    if (readAt == null) return null;
    final age = ref.read(clockProvider).nowUtc().difference(readAt);
    return 'read ${describeAge(age)}';
  }

  return ExplorerTree(
    buildExplorerTree(
      projects: ref.watch(explorerFilteredProjectsProvider),
      environments: ref.watch(executionEnvironmentDaoProvider).getAll(),
      contexts: ref.watch(workspacesControllerProvider),
      collapsed: collapsed,
      expandedProjects: ref.watch(explorerExpandedProjectsProvider),
      expandedTerminals: expandedTerminals,
      // A machine holding nothing is worth a row; a machine holding nothing
      // that *matches a search* is noise.
      includeEmptyEnvironments: query.isEmpty,
      childrenOf: (node) => _projectChildren(ref, node),
      terminalsOf: (node) => _terminalNodes(ref, node),
      terminalCountOf: terminalCount,
      terminalDetailOf: terminalDetail,
    ),
  );
});

List<ExplorerNode> _terminalNodes(Ref ref, EnvironmentNode node) {
  final reading = ref.watch(environmentTerminalsProvider(node.environmentId));
  if (reading.problem case final String problem) {
    return [
      HintNode(id: '${node.id}/terminals/problem', depth: 2, message: problem),
    ];
  }
  if (!reading.asked) {
    return [
      HintNode(
        id: '${node.id}/terminals/asking',
        depth: 2,
        message: 'Asking this machine what it is running…',
      ),
    ];
  }
  if (reading.terminals.isEmpty) {
    return [
      HintNode(
        id: '${node.id}/terminals/empty',
        depth: 2,
        message: 'Nothing is running here.',
      ),
    ];
  }
  return [
    for (final terminal in reading.terminals)
      TerminalRowNode(environmentId: node.environmentId, terminal: terminal),
  ];
}

/// Everything under one expanded project. Asked by the tree only for an open
/// project, so a closed one costs neither indexed read below.
List<ExplorerNode> _projectChildren(Ref ref, ProjectNode node) {
  final project = node.project;
  final depth = node.depth + 1;
  // No git at any depth: the checkouts a session works in are the right
  // sidebar's subject now, not a row here.
  final visible = ref.watch(visibleProjectSessionsProvider(project.id));
  final sessions = visible.sessions;
  if (sessions.isEmpty) {
    return [
      HintNode(
        id: 'hint-empty:${project.id}',
        depth: depth,
        // Never "no sessions yet" over sessions the filter took away: that
        // invites the user to start work they already have.
        message: visible.hidden == 0
            // Before the first-frame import lands nobody has read the CLI
            // stores, so "no sessions yet" would be a claim about nothing.
            ? ref.watch(cliSessionsCheckedProvider).forProject(project.id) ==
                      null
                  ? 'No sessions yet — the CLI stores have not been checked.'
                  : 'No sessions yet — start one with the + on this project.'
            : '${_sessionCount(visible.hidden)} hidden by the agent filter.',
      ),
    ];
  }
  return [
    ..._sessionNodes(ref, project, sessions, depth: depth),
    // Said where the rows are missing, and only while a narrowing is in
    // force: a partly-filtered list looks exactly like a shorter one.
    if (visible.hidden > 0)
      HintNode(
        id: 'hint-hidden:${project.id}',
        depth: depth,
        message: '${visible.hidden} more hidden by the agent filter.',
      ),
  ];
}

String _sessionCount(int n) => '$n session${n == 1 ? '' : 's'}';

/// Native sessions arranged parent-and-child, imported conversations
/// interleaved by when they were last touched.
List<ExplorerNode> _sessionNodes(
  Ref ref,
  Project project,
  CheckoutSessions sessions, {
  required int depth,
}) {
  if (sessions.isEmpty) return const [];
  // Read once for the project, never per row — `session_switch_cost_test`.
  final repositoryPaths = <String, EnvironmentPath>{
    for (final repository
        in ref.read(repositoryDaoProvider).getByProject(project.id))
      repository.id: repository.path,
  };
  final pinnedIds = ref
      .watch(settingsControllerProvider.select((s) => s.pinnedSessionIds))
      .toSet();
  final lastActiveOf = ref.read(sessionLastActiveProvider);
  final forest = buildSessionForest(
    sessions.native,
    isPinned: pinnedIds.contains,
    lastActive: lastActiveOf.call,
  );

  // Pinned first, then whatever is running in Karmashala right now, then most
  // recently active — applied to the *top* of each lineage so a child never
  // floats above the session it came from.
  final entries =
      <
          ({
            SessionActivityOrder order,
            bool pinned,
            bool live,
            List<ExplorerNode> rows,
          })
        >[
          for (final node in forest)
            (
              order: (
                lastActive: lastActiveOf(node.session.id),
                createdAt: node.session.createdAt,
              ),
              pinned: pinnedIds.contains(node.session.id),
              live: _hasLivePane(ref, node.session),
              rows: _lineageNodes(
                project,
                node,
                depth: depth,
                parent: null,
                repositoryPaths: repositoryPaths,
                pinnedIds: pinnedIds,
              ),
            ),
          for (final imported in sessions.imported)
            (
              order: (
                lastActive: lastActiveOf(
                  imported.id,
                  storeModifiedAt: imported.updatedAt,
                ),
                createdAt: imported.createdAt,
              ),
              pinned: pinnedIds.contains(imported.id),
              // A file on disk; nothing here runs it, so it never outranks one
              // this app is hosting.
              live: false,
              rows: [
                ImportedRowNode(
                  projectId: project.id,
                  session: imported,
                  depth: depth + (imported.isSubagent ? 1 : 0),
                  subPath: switch (repositoryPaths[imported.repositoryId]) {
                    final path? => relativeSubPath(project.root, path),
                    null => null,
                  },
                  pinned: pinnedIds.contains(imported.id),
                ),
              ],
            ),
        ]
        ..sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          if (a.live != b.live) return a.live ? -1 : 1;
          return compareByLastActive(a.order, b.order);
        });
  return [for (final entry in entries) ...entry.rows];
}

/// Whether a pane of ours runs [session] now. A session with no pane recorded
/// cannot be live, so it costs no watch at all.
bool _hasLivePane(Ref ref, Session session) {
  final paneId = session.paneId;
  if (paneId == null) return false;
  return ref.watch(terminalPaneLivenessProvider(paneId)).isLive;
}

List<ExplorerNode> _lineageNodes(
  Project project,
  SessionNode node, {
  required int depth,
  required Session? parent,
  required Map<String, EnvironmentPath> repositoryPaths,
  required Set<String> pinnedIds,
}) {
  final directory =
      node.session.worktree ?? repositoryPaths[node.session.repositoryId];
  return [
    SessionRowNode(
      projectId: project.id,
      session: node.session,
      depth: depth,
      subPath: directory == null
          ? null
          : relativeSubPath(project.root, directory),
      pinned: pinnedIds.contains(node.session.id),
      link: node.link,
      parentTitle: parent?.title,
      lineageBroken: node.lineageBroken,
    ),
    for (final child in node.children)
      ..._lineageNodes(
        project,
        child,
        depth: depth + 1,
        parent: node.session,
        repositoryPaths: repositoryPaths,
        pinnedIds: pinnedIds,
      ),
  ];
}
