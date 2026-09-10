import 'package:agent_cli/process.dart';
import 'session_launch.dart';
import 'session_lineage.dart';
import 'session_status.dart';

/// A unit of work targeting one repository, run by one agent installation.
/// Every session records an explicit, per-session choice of whether it runs in
/// a dedicated Git **worktree** ([useWorktree]) or directly in the repository.
class Session {
  const Session({
    required this.id,
    required this.repositoryId,
    required this.agentInstallationId,
    required this.title,
    required this.useWorktree,
    required this.status,
    required this.createdAt,
    this.worktree,
    this.workingDirectory,
    this.externalSessionId,
    this.parentSessionId,
    this.parentLink,
    this.paneId,
    this.surface = SessionSurface.pane,
    this.view = SessionView.terminal,
    this.permissionMode,
    this.modelId,
    this.archivedAt,
    this.titleByUser = false,
  });

  final String id;
  final String repositoryId;
  final String agentInstallationId;
  final String title;

  /// Whether this session runs in a dedicated Git worktree.
  final bool useWorktree;

  /// The worktree location when [useWorktree] is true and it has been created;
  /// otherwise `null`.
  final EnvironmentPath? worktree;

  /// The directory this session's agent actually runs in.
  ///
  /// Deliberately **not** [worktree], which is the more dangerous claim: a
  /// non-null [worktree] is what `SessionArchiveService` hands to
  /// `WorktreeService.remove`, so an ordinary cwd there would eventually offer
  /// to delete the user's own checkout. It does *not* decide whether a resume
  /// finds the conversation — see `AgentResumeLocality` — but it is what that
  /// refusal compares against. Null means **unknown**, never the repository
  /// root: pre-v22 rows are null, and readers fall back themselves.
  final EnvironmentPath? workingDirectory;

  final SessionStatus status;
  final DateTime createdAt;

  /// Session/thread id assigned by the underlying CLI, when it has announced
  /// one. External terminals must resume this id, never the app database id.
  final String? externalSessionId;

  /// The session this one came from, when it came from one. The **only** record
  /// of spawn depth — see `SessionDepth` for why depth is walked, never stored.
  final String? parentSessionId;

  /// Why [parentSessionId] is set: an agent delegated the work, the user moved
  /// it to another provider, or the user branched the conversation.
  ///
  /// Null-with-no-parent is a root session. Null-*with*-a-parent is a pre-v13
  /// row whose kind was never recorded — all of them spawns, backfilled by the
  /// v13 migration, so it should not survive a migrated database.
  final SessionLink? parentLink;

  /// The terminal pane this session runs in, for a [SessionSurface.pane]
  /// session. Null for one launched into a terminal we do not own.
  final String? paneId;

  /// Where the process lives. A runtime fact.
  final SessionSurface surface;

  /// How the session is drawn. A rendering choice the user can flip at any
  /// time; it starts and stops nothing.
  final SessionView view;

  /// The mode **chosen for this session**, or null when nobody ever chose one.
  ///
  /// Not "the mode it runs under": that is this resolved against the per-agent
  /// default by `resolveSessionPermission`. Non-null outranks the default at
  /// launch, at resume and across a restart; null follows it *live*, as pre-v11
  /// rows do. Since v35 it is a canonical `PermissionSelection` in the agent's
  /// own vocabulary, so a value this build cannot name is reported rather than
  /// swapped. A launch never stamps the resolved default here — that froze every
  /// session at whatever Settings said, and let the resume path overwrite it.
  final String? permissionMode;

  /// The model **chosen for this session**, as the CLI's own id, or null when
  /// nobody ever chose one.
  ///
  /// Nullable for [permissionMode]'s reason, and the two defaults differ: null
  /// here means "follow the per-agent default in Settings", and when *that* is
  /// unset it means "pass no model flag and let the agent start on whatever it
  /// is configured to use". Both are real states and neither is `sonnet`. A
  /// launch does not stamp the resolved default here either.
  final String? modelId;

