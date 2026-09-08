/// The payload shapes both ends of the session API agree on.
///
/// The host builds these; the companion parses them. Pure Dart, no imports
/// from the sessions feature — status, stage and attention travel as strings
/// so the phone can render values this build has never heard of.
library;

import '../client/relay_candidates.dart';
import '../protocol.dart';

/// The one attention word that means "a prompt is waiting on a person".
///
/// Named because three places now turn on it — the snapshot the host serves,
/// the arbiter that refuses a second answer, and the phone's own retiring of
/// a stale approval card — and a typo in any of them would leave an approval
/// that cannot be answered or one that cannot be dismissed.
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

  /// What a file sent to **this** session would be allowed to be — carried on
  /// the row so the phone knows before the user picks anything.
  ///
  /// Here rather than on `host.status` because the answer is per session, not
  /// per desktop: it turns on the agent behind the row, on whether that agent
  /// runs somewhere this desktop can write a file it will see, and on whether
  /// the row is live at all. Null means an older host that was never asked —
  /// the phone offers nothing, which is the honest reading of silence.
  final RemoteAttachmentSupport? attachments;

  /// The badge shown on non-local project/session cards (e.g. "WSL · Ubuntu", "SSH · build-box").
  /// Null for local-host sessions.
  final String? environmentBadge;

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
      other.environmentBadge == environmentBadge;

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
    Object.hash(subPath, worktree, branch, attachments),
  );
}

/// What a file sent to one session may be, or the host's sentence for why none
/// may be.
///
/// **A fact and a sentence, and they are not the same fact.** [mediaTypes] is
/// what the phone filters its picker by; [refusal] is what it shows in place of
/// the button when there is nothing to filter for. The host words the refusal
/// because only the host knows which of the several reasons it is — an agent
/// that cannot be handed a picture, a session running on a machine whose disk
/// this one cannot write to, imported history that is read-only here — and a
/// phone inventing that sentence would be inventing a claim about a CLI it has
/// never seen. The same rule [RemotePermissionOption] follows.
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

  /// The exact media types the agent behind this session will look at when a
  /// prompt names a file's path. Never a wildcard: the phone hands one of
  /// these back on `attachment.begin` and the host matches it literally, so a
  /// pattern here would be a pattern two builds could disagree about.
  final List<String> mediaTypes;

  /// The largest file this session will take, in bytes. Never above
  /// [kMaxAttachmentBytes]; may be below it.
  final int maxBytes;

  /// Why [mediaTypes] is empty, when the host can say. Null with an empty list
  /// means the host had no words for it, which the phone shows as nothing
  /// rather than as a guess.
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
/// message box for the person sitting at it.
///
/// Told to the phone rather than left to be inferred, because the two are
/// genuinely different outcomes and "sent" would be a false one. See
/// `RemoteHostBindings.sendPrompt`.
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
  /// keeps only its basename, strips it to a safe set of characters and puts
  /// its own extension on, so nothing the phone says can decide where a byte
  /// lands.
  final String name;

  /// One of the session's [RemoteAttachmentSupport.mediaTypes], exactly.
  final String mediaType;

  /// The whole file's length. Declared up front so the host can refuse an
  /// oversized one before a byte crosses, and so a short delivery is a fact
  /// rather than something nobody notices.
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
  /// phone and a newer host cannot disagree about it — and so this can be
  /// lowered later without stranding a build.
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

/// Why a transcript page carries nothing, when the host can actually say.
///
/// An empty list has always meant two different things — *this agent keeps no
/// record we can read* and *this session has not spoken yet* — and the host
/// knew which while the phone could only hedge across both. That is how a
/// running Antigravity session came to show a welcome screen with starter
/// prompts on it: the desktop refuses that agent's store (protobuf in an
/// unpublished schema, see `agentSupportsChatView`) and sent `[]`, which is
/// also what a brand-new session sends.
///
/// **A fact, never a sentence.** The wire carries which nothing it is and the
/// phone words it, so the wording stays a client decision and an older phone
/// that has never heard of a value falls back to the hedge rather than
/// rendering a word it cannot place.
enum RemoteTranscriptAbsence {
  /// The agent keeps no record this app can read, so there is no chat view for
  /// this session at all — not now, and not after it answers.
  noChatView('no_chat_view');

