/// The payload shapes both ends of the session API agree on. Status, stage and
/// attention travel as strings so the phone can render values this build has
/// never heard of.
library;

import '../client/relay_candidates.dart';
import '../protocol.dart';

/// The one attention word that means "a prompt is waiting on a person".
const String kAttentionNeedsApproval = 'needs_approval';

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
    this.attachments,
    this.environmentBadge,
    this.environmentName,
    this.environmentId,
    this.environmentKind,
  });

  final String sessionId;
  final String title;

  /// `SessionStatus.name` on the desktop; opaque here.
  final String status;

  final bool archived;

  /// [kAttentionNeedsApproval], `failed`, or null for "nothing waiting".
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
    if (attachments != null) 'attach': attachments!.toJson(),
    if (environmentBadge != null) 'environmentBadge': environmentBadge,
    if (environmentName != null) 'environmentName': environmentName,
    if (environmentId != null) 'environmentId': environmentId,
    if (environmentKind != null) 'environmentKind': environmentKind,
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
      attachments: RemoteAttachmentSupport.parse(json['attach']),
      environmentBadge: str(json['environmentBadge']),
      environmentName: str(json['environmentName']),
      environmentId: str(json['environmentId']),
      environmentKind: str(json['environmentKind']),
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
      other.branch == branch &&
      other.attachments == attachments &&
      other.environmentBadge == environmentBadge &&
      other.environmentName == environmentName &&
      other.environmentId == environmentId &&
      other.environmentKind == environmentKind;

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
      subPath,
      worktree,
      branch,
      attachments,
      environmentBadge,
      environmentName,
      environmentId,
      environmentKind,
    ),
  );
}

/// What a file sent to one session may be, or the host's sentence for why none
/// may be. The host words the refusal because only it knows which of the several
/// reasons applies.
class RemoteAttachmentSupport {
  const RemoteAttachmentSupport({
    required this.mediaTypes,
    required this.maxBytes,
    this.refusal,
  });

  /// Nothing may be sent here, and this is why — in the host's own words.
  const RemoteAttachmentSupport.refused(String reason)
    : mediaTypes = const [],
      maxBytes = 0,
      refusal = reason;

  /// The exact media types the agent will look at. Never a wildcard: the phone
  /// hands one of these back verbatim and the host matches it literally.
  final List<String> mediaTypes;

  /// The largest file this session will take, in bytes. Never above
  /// [kMaxAttachmentBytes]; may be below it.
  final int maxBytes;

  /// Why [mediaTypes] is empty, when the host can say. Null with an empty list
  /// means it had no words for it.
  final String? refusal;

  bool get allowsAnything => mediaTypes.isNotEmpty && maxBytes > 0;

  Map<String, Object?> toJson() => {
    'types': mediaTypes,
    'max': maxBytes,
    if (refusal != null) 'why': refusal,
  };

  /// An absent or malformed value reads as null — *we were not told* — which
  /// is not the same as being told nothing is allowed.
  static RemoteAttachmentSupport? parse(Object? json) {
    if (json is! Map) return null;
    final max = json['max'];
    final why = json['why'];
    return RemoteAttachmentSupport(
      mediaTypes: [
        for (final type in (json['types'] as List? ?? const []))
          if (type is String && type.isNotEmpty) type,
      ],
      maxBytes: max is int && max > 0 ? max : 0,
      refusal: why is String && why.isNotEmpty ? why : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteAttachmentSupport &&
      other.maxBytes == maxBytes &&
      other.refusal == refusal &&
      other.mediaTypes.length == mediaTypes.length &&
      other.mediaTypes.every(mediaTypes.contains);

  @override
  int get hashCode =>
      Object.hash(maxBytes, refusal, Object.hashAll(mediaTypes));
}

/// What became of a prompt: typed into the agent, or left in the desktop's own
/// message box. Told rather than inferred, because "sent" would be false for
/// the second.
enum RemotePromptDelivery {
  sent('sent'),
  offered('offered');

  const RemotePromptDelivery(this.wire);

  final String wire;

  /// An unknown word from a newer host reads as [sent] — the behaviour every
  /// build before this one had.
  static RemotePromptDelivery parse(Object? wire) =>
      wire == offered.wire ? offered : sent;
}

/// The phone declaring a file before any of it is sent.
class RemoteAttachmentBegin {
  const RemoteAttachmentBegin({
    required this.sessionId,
    required this.name,
    required this.mediaType,
    required this.bytes,
  });

  final String sessionId;

  /// The file's name as the phone knows it. **A hint, never a path**: the host
  /// keeps a sanitised basename and puts its own extension on.
  final String name;

  /// One of the session's [RemoteAttachmentSupport.mediaTypes], exactly.
  final String mediaType;

  /// The whole file's length, declared up front so the host can refuse an
  /// oversized file before a byte crosses.
  final int bytes;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'name': name,
    'type': mediaType,
    'bytes': bytes,
  };

  static RemoteAttachmentBegin fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final name = json['name'];
    final type = json['type'];
    final bytes = json['bytes'];
    if (sessionId is! String ||
        name is! String ||
        type is! String ||
        bytes is! int) {
      throw const ProtocolException('bad attachment request');
    }
    return RemoteAttachmentBegin(
      sessionId: sessionId,
      name: name,
      mediaType: type,
      bytes: bytes,
    );
  }
}

