/// The companion app's one seam onto a paired desktop host.
///
/// Loop 70 builds the real protocol client (`features/remote/client/`) in
/// parallel with this UI; the two must not collide, so the companion talks to
/// this interface and the orchestrator wires the real client behind it at
/// integration. The shape deliberately mirrors what `remote/protocol.dart`
/// offers — one method or stream per frame type, nothing the protocol cannot
/// carry — and reuses its types (`CapabilitySet`, `DeviceId`) where they fit.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../remote/domain/companion_presence.dart';
import '../../remote/domain/remote_payloads.dart';
import '../../remote/protocol.dart';
import 'fake_companion_gateway.dart';

/// A refused or failed gateway call. Carries a sentence fit to show the user.
class GatewayException implements Exception {
  const GatewayException(this.message);

  final String message;

  @override
  String toString() => 'GatewayException: $message';
}

/// Pairing failed: a bad or expired QR payload, a short code the host did not
/// recognise, or a host that could not be reached to complete the handshake.
class PairingException extends GatewayException {
  const PairingException(super.message);

  @override
  String toString() => 'PairingException: $message';
}

/// The relay a typed pairing code falls back to when the phone has not
/// configured one. Mirrors the desktop's `kDefaultRelayUrl` (pinned equal by
/// test) without dragging the desktop controller into the companion client.
const String kDefaultCompanionRelayUrl = 'wss://relay.popupbits.com';

/// Whether the phone can currently talk to the host it is paired with.
enum CompanionLinkState { disconnected, connecting, connected }

/// Where one pairing attempt currently stands — what the progress screen
/// narrates. [failed] is terminal for the attempt; everything before walks
/// forward in declaration order.
enum CompanionPairingStage {
  /// The scanned or typed input parsed as a Karmashala code.
  codeAccepted,

  /// Dialling — the LAN and the relay race; first sealed answer wins.
  searching,

  /// The desktop was found and proved it holds the secret; keys are being
  /// proven both ways before anything is persisted.
  proving,

  /// Done: the pairing is stored and the link is coming up.
  paired,

  /// The attempt is over and [CompanionPairingProgress.message] says why.
  failed,
}

/// One step of one pairing attempt, as [CompanionGateway.pairingProgress]
/// reports it. Events-only: subscribe before calling a pairing verb.
class CompanionPairingProgress {
  const CompanionPairingProgress({
    required this.stage,
    this.detail,
    this.hostName,
    this.capabilities,
    this.message,
  });

  final CompanionPairingStage stage;

  /// A short clause for the searching stage ("on this network and over the
  /// relay"), when there is one.
  final String? detail;

  /// Known from the proving stage on — the host's self-reported name.
  final String? hostName;

  /// Known from the proving stage on — what the desktop granted.
  final CapabilitySet? capabilities;

  /// The user-fit failure sentence; only on [CompanionPairingStage.failed].
  final String? message;
}

/// Which transport carries the link while it is connected: the direct LAN
/// socket at home, or the relay from anywhere (design §3's priority order).
enum CompanionLinkPath {
  lan('Direct (LAN)'),
  relay('Relay');

  const CompanionLinkPath(this.label);

  /// What the settings screen calls this path.
  final String label;
}

/// What pairing established, kept for the settings screen.
class CompanionPairing {
  const CompanionPairing({
    required this.capabilities,
    this.hostName,
    this.hostId,
  });

  /// What the desktop granted this phone; every action the UI offers must be
  /// backed by a bit here.
  final CapabilitySet capabilities;

  /// The host machine's self-reported name, when it sent one.
  final String? hostName;

  final DeviceId? hostId;
}

/// One saved desktop pairing, as the Connections UI lists it. The phone can
/// hold several; exactly one — the active one — carries the live link.
class CompanionConnection {
  const CompanionConnection({
    required this.hostId,
    required this.name,
    required this.active,
    this.lastConnectedAt,
  });

  /// The host's id in its wire (hex) form — the key [CompanionGateway.switchTo]
  /// and [CompanionGateway.removeConnection] take.
  final String hostId;

  /// The desktop's self-reported name, or "Desktop" when it never sent one.
  final String name;

  /// Whether this is the desktop the link (and every session stream) is for.
  final bool active;

  /// When this phone last held a link to this desktop, UTC. Null for a
  /// pairing that never connected.
  final DateTime? lastConnectedAt;

