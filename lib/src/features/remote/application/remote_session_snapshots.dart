/// What a phone is shown about a session: the two snapshot builders and the
/// Explorer-ordered walk that answers `sessions.list`.
///
/// The snapshots are the desktop card's own wording — the agent label, the
/// whereabouts note, the badge, the subtitle — computed here so the phone and
/// the screen beside it cannot describe one session differently.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_registry.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../explorer/application/checkout.dart';
import '../../explorer/application/project_tree.dart';
import '../../explorer/application/session_forest.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/domain/session_attention.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/domain/project.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_resume_providers.dart';
import '../../sessions/domain/session.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/remote_payloads.dart';
import 'remote_attachment_bindings.dart';
import 'remote_binding_support.dart';

/// The delivery-stage lookup, split out so tests can stub the one binding
/// whose production path costs a git/gh probe (`sessionDeliveryProvider` —
/// the same probe the desktop strip pays for a session on screen).
final remoteDeliveryStageProvider =
    Provider<Future<String?> Function(String sessionId)>((ref) {
      return (sessionId) async {
        try {
          final delivery = await ref.read(
            sessionDeliveryProvider(sessionId).future,
          );
          return delivery.stage.name;
        } on Object {
          return null;
        }
      };
    });

/// The whereabouts-and-age lookup behind the list payload, split out like the
/// stage lookup so tests can stub it: production reads
/// [sessionWhereaboutsProvider] — the same value the desktop card reads —
/// whose sources include the terminal grid and the agent status providers.
final remoteSessionPresenceProvider =
    Provider<({String? note, DateTime? lastSeen}) Function(String sessionId)>((
      ref,
    ) {
      return (sessionId) {
        try {
          final whereabouts = ref.read(sessionWhereaboutsProvider(sessionId));
          return (note: whereabouts.note, lastSeen: whereabouts.lastSeen);
        } on Object {
          return (note: null, lastSeen: null);
        }
      };
    });

/// The project a repository belongs to, for the rows the ordered walk did
/// not already know it for (`sessionById`, orphan fallbacks).
Project? _projectOfRepository(Ref ref, String? repositoryId) {
  if (repositoryId == null) return null;
  final repository = ref.read(repositoryDaoProvider).getById(repositoryId);
  if (repository == null) return null;
  return ref.read(projectDaoProvider).getById(repository.projectId);
}

bool _isPinned(Ref ref, String sessionId) =>
    ref.read(settingsControllerProvider).pinnedSessionIds.contains(sessionId);

String? _attentionFor(Ref ref, String sessionId, {bool imported = false}) {
  for (final attention in ref.read(sessionAttentionProvider)) {
    if (attention.session.openId == sessionId &&
        attention.session.imported == imported) {
      return attention.kind == AttentionKind.needsInput
          ? 'needs_approval'
          : 'failed';
    }
  }
  return null;
}

RemoteSessionSnapshot remoteSessionSnapshot(
  Ref ref,
  Session session, {
  Project? project,
}) {
  final repository = ref
      .read(repositoryDaoProvider)
      .getById(session.repositoryId);
  final installation = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId);
  final agentId = installation?.agentId;
  final presence = ref.read(remoteSessionPresenceProvider)(session.id);
  final owner = project ?? _projectOfRepository(ref, session.repositoryId);
  // The directory the agent actually works in — its worktree, else the
  // repository's own path. The same value the Explorer places rows by.
  final directory = session.worktree ?? repository?.path;
  return RemoteSessionSnapshot(
    sessionId: session.id,
    title: session.title,
    status: session.status.name,
    archived: session.isArchived,
    attention: _attentionFor(ref, session.id),
    repositoryId: repository?.id,
    repositoryName: repository?.name,
    createdAt: session.createdAt.toUtc().toIso8601String(),
    // The desktop card's own first line, worded here — never on the phone.
    agentLabel: [
      agentId == null
          ? 'Agent'
          : AgentRegistry.builtIn.displayNameFor(agentId),
      session.status.name,
    ].join('  ·  '),
    whereabouts: presence.note,
    // The desktop's `since`: the agent's own newest evidence, or failing
    // that when the row was created — never the time of our last poll.
    lastActivityAt: (presence.lastSeen ?? session.createdAt)
        .toUtc()
        .toIso8601String(),
    projectId: owner?.id,
    projectName: owner?.name,
    projectPath: owner?.root.path,
    pinned: _isPinned(ref, session.id),
    folderMissing:
        directory != null && ref.read(remoteFolderMissingProvider)(directory),
    // The Explorer row's own subtitle, and the worktree it names.
    subPath: owner == null || directory == null
        ? null
        : relativeSubPath(owner.root, directory),
    worktree: session.worktree?.path,
    branch: directory == null
        ? null
        : ref.read(remoteCheckoutBranchProvider)(directory),
    // The agent's *own* environment, not the checkout's: the executable is
    // what runs, and it is the thing that has to be able to open the path.
    attachments: remoteAttachmentSupportFor(
      ref,
      agentId,
      installation?.executable.environmentId,
    ),
    // The project's environment, as the Explorer card badges it. A session
    // has none of its own, and one with no project has nothing to badge.
    environmentBadge: environmentBadgeFor(ref, owner?.environmentId),
  );
}