/// The host agreeing to take a file, and saying how to hand it over.
class RemoteAttachmentOffer {
  const RemoteAttachmentOffer({
    required this.uploadId,
    required this.chunkBytes,
  });

  /// Names this upload for the life of the link. Nothing is a file until a
  /// `prompt.send` quotes it, and nothing outside that link can quote it.
  final String uploadId;

  /// Raw bytes per `attachment.chunk`. Sent rather than assumed so an older
  /// phone and a newer host cannot disagree about it.
  final int chunkBytes;

  Map<String, Object?> toJson() => {
    'uploadId': uploadId,
    'chunkBytes': chunkBytes,
  };

  static RemoteAttachmentOffer fromJson(Map<String, Object?> json) {
    final uploadId = json['uploadId'];
    final chunk = json['chunkBytes'];
    if (uploadId is! String || uploadId.isEmpty || chunk is! int || chunk < 1) {
      throw const ProtocolException('bad attachment offer');
    }
    return RemoteAttachmentOffer(uploadId: uploadId, chunkBytes: chunk);
  }
}

/// One transcript line, in the roles the desktop chat view renders.
class RemoteTranscriptMessage {
  const RemoteTranscriptMessage({required this.role, required this.text});

  /// `user`, `agent`, `error`, or `tool` — the last for a row the host folded
  /// down (a task-notification envelope), never for a turn somebody took.
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

/// Why a transcript page carries nothing — a fact, never a sentence, so an
/// older phone falls back to the hedge rather than rendering a word it cannot
/// place. `absence` keeps the coarse word every build understands and
/// `absenceKind` refines it beside.
enum RemoteTranscriptAbsence {
  /// The agent keeps no record this app can read, so there is no chat view for
  /// this session at all — not now, and not after it answers.
  noChatView('no_chat_view'),

  /// The store kept the conversation and no readable transcript beside it.
  /// Structural like [noChatView], but about the conversation, not the agent.
  noTranscriptFile('no_transcript_file', olderWire: 'no_chat_view');

  const RemoteTranscriptAbsence(this.wire, {this.olderWire});

  final String wire;

  /// The word a build that predates this value reads it as, or null when this
  /// value *is* that word.
  final String? olderWire;

  /// What goes in `absence`: the coarsest true word for this fact.
  String get coarseWire => olderWire ?? wire;

  /// The refinement first, then the coarse word beside it. An absent or
  /// unrecognised coarse word reads as null — *we were not told why*.
  static RemoteTranscriptAbsence? parse(Object? wire, {Object? refinement}) =>
      _byWire[refinement] ?? _byWire[wire];

  static final Map<Object?, RemoteTranscriptAbsence> _byWire = {
    for (final value in RemoteTranscriptAbsence.values) value.wire: value,
  };
}

/// A run of transcript messages plus the cursor to ask after next time.
/// `transcript.get` answers with one; `transcript.appended` carries the delta.
class RemoteTranscriptPage {
  const RemoteTranscriptPage({
    required this.sessionId,
    required this.messages,
    required this.cursor,
    this.omitted = 0,
    this.hasNewer = false,
    this.absence,
  });

  final String sessionId;
  final List<RemoteTranscriptMessage> messages;

