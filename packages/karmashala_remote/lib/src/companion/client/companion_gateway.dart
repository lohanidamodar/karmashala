/// The companion app's one seam onto a paired desktop host. Mirrors what
/// `remote/protocol.dart` offers — one method or stream per frame type — and
/// reuses its types where they fit.
library;

import 'dart:typed_data';

import '../../domain/companion_presence.dart';
import '../../domain/remote_payloads.dart';
import '../../domain/remote_session_options.dart';
import '../../domain/remote_notes.dart';
import '../../domain/remote_usage.dart';
import '../../client/route_pin.dart';
import '../../pairing/host_pairing_invite.dart' show HostRoute;
import '../../protocol.dart';

export '../../client/route_pin.dart';
export '../../pairing/host_pairing_invite.dart' show HostRoute;

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

/// The relay a typed pairing code falls back to when the phone has configured
/// none. Pinned equal to the desktop's `kDefaultRelayUrl` by test.
const String kDefaultCompanionRelayUrl = 'wss://relay.popupbits.com';

/// Whether the phone can currently talk to the host it is paired with.
enum CompanionLinkState { disconnected, connecting, connected }

/// Where one pairing attempt currently stands. [failed] is terminal for the
/// attempt; everything before it walks forward in declaration order.
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
    this.route,
    this.directEndpoint,
  });

  /// How a session host on a box is reached; null for a desktop.
  final HostRoute? route;

  /// `host:port` of a box reached directly; null otherwise.
  final String? directEndpoint;

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
    this.route,
    this.directEndpoint,
    this.pin = CompanionRoutePin.auto,
    this.relays = const [],
  });

  /// How the person has asked for this desktop to be reached. Always
  /// [CompanionRoutePin.auto] for a box, which keeps the route it was paired
  /// over.
  final CompanionRoutePin pin;

  /// The relays the desktop has announced, in the order it announced them —
  /// what a pin may choose between. May no longer include a pinned relay.
  final List<Uri> relays;

  /// How a session host on a box is reached — [HostRoute.direct] at
  /// [directEndpoint], or [HostRoute.relay]. Null for a desktop, which the
  /// phone finds by itself.
  final HostRoute? route;

  /// `host:port` of a box reached directly; null otherwise.
  final String? directEndpoint;

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

  CompanionConnection copyWith({bool? active, CompanionRoutePin? pin}) =>
      CompanionConnection(
        hostId: hostId,
        name: name,
        active: active ?? this.active,
        lastConnectedAt: lastConnectedAt,
        route: route,
        directEndpoint: directEndpoint,
        pin: pin ?? this.pin,
        relays: relays,
      );

  @override
  bool operator ==(Object other) =>
      other is CompanionConnection &&
      other.hostId == hostId &&
      other.name == name &&
      other.active == active &&
      other.lastConnectedAt == lastConnectedAt &&
      other.route == route &&
      other.directEndpoint == directEndpoint &&
      other.pin == pin &&
      _sameUris(other.relays, relays);

  @override
  int get hashCode => Object.hash(
    hostId,
    name,
    active,
    lastConnectedAt,
    route,
    directEndpoint,
    pin,
    Object.hashAll([for (final url in relays) url.toString()]),
  );

  static bool _sameUris(List<Uri> a, List<Uri> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].toString() != b[i].toString()) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'CompanionConnection($name, $hostId${active ? ', active' : ''})';
}

/// One session's status, in the terms the phone shows: what its agent is
/// doing while the session runs, and how it ended once it has.
enum CompanionSessionStatus {
  working,
  idle,
  needsYou,

  /// The agent's turn failed, or the session ended in error.
  failed,

  /// Nobody can say: no status is kept, or the host lost sight of the
  /// session.
  unknown,

  /// The session ended on its own (`completed`).
  ended,

  /// The user ended it (`cancelled`).
  stoppedByYou;

  /// Whether this is how the session ended rather than what its agent is
  /// doing — never replaced by a later reading of the agent.
  bool get isEnding =>
      this == CompanionSessionStatus.ended ||
      this == CompanionSessionStatus.stoppedByYou;
}

