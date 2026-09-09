/// The production wiring of [RemoteHostBindings]: every function points at
/// the SAME provider the desktop UI reads, so the phone and the screen can
/// never tell a different story about one session.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/process/path_translator.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_permission_support.dart';
import '../../agents/domain/agent_permission_options.dart';
import '../../agents/domain/agent_registry.dart';
import '../../agents/domain/agent_status.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_label.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';
import '../../environments/domain/execution_environment.dart';
import '../../explorer/application/checkout.dart';
import '../../explorer/application/project_tree.dart';
import '../../explorer/application/session_diff_stat.dart';
import '../../explorer/application/session_forest.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/domain/session_attention.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/domain/project.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_activity_providers.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_chat_view_providers.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_resume_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_attribution.dart';
import '../../sessions/domain/session_event_types.dart';
import '../../sessions/domain/session_launch.dart';
import '../../notes/application/composer_draft.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../data/companion_attachment_store.dart';
import '../domain/remote_payloads.dart';
import '../protocol.dart';
import 'host_bindings.dart';
import 'remote_providers.dart';

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

/// The Loop-49 evidence lookup, stubbed in tests for the same reason: the
/// real one reads `agentSessionStatusProvider`, whose sources include a
/// terminal grid and the CLI store on disk.
final remoteApprovalEvidenceProvider =
    Provider<Future<AgentStatusReport?> Function(String sessionId)>((ref) {
      return (sessionId) async {
        try {
          return await ref.read(agentSessionStatusProvider(sessionId).future);
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

/// Whether a session's working folder is gone from disk — the Explorer's own
/// "missing" mark, answered synchronously here because `sessions.list` is.
///
/// A seam like the two probe-shaped lookups above: production touches the
/// filesystem, tests stub it. **False also means "could not tell"** — a
/// non-Windows path with no translation available is never flagged, which is
/// the same fail-safe direction `projectPathMissingProvider` takes.
final remoteFolderMissingProvider =
    Provider<bool Function(EnvironmentPath path)>((ref) {
      return (path) {
        try {
          final environments = ref.read(executionEnvironmentDaoProvider);
          final env = environments.getById(path.environmentId);
          if (env == null) return false;
          var resolved = path.path;
          if (env.kind != EnvironmentKind.windowsNative) {
            ExecutionEnvironment? windows;
            for (final candidate in environments.getAll()) {
              if (candidate.kind == EnvironmentKind.windowsNative) {
                windows = candidate;
                break;
              }
            }
            if (windows == null) return false;
            resolved = ref
                .read(pathTranslatorProvider)
                .translate(path, from: env, to: windows)
                .path;
          }
          return !Directory(resolved).existsSync();
        } on Object {
          return false;
        }
      };
    });

/// The branch checked out at a directory, **only if the desktop has already
/// measured it**. Reads the cached `checkoutStatProvider` answer and starts
/// no git of its own — the same rule the Explorer's project headers follow, so
/// listing sessions on a phone never sets off a wave of processes. Null means
/// "not measured yet", never "no branch".
final remoteCheckoutBranchProvider =
    Provider<String? Function(EnvironmentPath path)>((ref) {
      return (path) {
        try {
          return ref
              .read(checkoutStatProvider(Checkout(path)))
              .asData
              ?.value
              .branch;
        } on Object {
          return null;
        }
      };
    });

/// What a file sent to one session may be — the answer the phone is shown on
/// the row, **before** it lets anybody pick a 4 MB photo.
///
/// Three things have to be true at once, and each of them is per session:
///
/// 1. the agent behind it reads a path written into its prompt
///    ([AgentAttachmentSupport], declared per agent with its evidence);
/// 2. that agent runs somewhere this desktop can write a file it will see —
///    which rules SSH out entirely, because the agent is on another machine
///    and a path on this disk means nothing there;
/// 3. there is a live session to type into at all.
///
/// Costs nothing to compute: three DAO reads the snapshot already makes, and
/// no process, no probe and no filesystem call.
RemoteAttachmentSupport _attachmentSupportFor(
  Ref ref,
  String? agentId,
  String? environmentId,
) {
  final descriptor = agentId == null
      ? null
      : AgentRegistry.builtIn.byId(agentId);
  final support = descriptor?.attachments;
  if (support == null || !support.isSupported) {
    return RemoteAttachmentSupport.refused(
      support?.refusal.isNotEmpty ?? false
          ? support!.refusal
          : 'This agent is not known to open a file named in a prompt.',
    );
  }
  final environment = environmentId == null
      ? null
      : ref.read(executionEnvironmentDaoProvider).getById(environmentId);
  if (environment == null) {
    return const RemoteAttachmentSupport.refused(
      'This desktop cannot tell where that agent runs.',
    );
  }
  if (!isLocalHost(environment.kind) &&
      environment.kind != EnvironmentKind.wsl) {
    // The one case that is not about the CLI at all: the agent has its own
    // filesystem, and a path this desktop writes is not a path it can open.
    return RemoteAttachmentSupport.refused(
      '${environment.name} runs on another machine — a file written here is '
      'not a file it can open.',
    );
  }
  return RemoteAttachmentSupport(
    mediaTypes: [
      for (final type in support.mediaTypes)
        // Only what this desktop can also *write*: a type the agent would read
        // but the store has no extension for is a path nobody can open.
        if (kAttachmentExtensions.containsKey(type)) type,
    ],
    maxBytes: kMaxAttachmentBytes,
  );
}

/// The path an agent in [environmentId] would use for a file this host wrote.
///
/// Explicit, through [PathTranslator], because constraint 8 forbids the
/// implicit kind — and because getting it wrong hands an agent a path that
/// silently does not exist rather than an error anybody can read.
String _agentVisiblePath(Ref ref, String hostPath, String? environmentId) {
  final environments = ref.read(executionEnvironmentDaoProvider);
  final target = environmentId == null
      ? null
      : environments.getById(environmentId);
  if (target == null || isLocalHost(target.kind)) return hostPath;
  ExecutionEnvironment? here;
  for (final candidate in environments.getAll()) {
    if (candidate.kind == EnvironmentKind.windowsNative) {
      here = candidate;
      break;
    }
  }
  if (here == null) return hostPath;
  return ref
      .read(pathTranslatorProvider)
      .translate(
        EnvironmentPath(environmentId: here.id, path: hostPath),
        from: here,
        to: target,
      )
      .path;
}

final remoteHostBindingsProvider = Provider<RemoteHostBindings>((ref) {
  final projectAdds = <String, Future<RemoteWorkspaceProject>>{};
  /// The project a repository belongs to, for the rows the ordered walk did
  /// not already know it for (`sessionById`, orphan fallbacks).
  Project? projectOfRepository(String? repositoryId) {
    if (repositoryId == null) return null;
    final repository = ref.read(repositoryDaoProvider).getById(repositoryId);
    if (repository == null) return null;
    return ref.read(projectDaoProvider).getById(repository.projectId);
  }

  bool isPinned(String sessionId) =>
      ref.read(settingsControllerProvider).pinnedSessionIds.contains(sessionId);

  RemoteSessionSnapshot snapshotOf(Session session, {Project? project}) {
    final repository = ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    final installation = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    final agentId = installation?.agentId;
    final presence = ref.read(remoteSessionPresenceProvider)(session.id);
    final owner = project ?? projectOfRepository(session.repositoryId);
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
      pinned: isPinned(session.id),
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
      attachments: _attachmentSupportFor(
        ref,
        agentId,
        installation?.executable.environmentId,
      ),
      // The project's environment, as the Explorer card badges it. A session
      // has none of its own, and one with no project has nothing to badge.
      environmentBadge: () {
        if (owner == null) return null;
        final env = ref
            .read(executionEnvironmentDaoProvider)
            .getById(owner.environmentId);
        return env == null ? null : environmentBadge(env);
      }(),
    );
  }

  RemoteSessionSnapshot importedSnapshotOf(
    ImportedSession session, {
    Project? project,
  }) {
    final repository = ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    final owner = project ?? projectOfRepository(session.repositoryId);
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
      pinned: isPinned(session.id),
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
      environmentBadge: () {
        final envDao = ref.read(executionEnvironmentDaoProvider);
        final envId = owner?.environmentId ?? repository?.path.environmentId;
        final env = envId == null ? null : envDao.getById(envId);
        return env == null ? null : environmentBadge(env);
      }(),
    );
  }

  ResolvedRemoteSession resolve(String sessionId) =>
      resolveRemoteSession(ref, sessionId);

  /// The sessions of one Explorer row, in the order the Explorer draws them:
  /// pinned first, then most recently active, with a lineage's children
  /// following the session they came from.
  List<RemoteSessionSnapshot> rowSnapshots(
    CheckoutSessions sessions,
    Project project,
  ) {
    if (sessions.isEmpty) return const [];
    final forest = buildSessionForest(sessions.native, isPinned: isPinned);
    List<RemoteSessionSnapshot> lineage(SessionNode node) => [
      snapshotOf(node.session, project: project),
      for (final child in node.children) ...lineage(child),
    ];
    final entries =
        <({DateTime ts, bool pinned, List<RemoteSessionSnapshot> rows})>[
          for (final node in forest)
            (
              ts: node.session.createdAt,
              pinned: isPinned(node.session.id),
              rows: lineage(node),
            ),
          for (final imported in sessions.imported)
            (
              ts: imported.updatedAt ?? imported.createdAt,
              pinned: isPinned(imported.id),
              rows: [importedSnapshotOf(imported, project: project)],
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
  List<RemoteSessionSnapshot> listSessionsInExplorerOrder() {
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
          for (final row in rowSnapshots(
            placement.at(folderRowKey(folder.path)),
            project,
          )) {
            if (placed.add(row.sessionId)) out.add(row);
          }
        }
        for (final row in rowSnapshots(placement.at(key), project)) {
          if (placed.add(row.sessionId)) out.add(row);
        }
      }
    }
    // Nothing is ever dropped: a session whose repository or project row is
    // gone is appended rather than vanishing from the phone's list.
    for (final session in ref.read(sessionDaoProvider).getAll()) {
      if (placed.add(session.id)) out.add(snapshotOf(session));
    }
    // One entry per conversation, like the Explorer: `getAll` — and the
    // `getByRepository` the ordered walk above reads — both exclude a record a
    // native row already represents. That filter lives in `ImportedSessionDao`
    // and must stay the only copy of the rule; a raw read here would put the
    // same conversation on the phone twice.
    for (final session in ref.read(importedSessionDaoProvider).getAll()) {
      if (placed.add(session.id)) out.add(importedSnapshotOf(session));
    }
    return out;
  }

  /// One installed agent, with everything the phone needs to offer it as a
  /// real choice: its name, whether its command line can carry an opening
  /// message, and every permission mode with how that mode reaches this agent.
  ///
  /// The modes come from [permissionOptionsFor] — the same table the desktop's
  /// own permission control is built from — so a mode the descriptor cannot
  /// express arrives marked `selectable: false` with the agent's own
  /// explanation, rather than being hidden or, worse, offered and dropped.
  RemoteAgentOption agentOption(AgentInstallation installation) {
    final descriptor = ref.read(agentRegistryProvider).byId(installation.agentId);
    final name = descriptor?.displayName ?? installation.agentId;
    return RemoteAgentOption(
      installationId: installation.id,
      agentId: installation.agentId,
      name: name,
      version: installation.version,
      // The desktop's own setting for a NEW session with this agent. The phone
      // preselects it and the user may change it; nothing on the phone invents
      // a default of its own.
      defaultMode: ref
          .read(sessionLauncherProvider)
          .permissionFor(installation.agentId, SessionPurpose.newSession)
          .canonical,
      acceptsOpeningMessage: descriptor?.launch.acceptsPromptArgument ?? false,
      // The phone gets the agent's real selections, flattened. It cannot draw
      // two pickers today, and the wire has always carried an opaque mode id
      // with the host's own words beside it — so a phone one release behind
      // shows Claude Code's six modes and Codex's seven combinations without
      // knowing anything new. An agent whose modes are unknown sends one
      // unselectable row that says so, rather than an empty menu.
      permissionModes: () {
        final support = descriptor?.launch.permission;
        if (support == null || !support.isKnown) {
          return [
            RemotePermissionOption(
              mode: '',
              label: 'Not established',
              summary: unknownAgentReason(name),
              selectable: false,
            ),
          ];
        }
        return [
          for (final selection in support.selections())
            RemotePermissionOption(
              mode: selection.canonical,
              label: describeSelection(support, selection),
              summary:
                  describeSelectionDetail(support, selection) ??
                  describeSelection(support, selection),
              selectable: true,
              dangerous: support.isDangerous(selection),
            ),
        ];
      }(),
    );
  }

  /// What could be started here, in the Explorer's own order: projects as the
  /// tree sorts them, checkouts by path, and under each checkout the agents
  /// installed in the environment it lives in.
  ///
  /// A project with no checkout is omitted — there is nowhere in it to start
  /// anything, and listing it would offer a choice that does not exist. Like
  /// `sessions.list`, this reads only what the desktop already holds: the
  /// branch comes from the cached checkout stat and no git is started.
  List<RemoteWorkspaceProject> listWorkspace() {
    final installations = ref.read(agentInstallationDaoProvider);
    final byEnvironment = <String, List<RemoteAgentOption>>{};
    List<RemoteAgentOption> agentsIn(String environmentId) =>
        byEnvironment[environmentId] ??= [
          for (final installation in installations.getByEnvironment(
            environmentId,
          ))
            agentOption(installation),
        ];

    // Read once and looked up per row: a workspace is mostly two or three
    // environments spread over many checkouts, and this runs on every
    // `workspace.list`.
    final environments = {
      for (final environment
          in ref.read(executionEnvironmentDaoProvider).getAll())
        environment.id: environment,
    };
    // The desktop's own name for where a folder lives. Null for an
    // environment row the desktop no longer holds — the phone then falls back
    // to the path rather than inventing a name for it.
    String? nameOf(String environmentId) {
      final environment = environments[environmentId];
      return environment == null ? null : environmentLabel(environment);
    }
    String? badgeOf(String environmentId) {
      final environment = environments[environmentId];
      return environment == null ? null : environmentBadge(environment);
    }

    final out = <RemoteWorkspaceProject>[];
    for (final project in ref.read(sortedProjectsProvider)) {
      final repositories =
          [...ref.read(repositoryDaoProvider).getByProject(project.id)]..sort(
            (a, b) => canonicalPathKey(
              a.path.path,
            ).compareTo(canonicalPathKey(b.path.path)),
          );
      if (repositories.isEmpty) continue;
      out.add(
        RemoteWorkspaceProject(
          projectId: project.id,
          name: project.name,
          path: project.root.path,
          environmentName: nameOf(project.environmentId),
          environmentBadge: badgeOf(project.environmentId),
          checkouts: [
            for (final repository in repositories)
              RemoteCheckoutOption(
                repositoryId: repository.id,
                name: repository.name,
                path: repository.path.path,
                subPath: relativeSubPath(project.root, repository.path),
                branch: ref.read(remoteCheckoutBranchProvider)(repository.path),
                environmentName: nameOf(repository.environmentId),
                folderMissing: ref.read(remoteFolderMissingProvider)(
                  repository.path,
                ),
                agents: agentsIn(repository.environmentId),
              ),
          ],
        ),
      );
    }
    return out;
  }

  return RemoteHostBindings(
    hostName: Platform.localHostname,
    listSessions: listSessionsInExplorerOrder,
    sessionById: (sessionId) {
      final resolved = resolve(sessionId);
      final session = resolved.native;
      if (session != null) return snapshotOf(session);
      final imported = resolved.imported;
      return imported == null ? null : importedSnapshotOf(imported);
    },
    deliveryStageFor: (sessionId) =>
        ref.read(remoteDeliveryStageProvider)(sessionId),
    transcriptFor: (sessionId) => _transcriptFor(ref, sessionId),
    // The composer's own route: `continueSession` types into the live PTY or
    // resumes the engine session, exactly as the desktop send button does.
    // Async so an imported-session refusal is a failed future, never a
    // synchronous escape past a caller's error handling.
    sendPrompt: (sessionId, text, {attachment}) async {
      final resolved = resolve(sessionId);
      if (resolved.imported != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — read-only here; '
          'continue it in its own terminal',
        );
      }
      // The LIVE id, never the one the phone asked with: a stale imported id
      // names a record that cannot be typed into.
      final live = resolved.native?.id ?? sessionId;
      if (attachment == null) {
        await ref.read(sessionActionsProvider).continueSession(live, text);
        return RemotePromptDelivery.sent;
      }
      await _offerAttachment(ref, live, text, attachment);
      return RemotePromptDelivery.offered;
    },
    answerApproval: (sessionId, decision) async {
      final resolved = resolve(sessionId);
      if (resolved.imported != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — answer it in its own '
          'terminal',
        );
      }
      return _answerApproval(ref, resolved.native?.id ?? sessionId, decision);
    },
    approvalEvidenceFor: (sessionId) => _approvalEvidenceFor(ref, sessionId),
    registerPush: (deviceId, token, platform) async {
      ref
          .read(pairedDeviceDaoProvider)
          .updatePush(deviceId, token: token, platform: platform);
      ref.read(pairedDevicesRevisionProvider.notifier).bump();
    },
    listWorkspace: listWorkspace,
    listProjects: () {
      final envDao = ref.read(executionEnvironmentDaoProvider);
      return [
        for (final project in ref.read(projectDaoProvider).getAll())
          RemoteWorkspaceProject(
            projectId: project.id,
            name: project.name,
            path: project.root.path,
            environmentName: () {
              final env = envDao.getById(project.environmentId);
              return env == null ? null : environmentLabel(env);
            }(),
            environmentBadge: () {
              final env = envDao.getById(project.environmentId);
              return env == null ? null : environmentBadge(env);
            }(),
          ),
      ];
    },
    startSession: (request) => _startSession(ref, request),
    beginAttachment: (deviceId, request) async {
      try {
        return await (await ref.read(
          companionAttachmentStoreProvider.future,
        )).begin(deviceId, request);
      } on AttachmentUploadException catch (failure) {
        throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
      }
    },
    writeAttachmentChunk: (deviceId, uploadId, seq, data) async {
      try {
        await (await ref.read(
          companionAttachmentStoreProvider.future,
        )).write(deviceId, uploadId, seq, data);
      } on AttachmentUploadException catch (failure) {
        throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
      }
    },
    discardAttachment: (deviceId) async {
      await (await ref.read(
        companionAttachmentStoreProvider.future,
      )).discard(deviceId);
    },
    addProject: (name, path) async {
      final trimmedName = name.trim();
      if (trimmedName.isEmpty ||
          trimmedName.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'name and an existing absolute local desktop path are required',
        );
      }
      // Resolve before joining the in-flight map. This both avoids duplicate
      // filesystem work and makes aliases (including case variants on
      // Windows) share one operation.
      final canonical = await _canonicalProjectPath(path);
      final key = canonicalPathKey(canonical);
      final future = projectAdds.putIfAbsent(
        key,
        () => _addProject(ref, trimmedName, canonical),
      );
      try {
        return await future;
      } finally {
        if (identical(projectAdds[key], future)) {
          projectAdds.remove(key);
        }
      }
    },
    resumeSession: (sessionId) => _resumeSession(ref, sessionId),
  );
});

