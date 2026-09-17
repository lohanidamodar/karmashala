/// What a phone is shown about a session, worded as the desktop card words it,
/// so the phone and the screen beside it cannot describe one differently.
library;

import 'package:riverpod/riverpod.dart';

import '../../automations/application/scheduled_resume_providers.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
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
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/resume.dart';
import '../../settings/application/settings_controller.dart';
import 'package:karmashala_remote/remote.dart';
import 'remote_attachment_bindings.dart';
import 'remote_binding_support.dart';

/// Uses the latest delivery reading without making the phone wait for git/gh.
final remoteDeliveryStageProvider =
    Provider<Future<String?> Function(String sessionId)>((ref) {
      return (sessionId) async {
        try {
          final provider = sessionDeliveryProvider(sessionId);
          if (!ref.exists(provider)) return null;
          return ref.read(provider).value?.stage.name;
        } on Object {
          return null;
        }
      };
    });

/// The whereabouts-and-age lookup behind the list payload, split out like the
/// stage lookup so tests can stub it.
final remoteSessionPresenceProvider =
    Provider<({String? note, DateTime? lastSeen}) Function(String sessionId)>((
      ref,
    ) {
      return (sessionId) {
        try {
          final whereabouts = ref.read(sessionWhereaboutsProvider(sessionId));
          // Worded here like the rest of the clause, so the phone draws a
          // waiting resume with no field of its own.
          final clauses = [
            ?ref.read(sessionResumeBadgeProvider(sessionId))?.label,
            ?whereabouts.note,
          ];
          return (
            note: clauses.isEmpty ? null : clauses.join('  ·  '),
            lastSeen: whereabouts.lastSeen,
          );
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
    // The one definition every list orders by: the agent's own newest evidence,
    // else when the row was created — never our last poll.
    lastActivityAt: (_lastActiveOfSession(ref, session).at ?? session.createdAt)
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
    // The badge is null for the local host by design; the phone is not sitting
    // at that machine and still has to name it, so the name goes too.
    environmentName: environmentNameFor(ref, owner?.environmentId),
    environmentId: owner?.environmentId,
    environmentKind: environmentKindFor(ref, owner?.environmentId),
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
    // Absent rather than invented when the file could not be dated (§19).
    lastActivityAt: _lastActiveOfImported(session).at?.toUtc().toIso8601String(),
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
    environmentName: environmentNameFor(
      ref,
      owner?.environmentId ?? repository?.path.environmentId,
    ),
    environmentId: owner?.environmentId ?? repository?.path.environmentId,
    environmentKind: environmentKindFor(
      ref,
      owner?.environmentId ?? repository?.path.environmentId,
    ),
  );
}

/// When a session was last active, through [remoteSessionPresenceProvider]: the
/// field the phone draws and the order it is drawn in come from one reading.
SessionLastActive _lastActiveOfSession(Ref ref, Session session) =>
    newestLastActive(
      agentEvidenceAt: ref.read(remoteSessionPresenceProvider)(session.id)
          .lastSeen,
    );

SessionLastActive _lastActiveOfImported(ImportedSession session) =>
    newestLastActive(storeModifiedAt: session.updatedAt);

/// The sessions of one Explorer row, in the order the Explorer draws them:
/// pinned first, then most recently active, children under their parent.
List<RemoteSessionSnapshot> _rowSnapshots(
  Ref ref,
  CheckoutSessions sessions,
  Project project,
) {
  if (sessions.isEmpty) return const [];
  final forest = buildSessionForest(
    sessions.native,
    isPinned: (id) => _isPinned(ref, id),
    lastActive: (id) {
      final session = ref.read(sessionDaoProvider).getById(id);
      return session == null
          ? SessionLastActive.unknown
          : _lastActiveOfSession(ref, session);
    },
  );
  List<RemoteSessionSnapshot> lineage(SessionNode node) => [
    remoteSessionSnapshot(ref, node.session, project: project),
    for (final child in node.children) ...lineage(child),
  ];
  final entries =
      <({SessionActivityOrder order, bool pinned, List<RemoteSessionSnapshot> rows})>[
        for (final node in forest)
          (
            order: (
              lastActive: _lastActiveOfSession(ref, node.session),
              createdAt: node.session.createdAt,
            ),
            pinned: _isPinned(ref, node.session.id),
            rows: lineage(node),
          ),
        for (final imported in sessions.imported)
          (
            order: (
              lastActive: _lastActiveOfImported(imported),
              createdAt: imported.createdAt,
            ),
            pinned: _isPinned(ref, imported.id),
            rows: [remoteImportedSnapshot(ref, imported, project: project)],
          ),
      ]..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return compareByLastActive(a.order, b.order);
      });
  return [for (final entry in entries) ...entry.rows];
}

/// Every session in the **Explorer's own order**, built WITHOUT asking git for
/// worktrees: `sessions.list` must not spawn a process per repository.
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
  // One entry per conversation: `ImportedSessionDao` already excludes a record
  // a native row represents, and a raw read here would list it twice.
  for (final session in ref.read(importedSessionDaoProvider).getAll()) {
    if (placed.add(session.id)) {
      out.add(remoteImportedSnapshot(ref, session));
    }
  }
  return out;
}