/// Why a session is (or was) asking for the user — the attention-inbox kinds
/// the host forwards (design §5: finished / needs you / failed).
enum CompanionAttentionKind {
  finished,
  needsYou,
  failed,

  /// The session's turn ended on its account's usage limit.
  usageLimit;

  String get label => switch (this) {
    CompanionAttentionKind.finished => 'Finished',
    CompanionAttentionKind.needsYou => 'Needs you',
    CompanionAttentionKind.failed => 'Failed',
    CompanionAttentionKind.usageLimit => 'Hit a usage limit',
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
    this.live = false,
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
    this.environmentName,
    this.environmentId,
    this.environmentKind,
    this.model,
    this.usageLimit,
  });

  final String id;
  final String title;

  /// The model the desktop launched this session on, or null when it names
  /// none (the agent's own default, which the desktop does not know).
  final String? model;

  /// The desktop's sentence while this session sits on a usage limit — "Codex
  /// hit its 5-hour limit. Resets 14:05." — else null.
  final String? usageLimit;

  /// "Claude Code · running" — the card's first line, worded by the host so
  /// the phone never invents a claim about a process it cannot see.
  final String agentLabel;

  final String projectName;

  /// The repository's real identity on the host, so two checkouts sharing a
  /// folder name stay two projects. Null from a host too old to send one.
  final String? projectId;

  final String? projectPath;
  final CompanionSessionStatus status;

  /// Whether the session's process is running on the host. A live session
  /// whose agent is [CompanionSessionStatus.idle] sits at its own prompt:
  /// running, not ended, so it is sent a message rather than resumed.
  final bool live;

  /// Loop 46's whereabouts clause, verbatim from the host.
  final String? whereabouts;

  final String? branch;
  final String? subPath;
  final bool worktree;

  /// When the host last heard anything from this session.
  final DateTime? lastActivityAt;

  /// Set while this session is in the host's attention inbox.
  final CompanionAttention? attention;

  /// How far the work has travelled (`DeliveryStage.name`), or null for "could
  /// not tell", which is a first-class answer.
  final String? deliveryStage;

  /// True for CLI history the desktop imported: readable, never steerable.
  final bool imported;

  /// True once the desktop has archived this session. Listed, and said so —
  /// the phone shows what the host holds rather than quietly hiding rows.
  final bool archived;

  /// True when the host says this session's folder is no longer on disk.
  final bool folderMissing;

  /// What a file sent to this session may be, straight off the row — so the
  /// composer knows **before** the user opens a picker and spends mobile data
  /// on a photo the desktop was never going to be able to use.
  final RemoteAttachmentSupport? attachments;

  /// The badge on a non-local session card ("WSL · Ubuntu"); null for local.
  final String? environmentBadge;

  /// What the desktop calls this machine — "macOS", "Windows", "Ubuntu".
  ///
  /// The machine list needs it precisely because [environmentBadge] is null for
  /// the local host: without a name the list fell back to [environmentId], and
  /// the local host's id is the literal `windows` on every platform, so a Mac
  /// showed up in the picker as "windows". Null from an older desktop.
  final String? environmentName;

  /// The desktop's own id for the machine this runs on, and what kind it is.
  /// **Null from a desktop older than these fields** — the phone groups by the
  /// badge then, and never invents an id.
  final String? environmentId;
  final String? environmentKind;

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
    live: live,
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
    environmentName: environmentName,
    environmentId: environmentId,
    environmentKind: environmentKind,
    model: model,
    usageLimit: usageLimit,
  );

  /// What the list groups by: the repository's real identity when the host
  /// sent one, its display name otherwise.
  String get projectKey => projectId ?? 'name:$projectName';
}

/// The role on the gateway's own marker for history the host kept back — drawn
/// as the top edge of the loaded window, never as a message.
const String kCompanionNoticeRole = 'notice';