Future<RemoteWorkspaceProject> _addProject(
  Ref ref,
  String name,
  String path,
) async {
  final trimmedName = name.trim();
  final trimmedPath = path.trim();
  if (trimmedName.isEmpty || trimmedPath.isEmpty ||
      trimmedPath.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      !p.isAbsolute(trimmedPath)) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'name and an existing absolute local desktop path are required',
    );
  }
  if (trimmedPath.startsWith(r'\\') || trimmedPath.startsWith('//')) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'the path must be on the desktop, not a network or WSL path',
    );
  }
  final canonical = canonicalPathKey(trimmedPath);
  final envDao = ref.read(executionEnvironmentDaoProvider);
  for (final project in ref.read(projectDaoProvider).getAll()) {
    if (project.root.environmentId == localHostEnvironmentId &&
        canonicalPathKey(project.root.path) == canonical) {
      final env = envDao.getById(project.environmentId);
      return RemoteWorkspaceProject(
        projectId: project.id,
        name: project.name,
        path: project.root.path,
        environmentName: env == null ? null : environmentLabel(env),
        environmentBadge: env == null ? null : environmentBadge(env),
      );
    }
  }
  final result = await ref.read(projectsControllerProvider.notifier).createByDiscovery(
    name: trimmedName,
    path: trimmedPath,
  );
  final createdEnv = envDao.getById(result.project.environmentId);
  return RemoteWorkspaceProject(
    projectId: result.project.id,
    name: result.project.name,
    path: result.project.root.path,
    environmentName: createdEnv == null ? null : environmentLabel(createdEnv),
    environmentBadge: createdEnv == null ? null : environmentBadge(createdEnv),
    checkouts: [
      for (final repository in result.repositories)
        RemoteCheckoutOption(
          repositoryId: repository.id,
          name: repository.name,
          path: repository.path.path,
        ),
    ],
  );
}