  @override
  bool operator ==(Object other) =>
      other is CompanionConnection &&
      other.hostId == hostId &&
      other.name == name &&
      other.active == active &&
      other.lastConnectedAt == lastConnectedAt;

  @override
  int get hashCode => Object.hash(hostId, name, active, lastConnectedAt);

  @override
  String toString() =>
      'CompanionConnection($name, $hostId${active ? ', active' : ''})';
}

/// One session's live status, in the terms the phone shows.
enum CompanionSessionStatus { working, idle, needsYou, failed, unknown }

/// Why a session is (or was) asking for the user — the attention-inbox kinds
/// the host forwards (design §5: finished / needs you / failed).
enum CompanionAttentionKind {
  finished,
  needsYou,
  failed;

  String get label => switch (this) {
    CompanionAttentionKind.finished => 'Finished',
    CompanionAttentionKind.needsYou => 'Needs you',
    CompanionAttentionKind.failed => 'Failed',
  };
}

/// A session's standing claim on the user, shown in the inbox and as a badge.
class CompanionAttention {
  const CompanionAttention({required this.kind, required this.at});

  final CompanionAttentionKind kind;

  /// When the host reported it. Orders the inbox; never shown as a claim about
  /// when it happened at the agent.
  final DateTime at;
}

/// One session as `sessions.list` / `session.changed` describe it.
class CompanionSessionSummary {
  const CompanionSessionSummary({
    required this.id,
    required this.title,
    required this.agentLabel,
    required this.projectName,
    this.projectId,
    this.projectPath,
    this.status = CompanionSessionStatus.unknown,
    this.whereabouts,
    this.branch,
    this.subPath,
    this.worktree = false,
    this.lastActivityAt,
    this.attention,
    this.deliveryStage,
    this.imported = false,
    this.archived = false,
    this.folderMissing = false,
    this.attachments,
    this.environmentBadge,
  });

  final String id;
  final String title;

  /// "Claude Code · running" — the card's first line, worded by the host so
  /// the phone never invents a claim about a process it cannot see.
  final String agentLabel;

  final String projectName;

  /// The repository's real identity on the host, so two checkouts that share a
  /// folder name stay two projects. Null from a host too old to send one — the
  /// list then falls back to grouping by [projectName].
  final String? projectId;

  final String? projectPath;
  final CompanionSessionStatus status;

  /// Loop 46's whereabouts clause, verbatim from the host.
  final String? whereabouts;

  final String? branch;
  final String? subPath;
  final bool worktree;

  /// When the host last heard anything from this session.
  final DateTime? lastActivityAt;

  /// Set while this session is in the host's attention inbox.
  final CompanionAttention? attention;

  /// How far the work has travelled (`DeliveryStage.name` on the desktop —
  /// `working`, `pushed`, `merged`…), or null for "could not tell", which is
  /// a first-class answer.
  final String? deliveryStage;

  /// True for CLI history the desktop imported: readable, never steerable.
  final bool imported;

  /// True once the desktop has archived this session. Listed, and said so —
  /// the phone shows what the host holds rather than quietly hiding rows.
  final bool archived;

  /// True when the host says this session's folder is no longer on disk.
  final bool folderMissing;

  /// What a file sent to this session may be, straight off the row.
  ///
  /// Here so the composer knows **before** the user opens a picker: a phone
  /// that asked afterwards would have already spent somebody's mobile data on
  /// a photo the desktop was never going to be able to use. Null from a host
  /// that was never asked, which offers nothing rather than a guess.
  final RemoteAttachmentSupport? attachments;

  /// The badge shown on non-local project/session cards (e.g. "WSL · Ubuntu", "SSH · build-box").
  /// Null for local-host sessions.
  final String? environmentBadge;

  /// A narrow copy: only the facts that change while a session is listed.
  CompanionSessionSummary copyWith({
    CompanionSessionStatus? status,
    CompanionAttention? attention,
    DateTime? lastActivityAt,
    bool? archived,
    String? environmentBadge,
  }) => CompanionSessionSummary(
    id: id,
    title: title,
    agentLabel: agentLabel,
    projectName: projectName,
    projectId: projectId,
    projectPath: projectPath,
    status: status ?? this.status,
    whereabouts: whereabouts,
    branch: branch,
    subPath: subPath,
    worktree: worktree,
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    attention: attention ?? this.attention,
    deliveryStage: deliveryStage,
    imported: imported,
    archived: archived ?? this.archived,
    folderMissing: folderMissing,
    attachments: attachments,
    environmentBadge: environmentBadge ?? this.environmentBadge,
  );