  /// Position after the last message here — pass as `after` to resume.
  final int cursor;

  /// How many messages before [messages] the host did not send. A long
  /// conversation cannot cross in one frame, so the host sends the tail and
  /// says how much it kept back. Zero from an older host, which was complete.
  final int omitted;

  /// Whether the host holds messages **after** [cursor] that this page could
  /// not carry — the end condition of a gap recovery. Inferring it from a full
  /// page would stop one page early. Absent from an older host reads as false.
  final bool hasNewer;

  /// Why [messages] is empty, when the host knows. Null means it did not say —
  /// an older host, or a nothing it cannot account for either.
  final RemoteTranscriptAbsence? absence;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'messages': [for (final m in messages) m.toJson()],
    'cursor': cursor,
    if (omitted > 0) 'omitted': omitted,
    if (hasNewer) 'hasNewer': true,
    // The coarse word first and always, so an older phone gets a sentence.
    if (absence != null) 'absence': absence!.coarseWire,
    if (absence != null && absence!.olderWire != null)
      'absenceKind': absence!.wire,
  };

  static RemoteTranscriptPage fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final messages = json['messages'];
    final cursor = json['cursor'];
    if (sessionId is! String || messages is! List || cursor is! int) {
      throw const ProtocolException('bad transcript page');
    }
    final omitted = json['omitted'];
    return RemoteTranscriptPage(
      omitted: omitted is int && omitted > 0 ? omitted : 0,
      hasNewer: json['hasNewer'] == true,
      absence: RemoteTranscriptAbsence.parse(
        json['absence'],
        refinement: json['absenceKind'],
      ),
      sessionId: sessionId,
      messages: [
        for (final m in messages)
          if (m is Map<String, Object?>) RemoteTranscriptMessage.fromJson(m),
      ],
      cursor: cursor,
    );
  }
}

/// Why an activity answer carries no calls, when the host can say. A fact,
/// never a sentence — the same split [RemoteTranscriptAbsence] is built to.
enum RemoteActivityAbsence {
  /// The session is working and nothing the host can read records what on.
  noRecord('no_record');

  const RemoteActivityAbsence(this.wire);

  final String wire;

  /// An absent or unrecognised word reads as null — *we were not told why*.
  static RemoteActivityAbsence? parse(Object? wire) => _byWire[wire];

  static final Map<Object?, RemoteActivityAbsence> _byWire = {
    for (final value in RemoteActivityAbsence.values) value.wire: value,
  };
}

/// One call the agent has issued and not yet answered.
class RemoteActivityCall {
  const RemoteActivityCall({
    required this.summary,
    required this.toolName,
    required this.startedAt,
    this.subagent = false,
  });

  /// The line the desktop transcript already prints — `Bash(git status)`. For a
  /// shell call that line **is** the command.
  final String summary;

  /// The tool's own name, so the phone can ask what kind of call this is
  /// without parsing [summary] back apart.
  final String toolName;

  /// Whether this is another agent rather than a tool. A fact rather than
  /// something to infer: the CLI renamed that tool `Task` → `Agent` once.
  final bool subagent;

  /// When the agent issued it, on the **host's** clock and UTC — paired with
  /// [RemoteSessionActivity.observedAt] so elapsed is one clock's arithmetic.
  final DateTime startedAt;

  Map<String, Object?> toJson() => {
    'summary': summary,
    'tool': toolName,
    if (subagent) 'subagent': true,
    'startedAt': startedAt.toUtc().toIso8601String(),
  };

