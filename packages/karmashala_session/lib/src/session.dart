import 'package:agent_cli/process.dart';
import 'record_json.dart';
import 'session_launch.dart';
import 'session_lineage.dart';
import 'session_status.dart';

/// A unit of work targeting one repository, run by one agent installation, with
/// an explicit per-session choice of worktree or repository root.
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
    this.worktreeRemovedAt,
    this.titleByUser = false,
    this.operatorGranted = false,
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

  /// The directory this session's agent actually runs in — deliberately **not**
  /// [worktree], which archiving deletes. Null means unknown, not the root.
  final EnvironmentPath? workingDirectory;

  final SessionStatus status;
  final DateTime createdAt;

  /// Session/thread id assigned by the underlying CLI, when it has announced
  /// one. External terminals must resume this id, never the app database id.
  final String? externalSessionId;

  /// The session this one came from, when it came from one. The **only** record
  /// of spawn depth — see `SessionDepth` for why depth is walked, never stored.
  final String? parentSessionId;

  /// Why [parentSessionId] is set. Null *with* a parent is a pre-v13 row, all
  /// of them spawns, backfilled by the v13 migration.
  final SessionLink? parentLink;

  /// The terminal pane this session runs in, for a [SessionSurface.pane]
  /// session. Null for one launched into a terminal we do not own.
  final String? paneId;

  /// Where the process lives. A runtime fact.
  final SessionSurface surface;

  /// How the session is drawn. A rendering choice the user can flip at any
  /// time; it starts and stops nothing.
  final SessionView view;

  /// The mode **chosen for this session**, or null to follow the per-agent
  /// default *live*. A launch never stamps the resolved default here.
  final String? permissionMode;

  /// The model **chosen for this session**, as the CLI's own id, or null to
  /// follow the default; when that is unset, no model flag is passed at all.
  final String? modelId;

  /// When this session was archived — hidden from the lists, nothing else.
  final DateTime? archivedAt;

  /// When its worktree directory was removed ("Archive worktree"), which also
  /// archives it. Unarchiving never brings the directory back.
  final DateTime? worktreeRemovedAt;

  /// Whether the user typed this title in the app — the only reason the rename
  /// sync leaves a row alone. Recorded, not remembered: a restart forgot it.
  final bool titleByUser;

  /// Whether the person let this session's agent **operate Karmashala**: the
  /// tools that act — start, send to or end sessions, run terminals, restore
  /// checkpoints, drive devices, builds — beyond reading and its own records.
  /// Off until granted, per session (owner, 2026-10-01).
  final bool operatorGranted;

  /// The row on the wire, as the server's data API carries it.
  Map<String, Object?> toJson() => {
    'id': id,
    'repositoryId': repositoryId,
    'agentInstallationId': agentInstallationId,
    'title': title,
    'useWorktree': useWorktree,
    if (worktree case final worktree?) 'worktree': jsonPath(worktree),
    if (workingDirectory case final directory?)
      'workingDirectory': jsonPath(directory),
    'status': status.name,
    'createdAt': jsonDate(createdAt),
    'externalSessionId': ?externalSessionId,
    'parentSessionId': ?parentSessionId,
    'parentLink': ?parentLink?.name,
    'paneId': ?paneId,
    'surface': surface.name,
    'view': view.name,
    'permissionMode': ?permissionMode,
    'modelId': ?modelId,
    if (archivedAt case final at?) 'archivedAt': jsonDate(at),
    if (worktreeRemovedAt case final at?) 'worktreeRemovedAt': jsonDate(at),
    'titleByUser': titleByUser,
    if (operatorGranted) 'operatorGranted': true,
  };

  /// Throws [FormatException] on a row out of shape. A word this build does
  /// not know reads as the store reads it: `unknown`, `external`, `terminal`.
  static Session fromJson(Map<String, Object?> json) => Session(
    id: jsonString(json, 'id'),
    repositoryId: jsonString(json, 'repositoryId'),
    agentInstallationId: jsonString(json, 'agentInstallationId'),
    title: jsonString(json, 'title'),
    useWorktree: jsonBool(json, 'useWorktree'),
    worktree: jsonOptionalPathOf(json, 'worktree'),
    workingDirectory: jsonOptionalPathOf(json, 'workingDirectory'),
    status: jsonEnum(
      SessionStatus.values,
      json['status'],
      SessionStatus.unknown,
    ),
    createdAt: jsonDateOf(json, 'createdAt'),
    externalSessionId: jsonOptionalString(json, 'externalSessionId'),
    parentSessionId: jsonOptionalString(json, 'parentSessionId'),
    parentLink: SessionLink.parse(jsonOptionalString(json, 'parentLink')),
    paneId: jsonOptionalString(json, 'paneId'),
    surface: jsonEnum(
      SessionSurface.values,
      json['surface'],
      SessionSurface.external,
    ),
    view: jsonEnum(SessionView.values, json['view'], SessionView.terminal),
    permissionMode: jsonOptionalString(json, 'permissionMode'),
    modelId: jsonOptionalString(json, 'modelId'),
    archivedAt: jsonOptionalDateOf(json, 'archivedAt'),
    worktreeRemovedAt: jsonOptionalDateOf(json, 'worktreeRemovedAt'),
    titleByUser: jsonBool(json, 'titleByUser'),
    // Absent from an older server's rows: not granted.
    operatorGranted: json['operatorGranted'] == true,
  );

  bool get isArchived => archivedAt != null;

  /// Whether its worktree directory is gone — never read it, resume in it or
  /// offer to remove it again.
  bool get worktreeRemoved => worktreeRemovedAt != null;

  /// Whether this session is **over**. [SessionStatus.unknown] is deliberately
  /// not one: resuming makes the row `running` again.
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
    DateTime? worktreeRemovedAt,
    bool? titleByUser,
    bool? operatorGranted,
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
    worktreeRemovedAt: worktreeRemovedAt ?? this.worktreeRemovedAt,
    titleByUser: titleByUser ?? this.titleByUser,
    operatorGranted: operatorGranted ?? this.operatorGranted,
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
      other.worktreeRemovedAt == worktreeRemovedAt &&
      other.titleByUser == titleByUser &&
      other.operatorGranted == operatorGranted;

  @override
  int get hashCode => Object.hashAll([
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
    worktreeRemovedAt,
    titleByUser,
    operatorGranted,
  ]);

  @override
  String toString() => 'Session($id, $title, $status)';
}