Future<String> _canonicalProjectPath(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty ||
      trimmed.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      !p.isAbsolute(trimmed)) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'name and an existing absolute local desktop path are required',
    );
  }
  if (trimmed.startsWith(r'\\') || trimmed.startsWith('//')) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'the path must be on the desktop, not a network or WSL path',
    );
  }
  final directory = Directory(trimmed);
  if (!await directory.exists()) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'that desktop folder does not exist');
  }
  final canonical = (await directory.resolveSymbolicLinks()).trim();
  // A local-looking junction can resolve onto a UNC/network target. Refuse
  // after resolution as well as before it, so the service never imports a
  // path outside the desktop's local filesystem contract.
  if (canonical.startsWith(r'\\') || canonical.startsWith('//')) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'the path must be on the desktop, not a network or WSL path',
    );
  }
  return canonical;
}

Future<RemoteSessionStarted> _resumeSession(Ref ref, String sessionId) async {
  final native = ref.read(sessionDaoProvider).getById(sessionId);
  if (native != null) {
    final launcher = ref.read(sessionLauncherProvider);
    if (launcher.reveal(native.id)) {
      return RemoteSessionStarted(
        sessionId: native.id,
        title: native.title,
        permissionMode: native.permissionMode,
      );
    }
    final external = native.externalSessionId;
    if (external == null || external.trim().isEmpty) {
      throw const RemoteApiRefusal(ErrorCode.badRequest, 'this session has no conversation to resume');
    }
    final repository = ref.read(repositoryDaoProvider).getById(native.repositoryId);
    final installation = ref.read(agentInstallationDaoProvider).getById(native.agentInstallationId);
    if (repository == null || installation == null) {
      throw const RemoteApiRefusal(ErrorCode.notFound, 'the session workspace is no longer available');
    }
    try {
      final launched = await ref.read(sessionLauncherProvider).launch(
        SessionLaunchRequest(
          repository: repository,
          installation: installation,
          title: native.title,
          purpose: SessionPurpose.existingSession,
          resumeExternalSessionId: external,
          existingWorktree: native.worktree,
          workingDirectory: native.workingDirectory,
          permissionOverride: PermissionSelection.parse(native.permissionMode),
        ),
      );
      return RemoteSessionStarted(
        sessionId: launched.session.id,
        title: launched.session.title,
        permissionMode: launched.session.permissionMode,
      );
    } catch (error) {
      throw RemoteApiRefusal(ErrorCode.badRequest, _sayLaunchFailure(error));
    }
  }
  final imported = ref.read(importedSessionDaoProvider).getById(sessionId);
  if (imported == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'this session no longer exists');
  }
  try {
    final id = await ref.read(sessionActionsProvider).resumeImported(imported);
    final resumed = ref.read(sessionDaoProvider).getById(id);
    return RemoteSessionStarted(
      sessionId: id,
      title: resumed?.title ?? imported.title ?? 'Resumed session',
      permissionMode: resumed?.permissionMode,
    );
  } catch (error) {
    throw RemoteApiRefusal(ErrorCode.badRequest, _sayLaunchFailure(error));
  }
}

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