/// The role on the gateway's own account of **why** a transcript is empty: the
/// wire carries the fact and the client words it. Drawn instead of the empty
/// state's welcome, which is what "running, but no transcript" looked like.
const String kCompanionAbsenceRole = 'absence';

/// One file on its way to a desktop: what the phone picked, in memory. [bytes]
/// rather than a path because Android's picker hands back a content URI whose
/// file the host will never see.
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

/// One transcript turn. Role vocabulary matches the desktop chat view, plus
/// [kCompanionNoticeRole] and [kCompanionAbsenceRole] for the gateway's markers.
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

  /// How long it had been running **when the host looked** — a duration, not an
  /// instant, so nothing here subtracts one machine's clock from another's.
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
  static final unknown = CompanionActivity(
    at: DateTime.fromMillisecondsSinceEpoch(0),
  );

  /// When this reading landed here, on the **phone's** clock: what a live
  /// elapsed time is counted from.
  final DateTime at;

  final List<CompanionActivityCall> calls;

  /// Why [calls] is empty, when the host said. Null means it could see and
  /// there was nothing, or that we were never told.
  final RemoteActivityAbsence? absence;

  /// The host's sentence when it would not answer, shown rather than swallowed
  /// into an empty list.
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

/// A pending approval, as `approval.requested` carries it. [evidence] is the
/// agent's own rows or hook message **verbatim**; a null [denyLabel] means the
/// agent's prompt names no way to decline.
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
    this.question,
    this.menu,
  });

  final String id;
  final String sessionId;
  final String agentName;

  /// The menu on the agent's screen, when the host read one — folder trust, a
  /// permission prompt. Answered by option with [CompanionGateway.answerMenu].
  final RemoteMenu? menu;

  /// The multiple-choice question itself, when [waiting] is
  /// [RemoteWaitKind.question] and the host could read it. Answered with
  /// [CompanionGateway.answerQuestion], never with approve/deny.
  final RemoteQuestion? question;

  /// What the host says the session is waiting on. [RemoteWaitKind.input] is a
  /// notice, never an approval — the answer there is a message, not a key.
  final RemoteWaitKind waiting;

  /// Rendered terminal rows or the hook's message, exactly as received. Empty
  /// means "we can tell it is asking, but not what".
  final List<String> evidence;

  final String? approveLabel;

  /// What pressing approve actually does ("presses Enter"): the phone types
  /// into another program on the user's behalf and must say so.
  final String? approveEffect;

  final String? denyLabel;
  final String? denyEffect;
}

/// The two answers `approval.answer` can carry.
enum CompanionApprovalDecision { approve, deny }

/// Why a pending approval stopped being pending. [approved] and [denied] only
/// for an answer this host applied for this phone; anything else is
/// [elsewhere], because the host cannot see what was chosen.
enum CompanionApprovalOutcome {
  approved,
  denied,
  elsewhere,

  /// A question this phone answered.
  answered;

  /// One line for the reader whose card just disappeared: a card that simply
  /// vanishes reads as a dropped request.
  String get sentence => switch (this) {
    CompanionApprovalOutcome.approved => 'Approved.',
    CompanionApprovalOutcome.denied => 'Declined.',
    CompanionApprovalOutcome.elsewhere =>
      'That request was already answered elsewhere.',
    CompanionApprovalOutcome.answered => 'Answered.',
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
    this.detail,
  });

  final String sessionId;
  final String sessionTitle;
  final CompanionAttentionKind kind;
  final DateTime at;

  /// The desktop's own sentence, when it sent one — "Codex hit its 5-hour
  /// limit. Resets 14:05."
  final String? detail;

  /// Which desktop this news came from, so a notification that arrives around a
  /// switch is never attributed to the wrong host.
  final String? hostId;
}

/// What the companion UI can ask of a paired host.
///
/// Stream contract: every stream but [attentionEvents] emits its current value
/// on listen and then each change; action futures throw [GatewayException] (or
/// [PairingException] for the pairing verbs) with a user-fit sentence.
abstract interface class CompanionGateway {
  /// The pairing in effect, or null when this phone has never paired (or was
  /// revoked/unpaired).
  CompanionPairing? get pairing;
  Stream<CompanionPairing?> get pairingStates;

