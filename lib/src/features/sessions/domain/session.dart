import '../../environments/domain/environment_path.dart';
import '../../settings/domain/permission_mode.dart';
import 'session_launch.dart';
import 'session_lineage.dart';
import 'session_status.dart';

/// A unit of work targeting one repository, run by one agent installation.
///
/// Every session records an explicit, per-session choice of whether it runs in a
/// dedicated Git **worktree** ([useWorktree]) or directly in the repository.
/// When a worktree is used, [worktree] is its location (bound to an
/// environment). Worktree lifecycle itself arrives in Loop 5; in Loop 1 the
/// fields are merely persisted.
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
    this.archivedAt,
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
  /// Deliberately **not** [worktree], which is a narrower and more dangerous
  /// claim: a non-null [worktree] makes [useWorktree] true at launch and is
  /// what `SessionArchiveService` hands to `WorktreeService.remove`, so an
  /// ordinary cwd stored there would eventually offer to delete the user's own
  /// checkout. A session may run in a plain subdirectory of its repository and
  /// have no worktree at all — which is the ordinary case for a session adopted
  /// out of a terminal pane.
  ///
  /// It matters because Claude Code and Codex key their conversation stores by
  /// working directory: resuming in the wrong one may not find the
  /// conversation, and starts a new one wearing this row's title.
  ///
  /// Null means **unknown**, never "the repository root": every row written
  /// before schema v22 is null, and readers fall back to the root themselves
  /// rather than being handed a claim about where the session started.
  final EnvironmentPath? workingDirectory;

  final SessionStatus status;
  final DateTime createdAt;

  /// Session/thread id assigned by the underlying CLI, when it has announced
  /// one. External terminals must resume this id, never the app database id.
  final String? externalSessionId;

  /// The session this one came from, when it came from one.
  ///
  /// The **only** record of spawn depth — see `SessionDepth` for why the depth
  /// itself is walked from this and never stored beside it.
  final String? parentSessionId;

  /// Why [parentSessionId] is set: an agent delegated the work, the user moved
  /// it to another provider, or the user branched the conversation.
  ///
  /// Null in two different situations, and they are told apart by
  /// [parentSessionId]: null-with-no-parent is a root session, and there is no
  /// relationship to name. Null-*with*-a-parent is a row written before schema
  /// v13 whose kind was never recorded — every one of which is in fact a
  /// [SessionLink.spawn], and the v13 migration backfills them, so this shape
  /// should not survive a migrated database.
  final SessionLink? parentLink;

  /// The terminal pane this session runs in, for a [SessionSurface.pane]
  /// session. Null for one launched into a terminal we do not own.
  final String? paneId;

  /// Where the process lives. A runtime fact.
  final SessionSurface surface;

  /// How the session is drawn. A rendering choice the user can flip at any
  /// time; it starts and stops nothing.
  final SessionView view;

  /// How much this session's agent may do without asking.
  ///
  /// Stamped at launch from the per-agent default for the session's
  /// [SessionPurpose], and rewritten when the user overrides it on the composer
  /// control. Once written it is **the** answer for this session: a later
  /// resume runs under the mode the session carries, not under whatever the
  /// global default has since become.
  ///
  /// Null only for rows written before schema v11, which fall back to the
  /// per-agent setting. That is a genuine "we never recorded it", not a
  /// defaulted [PermissionMode.ask] — half those sessions were launched under
  /// something else, and claiming otherwise would be the silent lie this field
  /// exists to remove. See `SessionLauncher.permissionFor`.
  final PermissionMode? permissionMode;

  /// When this session's worktree was archived away, if it was.
  ///
  /// Archiving removes the worktree directory and nothing else — the
  /// transcript, review notes and checkpoints all stay reachable through this
  /// same row. Kept apart from [status], which records what the agent did, not
  /// what was tidied afterwards.
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

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
    PermissionMode? permissionMode,
    DateTime? archivedAt,
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
    archivedAt: archivedAt ?? this.archivedAt,
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
      other.archivedAt == archivedAt;

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
    archivedAt,
  );

  @override
  String toString() => 'Session($id, $title, $status)';
}