  const RemoteTranscriptAbsence(this.wire);

  final String wire;

  /// An absent or unrecognised word reads as null — *we were not told why* —
  /// which is exactly the hedge that existed before this field.
  static RemoteTranscriptAbsence? parse(Object? wire) => _byWire[wire];

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
    this.absence,
  });

  final String sessionId;
  final List<RemoteTranscriptMessage> messages;

  /// Position after the last message here — pass as `after` to resume.
  final int cursor;

  /// How many messages before [messages] the host did not send.
  ///
  /// A conversation is opened at its end, and a long one cannot be carried in
  /// a single frame: this session's own transcript is 53 MB of JSONL, and
  /// sending every message of it produced a frame the phone never finished
  /// receiving. So the host sends the tail and says how much it kept back,
  /// rather than silently showing a conversation that appears to begin in the
  /// middle. Defaults to zero, so a page from an older host reads as complete
  /// — which is what it was.
  final int omitted;

  /// Why [messages] is empty, when the host knows. Null means it did not say —
  /// an older host, or a nothing it cannot account for either.
  final RemoteTranscriptAbsence? absence;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'messages': [for (final m in messages) m.toJson()],
    'cursor': cursor,
    if (omitted > 0) 'omitted': omitted,
    if (absence != null) 'absence': absence!.wire,
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
      absence: RemoteTranscriptAbsence.parse(json['absence']),
      sessionId: sessionId,
      messages: [
        for (final m in messages)
          if (m is Map<String, Object?>) RemoteTranscriptMessage.fromJson(m),
      ],
      cursor: cursor,
    );
  }
}

/// Why an activity answer carries no calls, when the host can actually say.
///
/// The same split [RemoteTranscriptAbsence] is built to, for the same reason:
/// an empty list has two meanings — *this session is working and nothing is
/// outstanding* and *this session is working and we cannot see what on* — and
/// only the host knows which. **A fact, never a sentence.** The wire carries
/// which nothing it is and the phone words it, so an older phone that has never
/// heard of a value falls back to the hedge rather than rendering a word it
/// cannot place.
enum RemoteActivityAbsence {
  /// The session is working and nothing the host can read records what on:
  /// no CLI session id yet, an agent whose store the desktop cannot open, or a
  /// session whose only record is the engine's event log — which has no result
  /// event, and so cannot tell a finished call from a running one.
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

  /// The line the desktop transcript already prints — `Bash(git status)`,
  /// `Agent(review the diff)`. For a shell call that line **is** the command,
  /// so nothing extra is carried to name what is running.
  final String summary;

  /// The tool's own name, so the phone can ask what kind of call this is
  /// without parsing [summary] back apart.
  final String toolName;

  /// Whether this is another agent rather than a tool. Sent as a fact rather
  /// than left to the phone to work out from [toolName]: the CLI renamed that
  /// tool from `Task` to `Agent` once already, and a phone updates on its own
  /// schedule.
  final bool subagent;

  /// When the agent issued it, on the **host's** clock and in UTC. Paired with
  /// [RemoteSessionActivity.observedAt] so the phone measures elapsed against
  /// one clock rather than against its own.
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
///
/// [observedAt] is not decoration. The phone shows an elapsed time that keeps
/// counting between frames, and its clock is not the desktop's — so it counts
/// from `observedAt - startedAt`, which is a duration both ends agree on, plus
/// whatever has passed locally since the frame landed. Without it the phone
/// would be subtracting one machine's instant from another's.
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

/// What a session that has stopped for the user is actually waiting on — the
/// wire's copy of the desktop's `AgentWaitKind`.
///
/// "This session is holding you up" and "a prompt is open" are different
/// facts, and only the second one may be answered with a keystroke: Claude
/// Code fires the same notification when it wants permission and when it has
/// merely finished a turn, and the approve key types Enter, which at an idle
/// prompt submits whatever is in the composer. The host names [approval] only
/// for a wait a status source could identify as one.
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

