/// The payload shapes both ends of the session API agree on.
///
/// The host builds these; the companion parses them. Pure Dart, no imports
/// from the sessions feature — status, stage and attention travel as strings
/// so the phone can render values this build has never heard of.
library;

import '../protocol.dart';

/// What one session looks like from a phone: `sessions.list` rows and the
/// `session.changed` event share this shape.
class RemoteSessionSnapshot {
  const RemoteSessionSnapshot({
    required this.sessionId,
    required this.title,
    required this.status,
    this.archived = false,
    this.attention,
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
  });

  final String sessionId;
  final String title;

  /// `SessionStatus.name` on the desktop; opaque here.
  final String status;

  final bool archived;

  /// `needs_approval`, `failed`, or null for "nothing waiting".
  final String? attention;

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

  /// The project this session belongs to — the Explorer's top grouping, so
  /// the phone can draw the same headings the desktop does. Null when the
  /// repository is gone, or from an older host.
  final String? projectId;
  final String? projectName;

  /// The project root as the desktop spells it — a subtitle, never a path to
  /// act on: the phone cannot reach this filesystem.
  final String? projectPath;

  /// Whether the user pinned this session. Pinned sessions sort above the
  /// rest within their row, which is the ordering the host already applies —
  /// the flag exists so the phone can *show* the pin, not re-sort by it.
  final bool pinned;

  /// The session's working folder no longer exists on disk (the Explorer's
  /// own "missing" mark). False also means "we could not tell": the desktop
  /// never falsely flags a folder, and neither does this.
  final bool folderMissing;

  /// Where the agent works, written relative to the project root — the
  /// Explorer row's own subtitle (`projects/app`). Null when it says nothing
  /// the title does not.
  final String? subPath;

  /// The worktree directory when the session runs in one, else null.
  final String? worktree;

  /// The branch checked out where the session works, when the desktop has
  /// **already** measured it. Null means "not measured", never "no branch":
  /// this reads the cached checkout stat and deliberately starts no git.
  final String? branch;

  RemoteSessionSnapshot copyWith({String? attention, String? stage}) =>
      RemoteSessionSnapshot(
        sessionId: sessionId,
        title: title,
        status: status,
        archived: archived,
        attention: attention ?? this.attention,
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
      );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'title': title,
    'status': status,
    'archived': archived,
    if (attention != null) 'attention': attention,
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
      other.branch == branch;

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
    Object.hash(subPath, worktree, branch),
  );
}

/// One transcript line, in the roles the desktop chat view renders.
class RemoteTranscriptMessage {
  const RemoteTranscriptMessage({required this.role, required this.text});

  /// `user`, `agent`, or `error`.
  final String role;
  final String text;

  Map<String, Object?> toJson() => {'role': role, 'text': text};

  static RemoteTranscriptMessage fromJson(Map<String, Object?> json) {
    final role = json['role'];
    final text = json['text'];
    if (role is! String || text is! String) {
      throw const ProtocolException('bad transcript message');
    }
    return RemoteTranscriptMessage(role: role, text: text);
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteTranscriptMessage &&
      other.role == role &&
      other.text == text;

  @override
  int get hashCode => Object.hash(role, text);
}

/// A run of transcript messages plus the cursor to ask after next time.
/// `transcript.get` answers with one; `transcript.appended` carries the delta.
class RemoteTranscriptPage {
  const RemoteTranscriptPage({
    required this.sessionId,
    required this.messages,
    required this.cursor,
  });

  final String sessionId;
  final List<RemoteTranscriptMessage> messages;

  /// Position after the last message here — pass as `after` to resume.
  final int cursor;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'messages': [for (final m in messages) m.toJson()],
    'cursor': cursor,
  };

  static RemoteTranscriptPage fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final messages = json['messages'];
    final cursor = json['cursor'];
    if (sessionId is! String || messages is! List || cursor is! int) {
      throw const ProtocolException('bad transcript page');
    }
    return RemoteTranscriptPage(
      sessionId: sessionId,
      messages: [
        for (final m in messages)
          if (m is Map<String, Object?>) RemoteTranscriptMessage.fromJson(m),
      ],
      cursor: cursor,
    );
  }
}

/// What `approval.requested` carries: the agent's own words, verbatim, or
/// nothing — never a summary this code wrote.
class RemoteApprovalRequest {
  const RemoteApprovalRequest({
    required this.sessionId,
    this.evidence = const [],
    this.approveLabel,
    this.denyLabel,
  });

  final String sessionId;
  final List<String> evidence;

  /// The answers the agent itself names. A missing label means that answer
  /// does not exist for this agent, not that the phone should invent one.
  final String? approveLabel;
  final String? denyLabel;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'evidence': evidence,
    if (approveLabel != null) 'approve': approveLabel,
    if (denyLabel != null) 'deny': denyLabel,
  };

  static RemoteApprovalRequest fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String) {
      throw const ProtocolException('bad approval request');
    }
    final evidence = json['evidence'];
    return RemoteApprovalRequest(
      sessionId: sessionId,
      evidence: [
        if (evidence is List)
          for (final line in evidence)
            if (line is String) line,
      ],
      approveLabel: json['approve'] is String
          ? json['approve']! as String
          : null,
      denyLabel: json['deny'] is String ? json['deny']! as String : null,
    );
  }
}

/// What `host.status` carries on connect.
class RemoteHostStatus {
  const RemoteHostStatus({required this.versions, required this.hostName});

  final VersionRange versions;
  final String hostName;

  Map<String, Object?> toJson() => {
    'versions': versions.toJson(),
    'host': hostName,
  };

  static RemoteHostStatus fromJson(Map<String, Object?> json) {
    final versions = json['versions'];
    if (versions is! Map<String, Object?>) {
      throw const ProtocolException('bad host status');
    }
    return RemoteHostStatus(
      versions: VersionRange.fromJson(versions),
      hostName: json['host'] is String ? json['host']! as String : '',
    );
  }
}