/// Which record represents [sessionId] **right now**: the live session row, or
/// read-only CLI history, or neither.
///
/// One conversation can have a record in both tables, and `ImportedSessionDao`
/// resolves the tie: a conversation with a native row is *superseded*, and
/// every list read there hides the imported record. Hiding a row from a list
/// does not stop anyone asking for it by id, though, and a phone holds ids: it
/// lists once and opens later. A Codex conversation id is *discovered* rather
/// than assigned — `LaunchedSessionAttributionService` writes it on a store
/// sweep — so there is a real window after launch in which the imported record
/// is still listed, and a phone that fetched its list inside that window is
/// holding an id that has since been superseded.
///
/// Opening it gave the owner "a session that's not running": the CLI's own
/// history for a conversation live in a pane on the desktop, with a composer
/// that refused every prompt as read-only. So the rule is applied on the way
/// *in* as well: an imported id a native row has taken over resolves to that
/// row, and the phone reaches the running session with the id it happens to
/// hold. The supersede test itself is not repeated here — it is asked of
/// [ImportedSessionDao.supersedingSessionId], the same place the list filter
/// is written.
ResolvedRemoteSession resolveRemoteSession(Ref ref, String sessionId) {
  final sessions = ref.read(sessionDaoProvider);
  final native = sessions.getById(sessionId);
  if (native != null) return (native: native, imported: null);
  final imported = ref.read(importedSessionDaoProvider).getById(sessionId);
  if (imported == null) return (native: null, imported: null);
  final liveId = ref
      .read(importedSessionDaoProvider)
      .supersedingSessionId(imported.externalId);
  final live = liveId == null ? null : sessions.getById(liveId);
  // Nothing took it over — genuine history, opened read-only as before.
  if (live == null) return (native: null, imported: imported);
  return (native: live, imported: null);
}