  /// The answers the agent itself names, and **only** for a prompt the host
  /// can see ([RemoteWaitKind.approval]). A missing label means that answer
  /// does not exist here, not that the phone should invent one.
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
///
/// [approved] and [denied] are stated only for an answer this host applied on
/// the asking device's behalf — it pressed the key, so it knows which. Every
/// other route (the desktop's own card, a second paired phone, the agent
/// giving up) is [elsewhere]: the host observes that the request is gone, not
/// what was chosen, and inventing the decision would be a claim it cannot
/// back.
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
///
/// Correlated by session, because that is how the protocol correlates an
/// approval: `approval.requested` carries no id of its own, and a session has
/// at most one prompt waiting at a time — the phone's `approvalId` is a local
/// label it mints for its own card, and has never been on the wire.
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

/// What `host.status` carries on connect — and, since Loop 83, again whenever
/// the host's relays change under a live link.
class RemoteHostStatus {
  const RemoteHostStatus({
    required this.versions,
    required this.hostName,
    this.relays = const [],
    this.lanHint,
  });

  final VersionRange versions;
  final String hostName;

  /// Every relay this host is serving right now. The phone replaces its saved
  /// candidate set with this, which is how a hosted relay switched on months
  /// later — or a desktop whose LAN address moved — heals with no re-pairing.
  /// Additive: an older host sends none, and the phone keeps what it has.
  final List<Uri> relays;

  /// `host:port` of the host's direct LAN listener, when it has a LAN address
  /// to name. A **discovery hint** — it goes stale the moment DHCP moves, and
  /// the sealed hello remains the only proof of who answered.
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

/// One permission mode an agent can be put into, worded by the host.
///
/// The mode travels as `PermissionMode.name` and everything the phone shows
/// about it travels as the host's own sentences — the same rule the session
/// snapshot follows for status and stage. A phone one release behind can
/// therefore offer a mode this build of the companion has never heard of, and
/// still say truthfully what it does to that agent.
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
  /// **sent and not selectable** rather than hidden: Loop 31 §4 option C, so
  /// nobody wonders where the safe option went.
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
  /// phone preselects it and the user may change it; the phone never invents
  /// one of its own.
  final String defaultMode;

  final String? version;

  /// Whether this agent's command line takes an opening message. False means
  /// a start carrying one is refused (`SessionLaunchRefused`), so the phone
  /// says so before the user types rather than after.
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

  /// The branch checked out here, when the desktop has **already** measured
  /// it. Null means "not measured", never "no branch": this reads the cached
  /// checkout stat and starts no git.
  final String? branch;

  /// The execution environment this checkout lives in, as the desktop names
  /// it — `Windows`, `WSL · Ubuntu`, `SSH · build-box`.
  ///
  /// The same repository checked out twice — natively and inside a WSL
  /// distribution — gives a project two checkouts of the same name, and the
  /// path is the only other thing that differs. Naming the environment is
  /// what makes that choice readable on a phone.
  ///
  /// Null when the desktop has nothing worth saying: an environment row it no
  /// longer holds, or one saved with a blank name. The phone falls back to the
  /// path rather than showing an empty line.
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

/// One project of the desktop's workspace: what `workspace.list` answers with.
///
/// Reported, never guessed — a checkout the desktop does not hold a row for is
/// absent from this list rather than inferred from a session that mentions it.
class RemoteWorkspaceProject {
  const RemoteWorkspaceProject({
    required this.projectId,
    required this.name,
    this.path,
    this.environmentName,
    this.environmentBadge,
    this.checkouts = const [],
  });

  final String projectId;
  final String name;
  final String? path;

  /// The environment the project's root folder lives in, named the way
  /// [RemoteCheckoutOption.environmentName] is. Two projects of the same name
  /// — one per environment — are otherwise told apart only by their paths.
  final String? environmentName;

  /// The badge shown on non-local project cards (e.g. "WSL · Ubuntu", "SSH · build-box").
  /// Null for local-host projects.
  final String? environmentBadge;

  final List<RemoteCheckoutOption> checkouts;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'name': name,
    if (path != null) 'path': path,
    if (environmentName != null) 'environmentName': environmentName,
    if (environmentBadge != null) 'environmentBadge': environmentBadge,
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

  /// The mode the **user** picked, from the options `workspace.list` sent. Not
  /// optional: a phone that named no mode would be asking the desktop to
  /// choose one for it, and starting an agent in bypass is not a choice
  /// anything but a person may make.
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

  /// True when this answer was remembered rather than acted on: the phone
  /// sent the same idempotency key twice and the desktop started nothing the
  /// second time.
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