RemoteSessionSnapshot remoteImportedSnapshot(
  Ref ref,
  ImportedSession session, {
  Project? project,
}) {
  final repository = ref
      .read(repositoryDaoProvider)
      .getById(session.repositoryId);
  final owner = project ?? _projectOfRepository(ref, session.repositoryId);
  return RemoteSessionSnapshot(
    sessionId: session.id,
    title: session.displayTitle,
    // An older companion renders the raw word as its label — still honest.
    status: 'imported',
    attention: _attentionFor(ref, session.id, imported: true),
    repositoryId: repository?.id,
    repositoryName: repository?.name,
    createdAt: session.createdAt.toUtc().toIso8601String(),
    // The desktop's own imported wording: "Claude Code  ·  imported".
    agentLabel: [
      AgentRegistry.builtIn.displayNameFor(session.cli),
      'imported',
    ].join('  ·  '),
    // The store file's own mtime — the agent's writing, nothing inferred.
    lastActivityAt: session.updatedAt?.toUtc().toIso8601String(),
    imported: true,
    projectId: owner?.id,
    projectName: owner?.name,
    projectPath: owner?.root.path,
    pinned: _isPinned(ref, session.id),
    folderMissing:
        repository != null &&
        ref.read(remoteFolderMissingProvider)(repository.path),
    subPath: owner == null || repository == null
        ? null
        : relativeSubPath(owner.root, repository.path),
    branch: repository == null
        ? null
        : ref.read(remoteCheckoutBranchProvider)(repository.path),
    // Said outright rather than left null: imported history has no process
    // to type into, and a phone that was told nothing would show no reason.
    attachments: const RemoteAttachmentSupport.refused(
      'This is imported history, read-only here — continue it in its own '
      'terminal to attach anything.',
    ),
    environmentBadge: environmentBadgeFor(
      ref,
      owner?.environmentId ?? repository?.path.environmentId,
    ),
  );
}

/// The sessions of one Explorer row, in the order the Explorer draws them:
/// pinned first, then most recently active, with a lineage's children
/// following the session they came from.
List<RemoteSessionSnapshot> _rowSnapshots(
  Ref ref,
  CheckoutSessions sessions,
  Project project,
) {
  if (sessions.isEmpty) return const [];
  final forest = buildSessionForest(
    sessions.native,
    isPinned: (id) => _isPinned(ref, id),
  );
  List<RemoteSessionSnapshot> lineage(SessionNode node) => [
    remoteSessionSnapshot(ref, node.session, project: project),
    for (final child in node.children) ...lineage(child),
  ];
  final entries =
      <({DateTime ts, bool pinned, List<RemoteSessionSnapshot> rows})>[
        for (final node in forest)
          (
            ts: node.session.createdAt,
            pinned: _isPinned(ref, node.session.id),
            rows: lineage(node),
          ),
        for (final imported in sessions.imported)
          (
            ts: imported.updatedAt ?? imported.createdAt,
            pinned: _isPinned(ref, imported.id),
            rows: [remoteImportedSnapshot(ref, imported, project: project)],
          ),
      ]..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.ts.compareTo(a.ts);
      });
  return [for (final entry in entries) ...entry.rows];
}

/// Every session, in the **Explorer's own order** — the desktop tree read
/// top to bottom: pinned projects first, repositories in path order, the
/// unscanned folders beneath a repository before the repository's own
/// sessions, and each row's sessions ordered as the cards are.
///
/// Deliberately built WITHOUT asking git for worktrees: that is the same
/// tree the Explorer itself draws while git is still answering (repositories
/// as peers), and `sessions.list` must not spawn a process per repository.
/// Placement by deepest containing path is unaffected — it is what puts a
/// worktree's sessions in the right place — so only the worktree *headings*
/// are missing, which the phone does not draw anyway.
List<RemoteSessionSnapshot> listRemoteSessions(Ref ref) {
  final out = <RemoteSessionSnapshot>[];
  final placed = <String>{};
  for (final project in ref.read(sortedProjectsProvider)) {
    final repositories = ref
        .read(repositoryDaoProvider)
        .getByProject(project.id);
    if (repositories.isEmpty) continue;
    final tree = ProjectTree(
      repositories: [
        for (final repository in repositories)
          RepoNode(repository: repository, worktreesKnown: false),
      ],
    );
    final placement = placeSessions(
      tree,
      ref.read(projectSessionLocationsProvider(project.id)),
    );
    final ordered = [...tree.repositories]
      ..sort(
        (a, b) => canonicalPathKey(
          a.repository.path.path,
        ).compareTo(canonicalPathKey(b.repository.path.path)),
      );
    for (final node in ordered) {
      final key = repoRowKey(node.repository);
      for (final folder in placement.under(key)) {
        for (final row in _rowSnapshots(
          ref,
          placement.at(folderRowKey(folder.path)),
          project,
        )) {
          if (placed.add(row.sessionId)) out.add(row);
        }
      }
      for (final row in _rowSnapshots(ref, placement.at(key), project)) {
        if (placed.add(row.sessionId)) out.add(row);
      }
    }
  }
  // Nothing is ever dropped: a session whose repository or project row is
  // gone is appended rather than vanishing from the phone's list.
  for (final session in ref.read(sessionDaoProvider).getAll()) {
    if (placed.add(session.id)) out.add(remoteSessionSnapshot(ref, session));
  }
  // One entry per conversation, like the Explorer: `getAll` — and the
  // `getByRepository` the ordered walk above reads — both exclude a record a
  // native row already represents. That filter lives in `ImportedSessionDao`
  // and must stay the only copy of the rule; a raw read here would put the
  // same conversation on the phone twice.
  for (final session in ref.read(importedSessionDaoProvider).getAll()) {
    if (placed.add(session.id)) {
      out.add(remoteImportedSnapshot(ref, session));
    }
  }
  return out;
}