/// What [resolveRemoteSession] answers with. Exactly one field is ever set.
typedef ResolvedRemoteSession = ({Session? native, ImportedSession? imported});

/// The same source selection as `SessionTranscriptView`: a PTY-hosted
/// session renders from the agent's own record; anything else renders from
/// the engine's event log. Attribution is REBUILT from the parent session's
/// typed fields and stripped on a whole-string match — never parsed out of
/// the text (the dray constraint).
///
/// **One read, two answers.** The activity comes off the very same parse — see
/// [RemoteSessionRecord] — because the poll sweep re-reads this file and the
/// largest one here is 53 MB.
Future<RemoteSessionRecord> _transcriptFor(Ref ref, String sessionId) async {
  final resolved = resolveRemoteSession(ref, sessionId);
  final session = resolved.native;
  if (session == null) {
    final imported = resolved.imported;
    if (imported != null) {
      // Imported history is not a running session: it has no row to be
      // `working`, so the one rule answers "nothing is running" for it.
      return (
        page: await _importedTranscript(imported),
        activity: _activityOf(ref, sessionId, SessionActivity.none),
      );
    }
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  final record = session.surface == SessionSurface.pane
      ? await _agentRecordMessages(ref, session)
      // `session.id`, not the id asked with: a superseded imported id has no
      // event log of its own.
      : (
          messages: _eventLogMessages(ref, session.id),
          absence: null,
          turns: null,
        );
  var messages = record.messages;

  final attribution = _attributionOf(ref, session);
  if (attribution != null) {
    messages = [
      for (final message in messages)
        message.role == 'user'
            ? RemoteTranscriptMessage(
                role: 'user',
                text: attribution.stripFrom(message.text),
              )
            : message,
    ];
  }
  return (
    page: RemoteTranscriptPage(
      // The row this actually came from. A phone that asked with a superseded
      // imported id learns the live one here rather than being told its stale
      // id is fine.
      sessionId: session.id,
      messages: messages,
      cursor: messages.length,
      // Only ever a reason for a nothing. A page that carries turns needs no
      // explanation, and one that carried both would be saying two things.
      absence: messages.isEmpty ? record.absence : null,
    ),
    activity: _activityOf(
      ref,
      session.id,
      sessionActivityFrom(
        rowStatus: session.status,
        surface: session.surface,
        // The registry's cached answer, read synchronously: the same word the
        // desktop badge shows, and no poll of its own.
        status: ref.read(sessionActivityLookupProvider)(session.id),
        messages: record.turns,
      ),
    ),
  );
}

/// The wire form of one [SessionActivity], stamped with when we looked.
///
/// The host's clock rather than the phone's, and said out loud, so the phone
/// can measure an elapsed time both ends agree on — see
/// [RemoteSessionActivity.observedAt].
RemoteSessionActivity _activityOf(
  Ref ref,
  String sessionId,
  SessionActivity activity,
) => RemoteSessionActivity(
  sessionId: sessionId,
  observedAt: ref.read(clockProvider).nowUtc(),
  calls: [
    for (final call in activity.calls)
      RemoteActivityCall(
        summary: call.summary,
        toolName: call.toolName,
        subagent: call.isSubagent,
        startedAt: call.startedAt,
      ),
  ],
  absence: switch (activity.blindSpot) {
    ActivityBlindSpot.noRecord => RemoteActivityAbsence.noRecord,
    null => null,
  },
);

/// An imported CLI session's transcript: the agent's own store file, exactly
/// what the desktop's imported view reads. Tool rows dropped like the pane
/// mapping; no attribution — an imported session has no parent of ours.
Future<RemoteTranscriptPage> _importedTranscript(
  ImportedSession session,
) async {
  final messages = await readCliTranscript(session.filePath, session.cli);
  final mapped = [
    for (final message in messages)
      if (message.role != 'tool')
        RemoteTranscriptMessage(role: message.role, text: message.text),
  ];
  return RemoteTranscriptPage(
    sessionId: session.id,
    messages: mapped,
    cursor: mapped.length,
  );
}

/// What [_agentRecordMessages] answers with: the turns, and *why* there are
/// none when the host can say so.
typedef _AgentRecord = ({
  List<RemoteTranscriptMessage> messages,
  RemoteTranscriptAbsence? absence,
  /// The parse the [messages] were cut from, kept so the activity can be read
  /// off the same read. **Null means there was no record to read** — which is
  /// what tells "nothing is outstanding" from "we cannot see", and is exactly
  /// the distinction every early return below is already making.
  List<TranscriptMessage>? turns,
});

const _AgentRecord _nothingKnown = (
  messages: <RemoteTranscriptMessage>[],
  absence: null,
  turns: null,
);

/// The agent's own transcript file — `sessionChatTranscriptProvider`'s source,
/// read once rather than polled. Tool rows are dropped, as the desktop chat
/// view drops them.
///
/// The empty answers are not interchangeable, and this is the only place that
/// can tell them apart. A **structural** nothing is one that will still hold
/// after the agent answers — an agent whose store keeps its messages in a form
/// nothing here opens, or a session whose store keeps the conversation and no
/// readable transcript beside it — and the phone words that as its own empty
/// state. Every other early return is a nothing we cannot account for — no
/// external id yet, an installation that has gone, a store file the locator
/// could not find — and those stay unexplained rather than being dressed up as
/// the structural one.
///
/// **Which one this is is now read per session, not per agent.** It was
/// `agentSupportsChatView` over the store format, which sent `noChatView` for
/// every Antigravity session; the WSL install here keeps a readable JSONL
/// transcript for all 25 of its conversations, so that refusal was wrong for
/// every one of them. `SessionChatView` is the same reading the desktop's own
/// chat view and plan panel use, off the store scan this already pays for, so
/// the two ends cannot describe one session differently.
Future<_AgentRecord> _agentRecordMessages(Ref ref, Session session) async {
  const noChatView = (
    messages: <RemoteTranscriptMessage>[],
    absence: RemoteTranscriptAbsence.noChatView,
    turns: null,
  );
  final screen = screenSessionChatView(ref, session.id);
  if (screen.keepsNoRecord) return noChatView;
  final externalId = session.externalSessionId;
  if (externalId == null || externalId.isEmpty) return _nothingKnown;
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  if (agentId == null) return _nothingKnown;
  final path = await ref
      .read(sessionTranscriptLocatorProvider)
      .locate(agentId: agentId, externalSessionId: externalId);
  final chatView = await readChatViewAt(
    storePath: path,
    agentId: agentId,
    prior: screen.prior,
    at: ref.read(clockProvider).nowUtc(),
  );
  if (chatView.keepsNoRecord) return noChatView;
  if (path == null || !chatView.hasChatView) return _nothingKnown;
  final messages = await readCliTranscript(path, agentId);
  return (
    messages: [
      for (final message in messages)
        if (message.role != 'tool')
          RemoteTranscriptMessage(role: message.role, text: message.text),
    ],
    absence: null,
    turns: messages,
  );
}

/// The engine's event log, mapped exactly as the desktop chat view maps it.
List<RemoteTranscriptMessage> _eventLogMessages(Ref ref, String sessionId) {
  final events = ref.read(sessionEventDaoProvider).listForSession(sessionId);
  final messages = <RemoteTranscriptMessage>[];
  for (final event in events) {
    switch (event.type) {
      case SessionEventTypes.userMessage:
        _addText(messages, 'user', event.payload);
      case SessionEventTypes.agentMessage:
        _addText(messages, 'agent', event.payload);
      case SessionEventTypes.error:
        _addText(messages, 'error', event.payload);
      case SessionEventTypes.sessionFailed:
        messages.add(
          const RemoteTranscriptMessage(role: 'error', text: 'Session failed.'),
        );
      case SessionEventTypes.sessionCancelled:
        messages.add(
          const RemoteTranscriptMessage(role: 'tool', text: 'Session ended.'),
        );
    }
  }
  return messages;
}

void _addText(List<RemoteTranscriptMessage> out, String role, String payload) {
  String text = '';
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      text = (decoded['text'] ?? '').toString();
    }
  } on FormatException {
    // Not JSON; nothing to show.
  }
  if (text.isNotEmpty) out.add(RemoteTranscriptMessage(role: role, text: text));
}

