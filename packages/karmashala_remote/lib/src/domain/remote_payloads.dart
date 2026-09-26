/// The payload shapes both ends of the session API agree on. Status, stage and
/// attention travel as strings so the phone can render values this build has
/// never heard of.
library;

import '../client/relay_candidates.dart';
import '../protocol.dart';

part 'remote_payloads/remote_attachment_payloads.dart';
part 'remote_payloads/remote_question_payloads.dart';
part 'remote_payloads/remote_start_payloads.dart';
part 'remote_payloads/remote_transcript_payloads.dart';

/// The one attention word that means "a prompt is waiting on a person".
const String kAttentionNeedsApproval = 'needs_approval';

/// The attention word for a session whose turn ended on its usage limit — in a
/// push, and as the phone's own reading of `RemoteSessionSnapshot.usageLimit`.
/// An older phone reads it as "needs you", the safe direction.
const String kAttentionUsageLimit = 'usage_limit';

/// What one session looks like from a phone: `sessions.list` rows and the
/// `session.changed` event share this shape.
class RemoteSessionSnapshot {
  const RemoteSessionSnapshot({
    required this.sessionId,
    required this.title,
    required this.status,
    this.archived = false,
    this.attention,
    this.activity,
    this.stage,
    this.repositoryId,
    this.repositoryName,
    this.createdAt,
    this.agentLabel,
    this.whereabouts,
    this.lastActivityAt,
    this.imported = false,
    this.projectId,
    this.projectName,
    this.projectPath,
    this.pinned = false,
    this.folderMissing = false,
    this.subPath,
    this.worktree,
    this.branch,
    this.attachments,
    this.environmentBadge,
    this.environmentName,
    this.environmentId,
    this.environmentKind,
    this.model,
    this.usageLimit,
  });

  final String sessionId;
  final String title;

  /// `SessionStatus.name` on the desktop; opaque here.
  final String status;

  final bool archived;

  /// [kAttentionNeedsApproval], `failed`, or null for "nothing waiting".
  final String? attention;

  /// **What the agent in a running session is doing** — `working`, `idle`,
  /// `awaitingApproval`, `failed` or `unknown` (`AgentActivityStatus.name`) —
  /// as whoever keeps its status says, or null when nobody does. [status] is
  /// the process's lifecycle: `running` covers an agent at rest at its own
  /// prompt as much as one mid-turn, and only this tells them apart.
  final String? activity;

  /// `DeliveryStage.name`, or null for "could not tell" — which is a
  /// first-class answer, never smoothed into a guess.
  final String? stage;

  final String? repositoryId;
  final String? repositoryName;

  /// ISO-8601 UTC, when known.
  final String? createdAt;

  /// The desktop card's first line, worded by the host ("Claude Code ·
  /// running") so the phone never invents a claim. Null from an older host.
  final String? agentLabel;

  /// The desktop's whereabouts clause, verbatim ("running here"), or null
  /// when there is nothing worth saying — a first-class answer.
  final String? whereabouts;

  /// When the newest evidence about this session was produced, ISO-8601 UTC.
  final String? lastActivityAt;

  /// True for a CLI session imported as read-only history.
  final bool imported;

  /// The Explorer's top grouping. Null when the repository is gone, or from an
  /// older host.
  final String? projectId;
  final String? projectName;

  /// The project root as the desktop spells it — a subtitle, never a path to
  /// act on: the phone cannot reach this filesystem.
  final String? projectPath;

  /// Whether the user pinned this session. The host already applies the order;
  /// the flag exists so the phone can *show* the pin, not re-sort by it.
  final bool pinned;

  /// The session's working folder no longer exists on disk. False also means
  /// "we could not tell": neither end falsely flags a folder.
  final bool folderMissing;

  /// Where the agent works, relative to the project root. Null when it says
  /// nothing the title does not.
  final String? subPath;

  /// The worktree directory when the session runs in one, else null.
  final String? worktree;

  /// The branch where the session works, when the desktop has already measured
  /// it. Null means "not measured", never "no branch" — this starts no git.
  final String? branch;

  /// What a file sent to **this** session may be — a per-session answer, not a
  /// per-desktop one. Null is an older host that was never asked, and the phone
  /// then offers nothing.
  final RemoteAttachmentSupport? attachments;

  /// The badge on a non-local session card ("WSL · Ubuntu"); null for local.
  final String? environmentBadge;

  /// What the desktop calls the machine this runs on — "macOS", "Windows",
  /// "Ubuntu". Sent **because [environmentBadge] is deliberately null for the
  /// local host**: a badge is what tells a session card apart from the host the
  /// user is sitting at, but the phone is not sitting at it, and the machine
  /// still needs a name there. Without this the machine list fell back to
  /// [environmentId], whose value for the local host is the literal `windows`
  /// on every platform — so a Mac appeared in the picker as "windows".
  ///
  /// Null from a desktop older than this field; the phone then shows what it
  /// can and never invents a name.
  final String? environmentName;

  /// The desktop's own id for the machine this runs on, and what kind it is.
  /// **Both null from a desktop older than this field** — the phone groups by
  /// name then and never invents an id, which would collide across desktops.
  final String? environmentId;
  final String? environmentKind;

  /// The model the desktop launched this session on — the one chosen for it,
  /// or the configured default it follows. Null when neither names one: the
  /// agent's own default is not known here, and is not guessed.
  final String? model;

  /// The desktop's sentence while this session sits on a usage limit — "Codex
  /// hit its 5-hour limit. Resets 14:05." — else null.
  final String? usageLimit;