  /// What the list groups by: the repository's real identity when the host
  /// sent one, its display name otherwise.
  String get projectKey => projectId ?? 'name:$projectName';
}

/// The role on the gateway's own marker for history the host kept back — not a
/// turn anybody took, and drawn as the top edge of the loaded window rather
/// than as a message.
const String kCompanionNoticeRole = 'notice';

/// The role on the gateway's own account of **why** a transcript is empty,
/// when the host said so — `RemoteTranscriptAbsence` put into words here, on
/// the client, because the wire carries the fact and not the sentence.
///
/// Not a turn either, and not [kCompanionNoticeRole]: that one marks history
/// the host kept back, and is drawn as the top edge of a loaded window. This
/// one is the whole of what there is, and is drawn instead of the empty
/// state's welcome — a screen offering starter prompts for a session the user
/// can see running was the "it shows running but no transcript" report.
const String kCompanionAbsenceRole = 'absence';

/// One file on its way to a desktop: what the phone picked, in memory.
///
/// [bytes] rather than a path because the picker on Android hands back a
/// content URI whose file the host will never see — the bytes are the only
/// thing that can cross. Bounded by the host's own
/// [RemoteAttachmentSupport.maxBytes], checked before this is built.
class CompanionOutgoingAttachment {
  const CompanionOutgoingAttachment({
    required this.name,
    required this.mediaType,
    required this.bytes,
  });

  /// The file's name as the phone knows it — a **hint**. The host keeps only
  /// its basename, strips it, and puts its own extension on.
  final String name;

  /// One of the session's [RemoteAttachmentSupport.mediaTypes], exactly.
  final String mediaType;

  final Uint8List bytes;
}

/// One transcript turn. Role vocabulary matches the desktop chat view:
/// `user`, `agent`, `tool` or `error`, plus [kCompanionNoticeRole] and
/// [kCompanionAbsenceRole] for the gateway's own markers.
class CompanionChatMessage {
  const CompanionChatMessage({required this.role, required this.text});

  final String role;
  final String text;
}

/// One call a session has issued and not yet answered, as the phone shows it.
class CompanionActivityCall {
  const CompanionActivityCall({
    required this.summary,
    required this.elapsed,
    this.subagent = false,
  });

  /// The desktop's own line for the call — `Bash(flutter test)`,
  /// `Agent(review the diff)`. For a shell call that is the command itself.
  final String summary;

  /// Whether this is another agent rather than a tool. The host says so; the
  /// phone does not work it out from the name.
  final bool subagent;

  /// How long it had been running **when the host looked**.
  ///
  /// A duration rather than an instant, on purpose: it is `observedAt -
  /// startedAt`, both read off the desktop's clock, so nothing here subtracts
  /// one machine's time from another's. A screen that wants a live number adds
  /// its own elapsed since the frame landed — see [CompanionActivity.at].
  final Duration elapsed;

  @override
  bool operator ==(Object other) =>
      other is CompanionActivityCall &&
      other.summary == summary &&
      other.subagent == subagent &&
      other.elapsed == elapsed;

  @override
  int get hashCode => Object.hash(summary, subagent, elapsed);
}

/// **What one session is doing right now**, as the phone last heard it.
class CompanionActivity {
  const CompanionActivity({
    required this.at,
    this.calls = const [],
    this.absence,
    this.refused,
  });

  /// Nothing has been heard yet — not "nothing is running".
  static final unknown = CompanionActivity(at: DateTime.fromMillisecondsSinceEpoch(0));

  /// When this reading landed here, on the **phone's** clock. What a live
  /// elapsed time is counted from, added to each call's own [
  /// CompanionActivityCall.elapsed].
  final DateTime at;

  final List<CompanionActivityCall> calls;

  /// Why [calls] is empty, when the host said. Null means it could see and
  /// there was nothing — or that we were never told, which [refused] and a
  /// zero [at] tell apart.
  final RemoteActivityAbsence? absence;

  /// The host's sentence when it would not answer — an older pairing that was
  /// never granted `view_activity` is refused in words, and those words are
  /// shown rather than swallowed into an empty list.
  final String? refused;

  /// Whether this is a reading at all, as opposed to the seed before one.
  bool get known => at.millisecondsSinceEpoch != 0;

