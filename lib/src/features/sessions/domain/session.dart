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

  /// The mode **chosen for this session**, or null when nobody ever chose one.
  ///
  /// Not "the mode it runs under": that is [permissionMode] resolved against
  /// the per-agent default, which is `resolveSessionPermission` and lives in
  /// `session_permission.dart`. This field records only the decision, and its
  /// nullability is load-bearing:
  ///
  /// * **Non-null** — someone picked this mode for this session (the composer
  ///   chip, "Continue with…", a caller that resolved one). It outranks the
  ///   global default at launch and at resume, after the default is changed,
  ///   and across a restart.
  /// * **Null** — no choice was made, so the session follows the per-agent
  ///   default *live* and moves with it. Rows written before schema v11 are
  ///   also null and get the same treatment, which is honest: half of them were
  ///   launched under something other than [PermissionMode.ask], and a
  ///   defaulted value here would be a claim about them we cannot make.
  ///
  /// A launch deliberately does **not** stamp the resolved default here. Doing
  /// so made every session read as having chosen, froze it at whatever Settings
  /// said the day it started, and — because the resume path rewrote this column
  /// from the setting — quietly discarded the choices that had really been
  /// made. Both halves of the owner's report: "existing session permission mode
  /// should be overridable in each session. but settings is taking precedence."
  final PermissionMode? permissionMode;

  /// The model **chosen for this session**, as the CLI's own id, or null when
  /// nobody ever chose one.
  ///
  /// Nullable for exactly [permissionMode]'s reason, and the reason is worth
  /// restating because the two defaults differ: null here means "follow the
  /// per-agent default in Settings", and when *that* is unset it means "pass no
  /// model flag and let the agent start on whatever it is configured to use".
  /// Both are real states and neither is `sonnet`.
  ///
  /// A launch deliberately does not stamp the resolved default here. Doing so
  /// would freeze every session on whichever model Settings named the day it
  /// started, which is the bug `permissionMode` above documents having had.
  final String? modelId;

  /// When this session's worktree was archived away, if it was.
  ///
  /// Archiving removes the worktree directory and nothing else — the
  /// transcript, review notes and checkpoints all stay reachable through this
  /// same row. Kept apart from [status], which records what the agent did, not
  /// what was tidied afterwards.
  final DateTime? archivedAt;

  /// Whether the user typed this title in the app.
  ///
  /// The one thing that makes a title theirs rather than the CLI's, and the
  /// only reason the rename sync leaves a row alone. It is recorded rather than
  /// remembered because the sync used to keep it in memory: after a restart
  /// every title looked user-set, so a `/rename` in the CLI was never copied in
  /// again — the owner's report.
  final bool titleByUser;

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