  static RemoteActivityCall fromJson(Map<String, Object?> json) {
    final summary = json['summary'];
    final tool = json['tool'];
    final startedAt = json['startedAt'];
    if (summary is! String || tool is! String || startedAt is! String) {
      throw const ProtocolException('bad activity call');
    }
    final at = DateTime.tryParse(startedAt);
    if (at == null) throw const ProtocolException('bad activity timestamp');
    return RemoteActivityCall(
      summary: summary,
      toolName: tool,
      subagent: json['subagent'] == true,
      startedAt: at.toUtc(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteActivityCall &&
      other.summary == summary &&
      other.toolName == toolName &&
      other.subagent == subagent &&
      other.startedAt == startedAt;

  @override
  int get hashCode => Object.hash(summary, toolName, subagent, startedAt);

  @override
  String toString() => 'RemoteActivityCall($summary, $startedAt)';
}

/// **What one session is doing right now**, as `session.activity` carries it.
/// The phone counts elapsed from `observedAt - startedAt`, a duration both ends
/// agree on, because its clock is not the desktop's.
class RemoteSessionActivity {
  const RemoteSessionActivity({
    required this.sessionId,
    required this.observedAt,
    this.calls = const [],
    this.absence,
  });

  final String sessionId;

  /// When the host took this reading, on its own clock and in UTC.
  final DateTime observedAt;

  /// Oldest first, as the transcript issued them.
  final List<RemoteActivityCall> calls;

  /// Why [calls] is empty, when the host knows. Null means it could see, and
  /// there was nothing — which is a different sentence.
  final RemoteActivityAbsence? absence;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'observedAt': observedAt.toUtc().toIso8601String(),
    'calls': [for (final call in calls) call.toJson()],
    if (absence != null) 'absence': absence!.wire,
  };

  static RemoteSessionActivity fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final observedAt = json['observedAt'];
    final calls = json['calls'];
    if (sessionId is! String || observedAt is! String) {
      throw const ProtocolException('bad session activity');
    }
    final at = DateTime.tryParse(observedAt);
    if (at == null) throw const ProtocolException('bad activity timestamp');
    return RemoteSessionActivity(
      sessionId: sessionId,
      observedAt: at.toUtc(),
      calls: [
        for (final call in calls is List ? calls : const [])
          if (call is Map<String, Object?>) RemoteActivityCall.fromJson(call),
      ],
      absence: RemoteActivityAbsence.parse(json['absence']),
    );
  }
}

/// What a stopped session is waiting on — the wire's copy of `AgentWaitKind`.
/// Only [approval] may be answered with a keystroke: Claude Code fires the same
/// notification for an open prompt and for a merely finished turn.
enum RemoteWaitKind {
  /// A prompt with options is open. Only here may a key be pressed for the
  /// user, and only here does the host name answers.
  approval('approval'),

  /// The agent is at its own input with nothing to confirm — reply to it, do
  /// not answer it.
  input('input'),

  /// No source could tell, or the host is older than this field. Treated like
  /// [input] wherever a key would be pressed.
  unrecorded('unrecorded');

  const RemoteWaitKind(this.wire);

  final String wire;

  /// An absent or unknown word reads as [unrecorded]: the fail-safe direction
  /// is always "we cannot tell whether a prompt is open".
  static RemoteWaitKind parse(Object? wire) =>
      _byWire[wire] ?? RemoteWaitKind.unrecorded;

  static final Map<Object?, RemoteWaitKind> _byWire = {
    for (final k in RemoteWaitKind.values) k.wire: k,
  };
}

/// What `approval.requested` carries: the agent's own words, verbatim, or
/// nothing — never a summary this code wrote.
class RemoteApprovalRequest {
  const RemoteApprovalRequest({
    required this.sessionId,
    this.evidence = const [],
    this.waiting = RemoteWaitKind.unrecorded,
    this.approveLabel,
    this.denyLabel,
  });

  final String sessionId;
  final List<String> evidence;

  /// What the host can tell the session is waiting on. Sent for every request
  /// so the phone can word the card without guessing.
  final RemoteWaitKind waiting;

  /// The answers the agent itself names, and **only** for a prompt the host can
  /// see. A missing label means that answer does not exist here.
  final String? approveLabel;
  final String? denyLabel;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'evidence': evidence,
    'waiting': waiting.wire,
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
      waiting: RemoteWaitKind.parse(json['waiting']),
      approveLabel: json['approve'] is String
          ? json['approve']! as String
          : null,
      denyLabel: json['deny'] is String ? json['deny']! as String : null,
    );
  }
}

/// How an approval stopped waiting, as far as the host can honestly say.
/// [approved] and [denied] only when this host pressed the key itself; every
/// other route is [elsewhere], because the decision is not observable.
enum RemoteApprovalOutcome {
  approved('approved'),
  denied('denied'),
  elsewhere('elsewhere');

  const RemoteApprovalOutcome(this.wire);

  final String wire;