  @override
  bool operator ==(Object other) =>
      other is CompanionActivity &&
      other.at == at &&
      other.absence == absence &&
      other.refused == refused &&
      _sameCalls(other.calls, calls);

  @override
  int get hashCode => Object.hash(at, absence, refused, Object.hashAll(calls));

  static bool _sameCalls(
    List<CompanionActivityCall> a,
    List<CompanionActivityCall> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A pending approval, as `approval.requested` carries it.
///
/// [evidence] is the agent's own rows or hook message **verbatim** — the host
/// never summarises what is being approved, and neither may the phone. Button
/// labels exist only when the agent named the answer; a null [denyLabel] means
/// the agent's prompt names no way to decline.
class CompanionApproval {
  const CompanionApproval({
    required this.id,
    required this.sessionId,
    required this.agentName,
    this.evidence = const [],
    this.waiting = RemoteWaitKind.unrecorded,
    this.approveLabel,
    this.approveEffect,
    this.denyLabel,
    this.denyEffect,
  });

  final String id;
  final String sessionId;
  final String agentName;

  /// What the host says the session is waiting on. [RemoteWaitKind.input] is
  /// a notice, never an approval — the agent is at its own prompt and the
  /// answer is a message, not a key.
  final RemoteWaitKind waiting;

  /// Rendered terminal rows or the hook's message, exactly as received. Empty
  /// means "we can tell it is asking, but not what".
  final List<String> evidence;

  final String? approveLabel;

  /// What pressing approve actually does ("presses Enter"), shown under the
  /// button — the phone types into another program on the user's behalf and
  /// must say so.
  final String? approveEffect;

  final String? denyLabel;
  final String? denyEffect;
}

/// The two answers `approval.answer` can carry.
enum CompanionApprovalDecision { approve, deny }

/// Why a pending approval stopped being pending.
///
/// The host states [approved] and [denied] only for an answer it applied for
/// this phone; anything else — the desktop's own card, a second paired phone,
/// an agent that gave up — is [elsewhere], because the host observes that the
/// request is gone and not what was chosen.
enum CompanionApprovalOutcome {
  approved,
  denied,
  elsewhere;

  /// One line for the reader whose card just disappeared. A card that simply
  /// vanishes reads as a dropped request, which is the failure this whole
  /// event exists to prevent.
  String get sentence => switch (this) {
    CompanionApprovalOutcome.approved => 'Approved.',
    CompanionApprovalOutcome.denied => 'Declined.',
    CompanionApprovalOutcome.elsewhere =>
      'That request was already answered on the desktop.',
  };
}

/// One approval going away, as it happens — what the session screen says out
/// loud so the card does not simply vanish.
class CompanionApprovalResolution {
  const CompanionApprovalResolution({
    required this.sessionId,
    required this.outcome,
  });

  final String sessionId;
  final CompanionApprovalOutcome outcome;

  @override
  bool operator ==(Object other) =>
      other is CompanionApprovalResolution &&
      other.sessionId == sessionId &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(sessionId, outcome);

  @override
  String toString() => 'CompanionApprovalResolution($sessionId, $outcome)';
}

/// An attention event as it happens — what a local notification is made from.
class CompanionAttentionEvent {
  const CompanionAttentionEvent({
    required this.sessionId,
    required this.sessionTitle,
    required this.kind,
    required this.at,
    this.hostId,
  });

  final String sessionId;
  final String sessionTitle;
  final CompanionAttentionKind kind;
  final DateTime at;

  /// Which desktop this news came from, so a notification that arrives around
  /// a switch is never attributed to the wrong host. Only the ACTIVE host has
  /// a live link in v1, so in practice this is always the active host's id;
  /// it is carried anyway because the id is what makes that checkable.
  final String? hostId;
}

/// What the companion UI can ask of a paired host.
///
/// Stream contract: [pairingStates], [linkStates], [watchSessions],
/// [transcript] and [pendingApproval] each emit their **current** value
/// promptly on listen, then every change. [attentionEvents] is events-only.
/// Action futures complete when the host has answered, and throw
/// [GatewayException] (or [PairingException] for the pairing verbs) with a
/// user-fit sentence when it refused or could not be reached.
abstract interface class CompanionGateway {
  /// The pairing in effect, or null when this phone has never paired (or was
  /// revoked/unpaired).
  CompanionPairing? get pairing;
  Stream<CompanionPairing?> get pairingStates;

  CompanionLinkState get link;
  Stream<CompanionLinkState> get linkStates;

  /// One plain sentence about why the link is not up, when the gateway knows
  /// something the banner's own words do not say — "the relay hung up because
  /// nobody else was there" is a different fact from "the network failed".
  /// Null while connected, and whenever there is nothing to add.
  String? get linkTrouble;

  /// [linkTrouble] as it changes, seeded on listen like the rest.
  ///
  /// A surface that re-reads the getter only when the link STATE changes
  /// never shows the reason on the first pass: the reason is learned by a
  /// dial that failed while the phone was already `connecting`, so there is
  /// no state change behind it to rebuild on.
  Stream<String?> get linkTroubleStates;

  /// Which path carries the link — [CompanionLinkPath.lan] at home,
  /// [CompanionLinkPath.relay] elsewhere — or null while not connected.
  CompanionLinkPath? get linkPath;
  Stream<CompanionLinkPath?> get linkPathStates;

  /// When [link] last **changed** — not when it was last reported.
  ///
  /// Null until this phone has seen a change, so a surface admits it does not
  /// know rather than claiming "just now" (CLAUDE.md §19). The path is
  /// deliberately not part of it: a link that heals from the LAN onto the
  /// relay never went down, and how long it has been up is the reading.
  DateTime? get linkSince;
  Stream<DateTime?> get linkSinceStates;

  /// The relay the link is running through right now, or null on the LAN path
  /// and while nothing is connected. A phone may hold several saved relays, so
  /// "Relay" alone no longer says which one — this names it.
  Uri? get activeRelay;

  /// What the desktop granted at pairing; [CapabilitySet.none] when unpaired.
  CapabilitySet get capabilities;

  /// Pairs from a scanned QR payload (the JSON the desktop displays).
  ///
  /// A phone that is already paired ADDS the new desktop to its saved
  /// connections and switches to it; pairing the SAME host again replaces
  /// that one record and leaves the others alone.
  Future<CompanionPairing> pairWithQr(String qrPayload);

  /// Pairs from what the user typed or pasted: the grouped base32 code shown
  /// under the desktop's QR, or the full JSON payload — sniffed apart here.
  /// Adds a connection, the way [pairWithQr] does.
  Future<CompanionPairing> pairWithCode(String shortCode);

  /// Stage-by-stage news about the pairing attempt in flight. Events only —
  /// no current value is replayed; listen before calling a pairing verb.
  Stream<CompanionPairingProgress> get pairingProgress;

  /// The relay a typed code will dial (the code itself carries none):
  /// the configured one, or [kDefaultCompanionRelayUrl].
  Future<Uri> pairingRelay();

  /// Configures [pairingRelay]; null returns to the default.
  Future<void> setPairingRelay(Uri? url);

  /// Every desktop this phone has paired with, newest pairing last, with
  /// exactly one flagged active (none when unpaired).
  List<CompanionConnection> get connections;
  Stream<List<CompanionConnection>> get connectionsStates;

  /// Makes [hostId] the active desktop: the current link is dropped cleanly
  /// and the chosen host dialled, with every derived state — sessions,
  /// transcripts, subscriptions, pending approvals — rebuilt for it. Nothing
  /// from the old host survives the switch.
  ///
  /// Throws [GatewayException] with a user-fit sentence when [hostId] names no
  /// saved connection. A host that simply cannot be reached is not a failure
  /// of the switch: the phone lands on it disconnected, and the link banner
  /// says so, exactly as it would after a relaunch.
  Future<void> switchTo(String hostId);

  /// Forgets one saved desktop. Removing the active one falls back to the
  /// most recently connected of the rest, or to unpaired when none remain.
  Future<void> removeConnection(String hostId);

  /// Forgets the pairing on this phone. (Revoking the phone's key on the host
  /// is the desktop's verb, not this one.)
  ///
  /// Multi-host: this forgets the ACTIVE connection only — the same verb the
  /// settings screen has always offered, now scoped to the desktop in use.
  Future<void> unpair();

  /// Asks the transport to try connecting now instead of waiting for backoff.
  Future<void> reconnect();

  /// Says whether this companion is on screen.
  ///
  /// **For routing notifications, and nothing else.** The desktop spends it in
  /// `PushFanout` — a backgrounded phone hears a `session.changed` into a
  /// window nobody can see, and this is what lets a push be sent as well.
  /// Nothing on the delivery path may ever read it.
  ///
  /// Reporting the same answer twice sends nothing: one frame per change, and
  /// never a tick.
  Future<void> reportVisibility(CompanionVisibility visibility);

  /// Says which session is on this companion's screen, or null for none.
  ///
  /// Same rule and same purpose as [reportVisibility]: it can only ever turn a
  /// suppressed push into a sent one, never the other way round.
  Future<void> reportFocusedSession(String? sessionId);

  /// `sessions.list` — one snapshot.
  Future<List<CompanionSessionSummary>> listSessions();

  /// The snapshot plus every `session.changed` folded in.
  Stream<List<CompanionSessionSummary>> watchSessions();

  /// `session.subscribe` + `transcript.get`/`transcript.appended` for one
  /// session, as the full list the chat view renders.
  ///
  /// See also [CompanionGateway.sendPrompt].
  Stream<List<CompanionChatMessage>> transcript(String sessionId);

  /// **What one session is doing right now**, seeded on listen and then every
  /// change the host states.
  ///
  /// Costs the host no read of its own: the desktop derives this from the same
  /// transcript parse the transcript poll already pays for. A pairing without
  /// `view_activity` gets one reading carrying the host's refusal in words —
  /// see [CompanionActivity.refused] — rather than an empty list that would
  /// read as "nothing is running".
  Stream<CompanionActivity> activity(String sessionId);

  /// The pending approval for one session, or null when nothing is waiting.
  ///
  /// Re-derived from the host rather than accumulated: an approval answered
  /// anywhere — the desktop, another paired phone, the agent giving up —
  /// clears here, including one resolved while this phone was off the link.
  Stream<CompanionApproval?> pendingApproval(String sessionId);

  /// Approvals going away, and why. Events-only, like [attentionEvents]: a
  /// screen subscribes to say what happened, and a screen that was not open
  /// has nothing to say.
  Stream<CompanionApprovalResolution> get approvalResolutions;

  /// `workspace.list` — the desktop's projects, their checkouts and the agents
  /// installed where each checkout lives.
  ///
  /// The host's own payload type, not a second vocabulary: unlike a session
  /// row there is nothing here for the phone to re-word — the desktop already
  /// wrote every label and every sentence, including what a permission mode
  /// does to a given agent.
  Future<List<RemoteWorkspaceProject>> listWorkspace();

  Future<List<RemoteWorkspaceProject>> listProjects();

  Future<RemoteWorkspaceProject> addProject({
    required String requestId,
    required String name,
    required String path,
  });

  /// `session.start` — starts a new session and answers with it.
  ///
  /// [requestId] is the phone's idempotency key: resend the SAME value to
  /// retry a request whose answer never arrived, and mint a fresh one the
  /// moment the user changes what they are asking for. [permissionMode] is
  /// the mode the **user** picked from what [listWorkspace] offered.
  Future<RemoteSessionStarted> startSession({
    required String requestId,
    required String repositoryId,
    required String installationId,
    required String permissionMode,
    String? title,
    String? message,
  });

  Future<RemoteSessionStarted> resumeSession({
    required String requestId,
    required String sessionId,
  });

  /// `prompt.send`.
  /// Sends a prompt, optionally with one file.
  ///
  /// [attachment] is uploaded first — declared, sliced, and each slice
  /// acknowledged — and the prompt then quotes it, so a file that did not
  /// arrive whole takes the prompt with it rather than being half-committed.
  /// [onProgress] is called with the slices sent and the total; a 4 MB photo
  /// off a phone is thirty-two of them over somebody's mobile data, and a
  /// silent spinner for that long is the "did that go?" this composer's whole
  /// design is against.
  ///
  /// Answers what became of it — a prompt carrying a file is **offered** to the
  /// desktop's own message box rather than typed into the agent.
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    CompanionOutgoingAttachment? attachment,
    void Function(int sent, int total)? onProgress,
  });

  /// `approval.answer`.
  Future<void> answerApproval(
    String sessionId,
    String approvalId,
    CompanionApprovalDecision decision,
  );

  /// Attention news (finished / needs you / failed) as it arrives — what local
  /// notifications are cut from.
  Stream<CompanionAttentionEvent> get attentionEvents;
}

/// The gateway the companion UI reads.
///
/// Defaults to an unpaired [FakeCompanionGateway] so companion mode boots to
/// the pairing screen with no host wired; the orchestrator overrides this with
/// Loop 70's real client at integration.
final companionGatewayProvider = Provider<CompanionGateway>(
  (ref) => FakeCompanionGateway(),
);