SessionAttribution? _attributionOf(Ref ref, Session session) {
  final parentId = session.parentSessionId;
  if (parentId == null) return null;
  final parent = ref.read(sessionDaoProvider).getById(parentId);
  if (parent == null) return null;
  return SessionAttribution(sessionId: parent.id, title: parent.title);
}

/// The Loop-49 answer path: the key comes from the agent's own
/// [AgentApprovalRules] and is pressed by [SessionLauncher.answerPrompt] —
/// nothing here invents a binding.
Future<String> _answerApproval(
  Ref ref,
  String sessionId,
  String decision,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  final rules = agentId == null
      ? const AgentApprovalRules()
      : ref.read(agentRegistryProvider).byId(agentId)?.approval ??
            const AgentApprovalRules();
  final key = decision == 'approve' ? rules.approve : rules.deny;
  if (key == null) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      'this agent names no way to $decision from outside its terminal',
    );
  }
  // The desktop card's rule, enforced where the key is actually pressed: a
  // phone holding a stale card — or an older build that was handed labels it
  // should not have been — must not type Enter into a session that has merely
  // finished its turn.
  if (!_hasOpenPrompt(await ref.read(remoteApprovalEvidenceProvider)(sessionId))) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'this session has no prompt open to answer',
    );
  }
  if (!ref.read(sessionLauncherProvider).answerPrompt(sessionId, key.keys)) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this session has no live terminal to answer in',
    );
  }
  return key.label;
}