  /// [clearAttention] because "nothing is waiting" is a value a null argument
  /// cannot express, and an approval being answered is exactly that move.
  RemoteSessionSnapshot copyWith({
    String? attention,
    String? stage,
    bool clearAttention = false,
    String? environmentBadge,
  }) => RemoteSessionSnapshot(
    sessionId: sessionId,
    title: title,
    status: status,
    archived: archived,
    attention: clearAttention ? null : (attention ?? this.attention),
    activity: activity,
    stage: stage ?? this.stage,
    repositoryId: repositoryId,
    repositoryName: repositoryName,
    createdAt: createdAt,
    agentLabel: agentLabel,
    whereabouts: whereabouts,
    lastActivityAt: lastActivityAt,
    imported: imported,
    projectId: projectId,
    projectName: projectName,
    projectPath: projectPath,
    pinned: pinned,
    folderMissing: folderMissing,
    subPath: subPath,
    worktree: worktree,
    branch: branch,
    attachments: attachments,
    environmentBadge: environmentBadge ?? this.environmentBadge,
    environmentName: environmentName,
    environmentId: environmentId,
    environmentKind: environmentKind,
    model: model,
    usageLimit: usageLimit,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'title': title,
    'status': status,
    'archived': archived,
    if (attention != null) 'attention': attention,
    if (activity != null) 'activity': activity,
    if (stage != null) 'stage': stage,
    if (repositoryId != null) 'repositoryId': repositoryId,
    if (repositoryName != null) 'repositoryName': repositoryName,
    if (createdAt != null) 'createdAt': createdAt,
    if (agentLabel != null) 'agentLabel': agentLabel,
    if (whereabouts != null) 'whereabouts': whereabouts,
    if (lastActivityAt != null) 'lastActivityAt': lastActivityAt,
    if (imported) 'imported': imported,
    if (projectId != null) 'projectId': projectId,
    if (projectName != null) 'projectName': projectName,
    if (projectPath != null) 'projectPath': projectPath,
    // Omitted when false, so an unpinned row's bytes stay the old shape.
    if (pinned) 'pinned': pinned,
    if (folderMissing) 'folderMissing': folderMissing,
    if (subPath != null) 'subPath': subPath,
    if (worktree != null) 'worktree': worktree,
    if (branch != null) 'branch': branch,
    if (attachments != null) 'attach': attachments!.toJson(),
    if (environmentBadge != null) 'environmentBadge': environmentBadge,
    if (environmentName != null) 'environmentName': environmentName,
    if (environmentId != null) 'environmentId': environmentId,
    if (environmentKind != null) 'environmentKind': environmentKind,
    if (model != null) 'model': model,
    if (usageLimit != null) 'usageLimit': usageLimit,
  };

  static RemoteSessionSnapshot fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final title = json['title'];
    final status = json['status'];
    if (sessionId is! String || title is! String || status is! String) {
      throw const ProtocolException('bad session snapshot');
    }
    String? str(Object? v) => v is String ? v : null;
    return RemoteSessionSnapshot(
      sessionId: sessionId,
      title: title,
      status: status,
      archived: json['archived'] == true,
      attention: str(json['attention']),
      activity: str(json['activity']),
      stage: str(json['stage']),
      repositoryId: str(json['repositoryId']),
      repositoryName: str(json['repositoryName']),
      createdAt: str(json['createdAt']),
      agentLabel: str(json['agentLabel']),
      whereabouts: str(json['whereabouts']),
      lastActivityAt: str(json['lastActivityAt']),
      imported: json['imported'] == true,
      projectId: str(json['projectId']),
      projectName: str(json['projectName']),
      projectPath: str(json['projectPath']),
      pinned: json['pinned'] == true,
      folderMissing: json['folderMissing'] == true,
      subPath: str(json['subPath']),
      worktree: str(json['worktree']),
      branch: str(json['branch']),
      attachments: RemoteAttachmentSupport.parse(json['attach']),
      environmentBadge: str(json['environmentBadge']),
      environmentName: str(json['environmentName']),
      environmentId: str(json['environmentId']),
      environmentKind: str(json['environmentKind']),
      model: str(json['model']),
      usageLimit: str(json['usageLimit']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteSessionSnapshot &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.status == status &&
      other.archived == archived &&
      other.attention == attention &&
      other.activity == activity &&
      other.stage == stage &&
      other.repositoryId == repositoryId &&
      other.repositoryName == repositoryName &&
      other.createdAt == createdAt &&
      other.agentLabel == agentLabel &&
      other.whereabouts == whereabouts &&
      other.lastActivityAt == lastActivityAt &&
      other.imported == imported &&
      other.projectId == projectId &&
      other.projectName == projectName &&
      other.projectPath == projectPath &&
      other.pinned == pinned &&
      other.folderMissing == folderMissing &&
      other.subPath == subPath &&
      other.worktree == worktree &&
      other.branch == branch &&
      other.attachments == attachments &&
      other.environmentBadge == environmentBadge &&
      other.environmentName == environmentName &&
      other.environmentId == environmentId &&
      other.environmentKind == environmentKind &&
      other.model == model &&
      other.usageLimit == usageLimit;

  @override
  int get hashCode => Object.hash(
    sessionId,
    title,
    status,
    archived,
    attention,
    stage,
    repositoryId,
    repositoryName,
    createdAt,
    agentLabel,
    whereabouts,
    lastActivityAt,
    imported,
    projectId,
    projectName,
    projectPath,
    pinned,
    folderMissing,
    Object.hash(
      activity,
      subPath,
      worktree,
      branch,
      attachments,
      environmentBadge,
      environmentName,
      environmentId,
      environmentKind,
      model,
      usageLimit,
    ),
  );
}
