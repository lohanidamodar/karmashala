/// The production wiring of [RemoteHostBindings]: every function points at
/// the SAME provider the desktop UI reads, so the phone and the screen can
/// never tell a different story about one session.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_registry.dart';
import '../../agents/domain/agent_status.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
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
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_resume_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_attribution.dart';
import '../../sessions/domain/session_event_types.dart';
import '../../sessions/domain/session_launch.dart';
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

final remoteHostBindingsProvider = Provider<RemoteHostBindings>((ref) {
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
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
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
    );
  }

  ImportedSession? importedById(String sessionId) =>
      ref.read(importedSessionDaoProvider).getById(sessionId);

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
    for (final session in ref.read(importedSessionDaoProvider).getAll()) {
      if (placed.add(session.id)) out.add(importedSnapshotOf(session));
    }
    return out;
  }

  return RemoteHostBindings(
    hostName: Platform.localHostname,
    listSessions: listSessionsInExplorerOrder,
    sessionById: (sessionId) {
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session != null) return snapshotOf(session);
      final imported = importedById(sessionId);
      return imported == null ? null : importedSnapshotOf(imported);
    },
    deliveryStageFor: (sessionId) =>
        ref.read(remoteDeliveryStageProvider)(sessionId),
    transcriptFor: (sessionId) => _transcriptFor(ref, sessionId),
    // The composer's own route: `continueSession` types into the live PTY or
    // resumes the engine session, exactly as the desktop send button does.
    // Async so an imported-session refusal is a failed future, never a
    // synchronous escape past a caller's error handling.
    sendPrompt: (sessionId, text) async {
      if (importedById(sessionId) != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — read-only here; '
          'continue it in its own terminal',
        );
      }
      return ref.read(sessionActionsProvider).continueSession(sessionId, text);
    },
    answerApproval: (sessionId, decision) async {
      if (importedById(sessionId) != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — answer it in its own '
          'terminal',
        );
      }
      return _answerApproval(ref, sessionId, decision);
    },
    approvalEvidenceFor: (sessionId) => _approvalEvidenceFor(ref, sessionId),
    registerPush: (deviceId, token, platform) async {
      ref
          .read(pairedDeviceDaoProvider)
          .updatePush(deviceId, token: token, platform: platform);
      ref.read(pairedDevicesRevisionProvider.notifier).bump();
    },
  );
});

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

/// The same source selection as `SessionTranscriptView`: a PTY-hosted
/// session renders from the agent's own record; anything else renders from
/// the engine's event log. Attribution is REBUILT from the parent session's
/// typed fields and stripped on a whole-string match — never parsed out of
/// the text (the dray constraint).
Future<RemoteTranscriptPage> _transcriptFor(Ref ref, String sessionId) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) {
    final imported = ref.read(importedSessionDaoProvider).getById(sessionId);
    if (imported != null) return _importedTranscript(imported);
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  var messages = session.surface == SessionSurface.pane
      ? await _agentRecordMessages(ref, session)
      : _eventLogMessages(ref, sessionId);

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
  return RemoteTranscriptPage(
    sessionId: sessionId,
    messages: messages,
    cursor: messages.length,
  );
}

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

/// The agent's own transcript file — `sessionChatTranscriptProvider`'s source,
/// read once rather than polled. Tool rows are dropped, as the desktop chat
/// view drops them.
Future<List<RemoteTranscriptMessage>> _agentRecordMessages(
  Ref ref,
  Session session,
) async {
  final externalId = session.externalSessionId;
  if (externalId == null || externalId.isEmpty) return const [];
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  if (agentId == null) return const [];
  if (!agentSupportsChatView(ref.read(agentRegistryProvider).byId(agentId))) {
    return const [];
  }
  final path = await ref
      .read(sessionTranscriptLocatorProvider)
      .locate(agentId: agentId, externalSessionId: externalId);
  if (path == null) return const [];
  final messages = await readCliTranscript(path, agentId);
  return [
    for (final message in messages)
      if (message.role != 'tool')
        RemoteTranscriptMessage(role: message.role, text: message.text),
  ];
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
  return RemoteApprovalRequest(
    sessionId: sessionId,
    evidence: report?.status == AgentActivityStatus.awaitingApproval
        ? report!.evidence
        : const [],
    approveLabel: rules?.approve?.label,
    denyLabel: rules?.deny?.label,
  );
}