  /// When this session's worktree was archived away, if it was. Archiving
  /// removes the worktree directory and nothing else. Kept apart from [status],
  /// which records what the agent did, not what was tidied afterwards.
  final DateTime? archivedAt;

  /// Whether the user typed this title in the app — the only reason the rename
  /// sync leaves a row alone. Recorded rather than remembered: the sync used to
  /// keep it in memory, so after a restart every title looked user-set and a
  /// `/rename` in the CLI was never copied in again.
  final bool titleByUser;

  bool get isArchived => archivedAt != null;

  /// Whether this session is **over**: there is nothing left for it to hold or
  /// to be spoken for.
  ///
  /// [SessionStatus.unknown] is deliberately not one of them — it means "we
  /// lost sight of it", and resuming makes the row `running` again. Shared by
  /// `McpSessionTokenReaper` and `DeviceClaims`, so a session that has stopped
  /// being speakable-for has also stopped holding phones.
  bool get isOver =>
      isArchived ||
      status == SessionStatus.completed ||
      status == SessionStatus.failed ||
      status == SessionStatus.cancelled;

  Session copyWith({
    String? id,
    String? repositoryId,
    String? agentInstallationId,
    String? title,
    bool? useWorktree,
    EnvironmentPath? worktree,
    EnvironmentPath? workingDirectory,
    SessionStatus? status,
    DateTime? createdAt,
    String? externalSessionId,
    String? parentSessionId,
    SessionLink? parentLink,
    String? paneId,
    SessionSurface? surface,
    SessionView? view,
    String? permissionMode,
    String? modelId,
    DateTime? archivedAt,
    bool? titleByUser,
  }) => Session(
    id: id ?? this.id,
    repositoryId: repositoryId ?? this.repositoryId,
    agentInstallationId: agentInstallationId ?? this.agentInstallationId,
    title: title ?? this.title,
    useWorktree: useWorktree ?? this.useWorktree,
    worktree: worktree ?? this.worktree,
    workingDirectory: workingDirectory ?? this.workingDirectory,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    externalSessionId: externalSessionId ?? this.externalSessionId,
    parentSessionId: parentSessionId ?? this.parentSessionId,
    parentLink: parentLink ?? this.parentLink,
    paneId: paneId ?? this.paneId,
    surface: surface ?? this.surface,
    view: view ?? this.view,
    permissionMode: permissionMode ?? this.permissionMode,
    modelId: modelId ?? this.modelId,
    archivedAt: archivedAt ?? this.archivedAt,
    titleByUser: titleByUser ?? this.titleByUser,
  );

  @override
  bool operator ==(Object other) =>
      other is Session &&
      other.id == id &&
      other.repositoryId == repositoryId &&
      other.agentInstallationId == agentInstallationId &&
      other.title == title &&
      other.useWorktree == useWorktree &&
      other.worktree == worktree &&
      other.workingDirectory == workingDirectory &&
      other.status == status &&
      other.createdAt == createdAt &&
      other.externalSessionId == externalSessionId &&
      other.parentSessionId == parentSessionId &&
      other.parentLink == parentLink &&
      other.paneId == paneId &&
      other.surface == surface &&
      other.view == view &&
      other.permissionMode == permissionMode &&
      other.modelId == modelId &&
      other.archivedAt == archivedAt &&
      other.titleByUser == titleByUser;

  @override
  int get hashCode => Object.hash(
    id,
    repositoryId,
    agentInstallationId,
    title,
    useWorktree,
    worktree,
    workingDirectory,
    status,
    createdAt,
    externalSessionId,
    parentSessionId,
    parentLink,
    paneId,
    surface,
    view,
    permissionMode,
    modelId,
    archivedAt,
    titleByUser,
  );

  @override
  String toString() => 'Session($id, $title, $status)';
}