  CompanionLinkState get link;
  Stream<CompanionLinkState> get linkStates;

  /// One plain sentence about why the link is not up, when the gateway knows
  /// something the banner's own words do not say. Null while connected.
  String? get linkTrouble;

  /// [linkTrouble] as it changes, seeded on listen: the reason is learned by a
  /// dial that failed while the phone was already `connecting`, so there is no
  /// state change behind it to rebuild on.
  Stream<String?> get linkTroubleStates;

  /// Which path carries the link — [CompanionLinkPath.lan] at home,
  /// [CompanionLinkPath.relay] elsewhere — or null while not connected.
  CompanionLinkPath? get linkPath;
  Stream<CompanionLinkPath?> get linkPathStates;

  /// When [link] last **changed** — not when it was last reported. Null until
  /// this phone has seen a change, and deliberately blind to the path: a link
  /// that heals from the LAN onto the relay never went down.
  DateTime? get linkSince;
  Stream<DateTime?> get linkSinceStates;

  /// The relay the link is running through right now, or null on the LAN path.
  /// A phone may hold several saved relays, so "Relay" alone no longer says which.
  Uri? get activeRelay;

  /// What the desktop granted at pairing; [CapabilitySet.none] when unpaired.
  CapabilitySet get capabilities;

  /// Pairs from a scanned QR payload. A phone that is already paired ADDS the
  /// new desktop and switches to it; pairing the SAME host replaces that one
  /// record and leaves the others alone.
  ///
  /// A QR with `kind: host` is a session host's invite (`HostPairingInvite`):
  /// it is paired over the one route it names — straight to its address, or
  /// through the relay it carries — and never over both.
  Future<CompanionPairing> pairWithQr(String qrPayload);

  /// Pairs from what the user typed or pasted: the grouped base32 code or the
  /// full JSON payload, sniffed apart here. Adds a connection, like [pairWithQr].
  /// [at] is `host:port` for a peer with an address of its own — a session
  /// host on a box. It is never discovered: the person typed it to reach the
  /// machine, and a box cannot read its own public address.
  Future<CompanionPairing> pairWithCode(String shortCode, {String? at});

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

  /// Makes [hostId] the active desktop: the current link is dropped and every
  /// derived state rebuilt for it. Throws [GatewayException] when [hostId] names
  /// no saved connection; a host that cannot be reached is not a failed switch.
  Future<void> switchTo(String hostId);

  /// Pins how [hostId] is reached, or lets the phone choose again with
  /// [CompanionRoutePin.auto]. Takes effect at once: the active desktop is
  /// re-dialled on the new route, its sessions kept. A pinned route that does
  /// not answer is said in [linkTrouble] and never swapped for another. Throws
  /// [GatewayException] for a machine paired directly, whose route was chosen
  /// on the desktop, and for a host this phone no longer holds.
  Future<void> setRoutePin(String hostId, CompanionRoutePin pin);

  /// Forgets one saved desktop. Removing the active one falls back to the
  /// most recently connected of the rest, or to unpaired when none remain.
  Future<void> removeConnection(String hostId);

  /// Forgets the pairing on this phone — the ACTIVE connection only. Revoking
  /// the phone's key on the host is the desktop's verb, not this one.
  Future<void> unpair();

  /// Asks the transport to try connecting now instead of waiting for backoff.
  Future<void> reconnect();

  /// Says whether this companion is on screen. **For routing notifications, and
  /// nothing else**: the desktop spends it in `PushFanout`, and nothing on the
  /// delivery path may read it. The same answer twice sends nothing.
  Future<void> reportVisibility(CompanionVisibility visibility);

  /// Says which session is on this companion's screen, or null for none. Same
  /// rule as [reportVisibility]: it can only turn a suppressed push into a sent
  /// one, never the other way round.
  Future<void> reportFocusedSession(String? sessionId);

  /// `sessions.list` — one snapshot.
  Future<List<CompanionSessionSummary>> listSessions();