Future<RemoteApprovalRequest> _approvalEvidenceFor(
  Ref ref,
  String sessionId,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  final agentId = session == null
      ? null
      : ref
            .read(agentInstallationDaoProvider)
            .getById(session.agentInstallationId)
            ?.agentId;
  final rules = agentId == null
      ? null
      : ref.read(agentRegistryProvider).byId(agentId)?.approval;
  final report = await ref.read(remoteApprovalEvidenceProvider)(sessionId);
  final asking = report?.status == AgentActivityStatus.awaitingApproval;
  final answerable = _hasOpenPrompt(report);
  return RemoteApprovalRequest(
    sessionId: sessionId,
    evidence: asking ? report!.evidence : const [],
    waiting: asking ? _wireWait(report!.waiting) : RemoteWaitKind.unrecorded,
    // Keys only for a prompt a source could actually see. `awaitingApproval`
    // alone says the session stopped for the user, which is also true of an
    // agent sitting at its own input — and approve types Enter there.
    approveLabel: answerable ? rules?.approve?.label : null,
    denyLabel: answerable ? rules?.deny?.label : null,
  );
}

/// The one rule both halves of the remote approval path turn on, and the same
/// one `ApprovalRequestCard` draws its buttons from: a key may be offered, and
/// pressed, only for a wait a status source identified as an approval.
///
/// The rule itself lives on [AgentStatusReport.hasOpenPrompt], because
/// `session_send` refuses on it too and three copies of it could disagree.
/// Absent is not an open prompt: a session no source could read is our blind
/// spot, not a modal.
bool _hasOpenPrompt(AgentStatusReport? report) => report?.hasOpenPrompt ?? false;

RemoteWaitKind _wireWait(AgentWaitKind kind) => switch (kind) {
  AgentWaitKind.approval => RemoteWaitKind.approval,
  AgentWaitKind.input => RemoteWaitKind.input,
  AgentWaitKind.unrecorded => RemoteWaitKind.unrecorded,
};