  /// Unknown wording from a newer host reads as [elsewhere]: something
  /// happened and the card must go, which is the part that matters.
  static RemoteApprovalOutcome parse(Object? wire) =>
      _byWire[wire] ?? RemoteApprovalOutcome.elsewhere;

  static final Map<Object?, RemoteApprovalOutcome> _byWire = {
    for (final o in RemoteApprovalOutcome.values) o.wire: o,
  };
}

/// What `approval.resolved` carries.
/// Correlated by session: `approval.requested` carries no id of its own, and a
/// session has at most one prompt waiting at a time.
class RemoteApprovalResolved {
  const RemoteApprovalResolved({
    required this.sessionId,
    this.outcome = RemoteApprovalOutcome.elsewhere,
  });

  final String sessionId;
  final RemoteApprovalOutcome outcome;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'outcome': outcome.wire,
  };

  static RemoteApprovalResolved fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String) {
      throw const ProtocolException('bad approval resolution');
    }
    return RemoteApprovalResolved(
      sessionId: sessionId,
      outcome: RemoteApprovalOutcome.parse(json['outcome']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteApprovalResolved &&
      other.sessionId == sessionId &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(sessionId, outcome);
}

/// What `host.status` carries on connect, and again whenever the host's relays
/// change under a live link.
class RemoteHostStatus {
  const RemoteHostStatus({
    required this.versions,
    required this.hostName,
    this.relays = const [],
    this.lanHint,
  });

  final VersionRange versions;
  final String hostName;

  /// Every relay this host is serving right now; the phone replaces its saved
  /// candidate set with this. Additive — an older host sends none and the phone
  /// keeps what it has.
  final List<Uri> relays;

  /// `host:port` of the host's direct LAN listener. A **discovery hint** — the
  /// sealed hello remains the only proof of who answered.
  final String? lanHint;

  Map<String, Object?> toJson() => {
    'versions': versions.toJson(),
    'host': hostName,
    if (relays.isNotEmpty)
      'relays': [for (final url in relays) url.toString()],
    if (lanHint != null) 'lan': lanHint,
  };

  static RemoteHostStatus fromJson(Map<String, Object?> json) {
    final versions = json['versions'];
    if (versions is! Map<String, Object?>) {
      throw const ProtocolException('bad host status');
    }
    final lan = json['lan'];
    return RemoteHostStatus(
      versions: VersionRange.fromJson(versions),
      hostName: json['host'] is String ? json['host']! as String : '',
      relays: relayUrisFrom(json['relays']),
      lanHint: lan is String && lan.isNotEmpty ? lan : null,
    );
  }
}

/// One permission mode an agent can be put into, worded by the host — so a
/// phone one release behind can offer a mode it has never heard of and still
/// say truthfully what it does to that agent.
class RemotePermissionOption {
  const RemotePermissionOption({
    required this.mode,
    required this.label,
    required this.summary,
    required this.selectable,
    this.dangerous = false,
  });

  /// `PermissionMode.name` on the desktop; opaque here.
  final String mode;

  /// The desktop's own name for it ("Ask every time").
  final String label;

  /// What picking it actually does to this agent, in the agent's own terms —
  /// `AgentPermissionOption.summary`, never re-worded on the phone.
  final String summary;

  /// Whether the agent can be put into it at all. A mode it cannot express is
  /// **sent and not selectable** rather than hidden.
  final bool selectable;

  /// True for the mode the desktop marks dangerous, so the phone can make the
  /// deliberate choice look deliberate.
  final bool dangerous;

  Map<String, Object?> toJson() => {
    'mode': mode,
    'label': label,
    'summary': summary,
    'selectable': selectable,
    if (dangerous) 'dangerous': dangerous,
  };

  static RemotePermissionOption fromJson(Map<String, Object?> json) {
    final mode = json['mode'];
    if (mode is! String) throw const ProtocolException('bad permission option');
    return RemotePermissionOption(
      mode: mode,
      label: json['label'] is String ? json['label']! as String : mode,
      summary: json['summary'] is String ? json['summary']! as String : '',
      selectable: json['selectable'] == true,
      dangerous: json['dangerous'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemotePermissionOption &&
      other.mode == mode &&
      other.label == label &&
      other.summary == summary &&
      other.selectable == selectable &&
      other.dangerous == dangerous;

  @override
  int get hashCode => Object.hash(mode, label, summary, selectable, dangerous);
}

/// One agent installed where a checkout lives — an installation the phone may
/// name in `session.start`, never an agent that merely exists in the registry.
class RemoteAgentOption {
  const RemoteAgentOption({
    required this.installationId,
    required this.agentId,
    required this.name,
    required this.defaultMode,
    this.version,
    this.acceptsOpeningMessage = false,
    this.permissionModes = const [],
  });

  /// `AgentInstallation.id` — what `session.start` names.
  final String installationId;

  /// `AgentDescriptor.id`; opaque here, useful for an icon.
  final String agentId;

  /// The desktop's display name for the agent ("Claude Code").
  final String name;

  /// The mode the desktop's own settings would start this agent under. The
  /// phone preselects it and never invents one.
  final String defaultMode;

  final String? version;

  /// Whether this agent's command line takes an opening message. False means a
  /// start carrying one is refused (`SessionLaunchRefused`).
  final bool acceptsOpeningMessage;

  final List<RemotePermissionOption> permissionModes;

  Map<String, Object?> toJson() => {
    'installationId': installationId,
    'agentId': agentId,
    'name': name,
    'defaultMode': defaultMode,
    if (version != null) 'version': version,
    if (acceptsOpeningMessage) 'acceptsOpeningMessage': acceptsOpeningMessage,
    'permissionModes': [for (final m in permissionModes) m.toJson()],
  };

  static RemoteAgentOption fromJson(Map<String, Object?> json) {
    final installationId = json['installationId'];
    final agentId = json['agentId'];
    if (installationId is! String || agentId is! String) {
      throw const ProtocolException('bad agent option');
    }
    final modes = json['permissionModes'];
    return RemoteAgentOption(
      installationId: installationId,
      agentId: agentId,
      name: json['name'] is String ? json['name']! as String : agentId,
      defaultMode: json['defaultMode'] is String
          ? json['defaultMode']! as String
          : '',
      version: json['version'] is String ? json['version']! as String : null,
      acceptsOpeningMessage: json['acceptsOpeningMessage'] == true,
      permissionModes: [
        if (modes is List)
          for (final entry in modes)
            if (entry is Map<String, Object?>)
              RemotePermissionOption.fromJson(entry),
      ],
    );
  }
}

/// One checkout of a project, and what can be started in it.
class RemoteCheckoutOption {
  const RemoteCheckoutOption({
    required this.repositoryId,
    required this.name,
    this.path,
    this.subPath,
    this.branch,
    this.environmentName,
    this.folderMissing = false,
    this.agents = const [],
  });

  /// `Repository.id` — what `session.start` names.
  final String repositoryId;
  final String name;

  /// The checkout as the desktop spells it. A subtitle, never a path to act
  /// on: the phone cannot reach this filesystem.
  final String? path;

  /// Written relative to the project root, when it says anything the name
  /// does not.
  final String? subPath;

  /// The branch checked out here, when already measured. Null means "not
  /// measured", never "no branch": this starts no git.
  final String? branch;

  /// The execution environment this checkout lives in, as the desktop names it.
  /// One repository checked out natively and inside WSL gives a project two
  /// checkouts of one name; null when there is nothing worth saying.
  final String? environmentName;

  /// The desktop cannot see this folder on disk. False also means "could not
  /// tell" — the same fail-safe direction the session rows take.
  final bool folderMissing;

  /// Every agent installed in the environment this checkout lives in. Empty
  /// is a real answer: nothing can be started here.
  final List<RemoteAgentOption> agents;

  Map<String, Object?> toJson() => {
    'repositoryId': repositoryId,
    'name': name,
    if (path != null) 'path': path,
    if (subPath != null) 'subPath': subPath,
    if (branch != null) 'branch': branch,
    if (environmentName != null) 'environmentName': environmentName,
    if (folderMissing) 'folderMissing': folderMissing,
    'agents': [for (final agent in agents) agent.toJson()],
  };

  static RemoteCheckoutOption fromJson(Map<String, Object?> json) {
    final repositoryId = json['repositoryId'];
    if (repositoryId is! String) {
      throw const ProtocolException('bad checkout option');
    }
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    final agents = json['agents'];
    return RemoteCheckoutOption(
      repositoryId: repositoryId,
      name: str(json['name']) ?? repositoryId,
      path: str(json['path']),
      subPath: str(json['subPath']),
      branch: str(json['branch']),
      environmentName: str(json['environmentName']),
      folderMissing: json['folderMissing'] == true,
      agents: [
        if (agents is List)
          for (final entry in agents)
            if (entry is Map<String, Object?>) RemoteAgentOption.fromJson(entry),
      ],
    );
  }
}

/// One project of the desktop's workspace. Reported, never guessed — a checkout
/// the desktop holds no row for is absent rather than inferred from a session.
class RemoteWorkspaceProject {
  const RemoteWorkspaceProject({
    required this.projectId,
    required this.name,
    this.path,
    this.environmentName,
    this.environmentBadge,
    this.environmentId,
    this.environmentKind,
    this.checkouts = const [],
  });

  final String projectId;
  final String name;
  final String? path;

  /// The environment the project's root lives in. Two projects of one name, one
  /// per environment, are otherwise told apart only by their paths.
  final String? environmentName;

  /// The badge on a non-local project card ("WSL · Ubuntu"); null for local.
  final String? environmentBadge;

  /// The desktop's own id for the machine, and what kind it is. Both null from
  /// a desktop older than this field; the phone groups by name then.
  final String? environmentId;
  final String? environmentKind;

  final List<RemoteCheckoutOption> checkouts;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'name': name,
    if (path != null) 'path': path,
    if (environmentName != null) 'environmentName': environmentName,
    if (environmentBadge != null) 'environmentBadge': environmentBadge,
    if (environmentId != null) 'environmentId': environmentId,
    if (environmentKind != null) 'environmentKind': environmentKind,
    'checkouts': [for (final checkout in checkouts) checkout.toJson()],
  };

  static RemoteWorkspaceProject fromJson(Map<String, Object?> json) {
    final projectId = json['projectId'];
    if (projectId is! String) {
      throw const ProtocolException('bad workspace project');
    }
    final checkouts = json['checkouts'];
    return RemoteWorkspaceProject(
      projectId: projectId,
      name: json['name'] is String ? json['name']! as String : projectId,
      path: json['path'] is String ? json['path']! as String : null,
      environmentName: json['environmentName'] is String
          ? json['environmentName']! as String
          : null,
      environmentBadge: json['environmentBadge'] is String
          ? json['environmentBadge']! as String
          : null,
      environmentId: json['environmentId'] is String
          ? json['environmentId']! as String
          : null,
      environmentKind: json['environmentKind'] is String
          ? json['environmentKind']! as String
          : null,
      checkouts: [
        if (checkouts is List)
          for (final entry in checkouts)
            if (entry is Map<String, Object?>)
              RemoteCheckoutOption.fromJson(entry),
      ],
    );
  }
}

/// A `session.start` request, after the host api has checked its shape.
class RemoteSessionStartRequest {
  const RemoteSessionStartRequest({
    required this.repositoryId,
    required this.installationId,
    required this.permissionMode,
    this.title,
    this.message,
  });

  final String repositoryId;
  final String installationId;

  /// The mode the **user** picked. Not optional: starting an agent in bypass is
  /// not a choice anything but a person may make.
  final String permissionMode;

  final String? title;

  /// The opening message, when there is one. Refused for an agent whose
  /// command line cannot carry it — by the launcher, not by anything here.
  final String? message;
}

/// What `session.start` answers with.
class RemoteSessionStarted {
  const RemoteSessionStarted({
    required this.sessionId,
    required this.title,
    this.permissionMode,
    this.replayed = false,
  });

  final String sessionId;
  final String title;

  /// The mode the session was actually stamped with, or null when the row
  /// records none.
  final String? permissionMode;

  /// True when this answer was remembered rather than acted on: the same
  /// idempotency key arrived twice.
  final bool replayed;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'title': title,
    if (permissionMode != null) 'permissionMode': permissionMode,
    if (replayed) 'replayed': replayed,
  };

  static RemoteSessionStarted fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String) {
      throw const ProtocolException('bad session start result');
    }
    return RemoteSessionStarted(
      sessionId: sessionId,
      title: json['title'] is String ? json['title']! as String : '',
      permissionMode: json['permissionMode'] is String
          ? json['permissionMode']! as String
          : null,
      replayed: json['replayed'] == true,
    );
  }
}