  /// The snapshot plus every `session.changed` folded in.
  Stream<List<CompanionSessionSummary>> watchSessions();

  /// `session.subscribe` + `transcript.get`/`transcript.appended` for one
  /// session, as the full list the chat view renders.
  Stream<List<CompanionChatMessage>> transcript(String sessionId);

  /// **What one session is doing right now**, seeded on listen and then every
  /// change. A pairing without `view_activity` gets one reading carrying the
  /// host's refusal in words rather than an empty list that reads as idle.
  Stream<CompanionActivity> activity(String sessionId);

  /// The pending approval for one session, or null when nothing is waiting.
  /// Re-derived from the host rather than accumulated, so an approval answered
  /// anywhere clears here.
  Stream<CompanionApproval?> pendingApproval(String sessionId);

  /// Answers the question pending on [sessionId] — one [answers] entry per
  /// question, in order — or declines it. [approvalId] is the card being
  /// answered, so a card that has since been replaced is not answered.
  Future<void> answerQuestion(
    String sessionId,
    String approvalId, {
    List<RemoteQuestionAnswer> answers = const [],
    bool decline = false,
  });

  /// `session.options` — the models and permission modes [sessionId] can be
  /// put on, and which it is on.
  Future<RemoteSessionOptions> sessionOptions(String sessionId);

  /// `session.configure` — puts [sessionId] on a model and/or mode. A field
  /// left null is left alone; its `followsDefault` hands it back to the
  /// desktop's default. Answers what became of the session running now.
  Future<RemoteConfigureOutcome> configureSession(
    String sessionId, {
    String? modelId,
    bool modelFollowsDefault = false,
    String? permissionId,
    bool permissionFollowsDefault = false,
  });

  /// `usage.get` — every agent account's usage limits, as the desktop read
  /// them. Throws [GatewayException] with the host's words when refused, as a
  /// phone paired before usage existed is.
  Future<RemoteUsageSnapshot> usage();

  /// `notes.get` — the desktop's notes and todo list, read-only. Throws
  /// [GatewayException] with the host's words when refused, as a desktop
  /// that predates it does.
  Future<RemoteNotesSnapshot> notes();

  /// Chooses [option] of the menu pending on [sessionId]. [approvalId] is the
  /// card being answered, so a card that has since been replaced is not.
  Future<void> answerMenu(String sessionId, String approvalId, int option);

  /// Approvals going away, and why. Events-only, like [attentionEvents].
  Stream<CompanionApprovalResolution> get approvalResolutions;

  /// `workspace.list` — the desktop's projects, their checkouts and the agents
  /// installed where each checkout lives. The host's own payload type: the
  /// desktop already wrote every label, so there is nothing here to re-word.
  Future<List<RemoteWorkspaceProject>> listWorkspace();

  Future<List<RemoteWorkspaceProject>> listProjects();

  Future<RemoteWorkspaceProject> addProject({
    required String requestId,
    required String name,
    required String path,
  });

  /// `session.start` — starts a new session and answers with it. [requestId] is
  /// the phone's idempotency key: resend the SAME value to retry an answer that
  /// never arrived, mint a fresh one when the user changes what they ask for.
  Future<RemoteSessionStarted> startSession({
    required String requestId,
    required String repositoryId,
    required String installationId,
    required String permissionMode,
    String? title,
    String? message,
    bool worktree = false,
  });

  Future<RemoteSessionStarted> resumeSession({
    required String requestId,
    required String sessionId,
  });

  /// `prompt.send`. Sends a prompt, optionally with one file: [attachment] is
  /// uploaded and acknowledged first, so a file that did not arrive whole takes
  /// the prompt with it. Answers what became of it — a prompt carrying a file is
  /// **offered** to the desktop's message box rather than typed into the agent.
  /// [requestId] is the phone's idempotency key: the SAME value when retrying a
  /// send that went unanswered, a fresh one once the user changes the message.
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    CompanionOutgoingAttachment? attachment,
    void Function(int sent, int total)? onProgress,
    String? requestId,
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