/// Starts a session the phone asked for, through [SessionLauncher.launch] and
/// nothing else.
///
/// Everything that makes a launch safe already lives there — the permission
/// mode it stamps, the depth cap, the resume and fork guards, the refusal of
/// an opening message an agent cannot be handed — so this resolves the two ids
/// the phone named, checks the mode is one the agent can actually be put into,
/// and hands over.
///
/// Every way that can end badly leaves as a [RemoteApiRefusal] carrying the
/// desktop's OWN sentence. `bad_request` is the code because that is the one
/// the companion quotes verbatim, and a phone told "something went wrong"
/// after asking for a session is told nothing it can act on.
Future<RemoteSessionStarted> _startSession(
  Ref ref,
  RemoteSessionStartRequest request,
) async {
  final repository = ref
      .read(repositoryDaoProvider)
      .getById(request.repositoryId);
  if (repository == null) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this desktop no longer holds that checkout',
    );
  }
  final installation = ref
      .read(agentInstallationDaoProvider)
      .getById(request.installationId);
  if (installation == null) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'that agent is no longer installed on this desktop',
    );
  }
  final descriptor = ref.read(agentRegistryProvider).byId(installation.agentId);
  final agentName = descriptor?.displayName ?? installation.agentId;
  // An installation is the pair (agent, environment): one installed in WSL
  // cannot be started against a Windows checkout, and the launcher would build
  // a command line for a path that environment cannot see.
  if (installation.environmentId != repository.path.environmentId) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      '$agentName is not installed where that checkout lives',
    );
  }

  // Enforced and not merely offered: `workspace.list` already told the phone
  // which modes this agent has, so asking for another one is asking for
  // something the desktop said does not exist. Refusing in the agent's own
  // terms beats launching under its default and reporting the mode the user
  // picked.
  //
  // Deliberately not `carryPermission`: nothing is being carried here. That
  // rule exists to move a mode from one agent to another when the user is
  // choosing an *agent*; this user is choosing a mode, for one agent, and the
  // safe answer to an impossible one is to say so.
  final support = descriptor?.launch.permission;
  if (support == null || !support.isKnown) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      unknownAgentReason(agentName),
    );
  }
  final mode = support
      .selections()
      .where((s) => s.canonical == request.permissionMode)
      .firstOrNull;
  if (mode == null) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      '$agentName has no permission mode called '
      '"${request.permissionMode}"',
    );
  }

  try {
    final launched = await ref
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository,
            installation: installation,
            // Empty becomes "Session" in the launcher, which is the same name
            // the desktop's own dialog falls back to.
            title: request.title ?? '',
            purpose: SessionPurpose.newSession,
            firstMessage: request.message,
            permissionOverride: mode,
          ),
        );
    return RemoteSessionStarted(
      sessionId: launched.session.id,
      title: launched.session.title,
      // What the row was actually stamped with, read back rather than echoed.
      permissionMode: launched.session.permissionMode,
    );
  } on RemoteApiRefusal {
    rethrow;
  } on Object catch (error) {
    throw RemoteApiRefusal(ErrorCode.badRequest, _sayLaunchFailure(error));
  }
}

/// The desktop's own words for a launch that did not happen — the same
/// readings the Explorer's own error line takes, so a phone and the screen
/// beside it never explain one failure two different ways.
String _sayLaunchFailure(Object error) => switch (error) {
  SessionLaunchRefused() => error.reason,
  SessionDepthRefused() => error.depth.refusal,
  SessionAlreadyRunning() => error.toString(),
  StateError() => error.message,
  ArgumentError() => '${error.message ?? error}',
  _ => '$error',
};

/// Commits the upload and leaves it in the session's own message box.
///
/// **Offered, not sent** — the rule `ComposerDrafts` was written for, and it
/// matters more here than it does for a note: this is a phone telling an agent
/// on somebody's desktop to open a file that has just been written onto that
/// desktop's disk. The path lands where the person sitting at the machine reads
/// it before the agent does, and they press Enter or they do not.
///
/// The conversation is revealed for the same reason `notes_view` reveals it:
/// the composer *is* the conversation, so a group showing its terminal has no
/// box for this to land in.
Future<void> _offerAttachment(
  Ref ref,
  String sessionId,
  String text,
  RemoteAttachmentRef attachment,
) async {
  final store = await ref.read(companionAttachmentStoreProvider.future);
  final File committed;
  try {
    committed = await store.commit(attachment.deviceId, attachment.uploadId);
  } on AttachmentUploadException catch (failure) {
    throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
  }
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  final environmentId = session == null
      ? null
      : ref
            .read(agentInstallationDaoProvider)
            .getById(session.agentInstallationId)
            ?.executable
            .environmentId;
  // The path as the *agent* would spell it. A Windows path handed to a WSL
  // agent names nothing, and constraint 8 forbids working that out implicitly.
  final String visible;
  try {
    visible = _agentVisiblePath(ref, committed.path, environmentId);
  } on PathTranslationException {
    // The translator's own message quotes the path, and a refusal must not:
    // it would put this machine's directory layout — and the name the user
    // picked — on the wire. See [RemoteApiRefusal.message].
    throw const RemoteApiRefusal(
      ErrorCode.internal,
      'this desktop cannot write a file where that agent could open it',
    );
  }
  // The desktop composer's own wording for the same act, so an agent cannot
  // tell which door the file came through — see `message_composer.dart`.
  final body = text.isEmpty
      ? 'Attached image(s):\n$visible'
      : '$text\n\nAttached image(s):\n$visible';
  ref.read(composerDraftProvider.notifier).queue(sessionId, body);
  ref.read(selectedSessionIdProvider.notifier).select(sessionId);
  final paneId = session?.paneId;
  if (paneId != null) {
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .revealConversationForPane(paneId);
  }
}
