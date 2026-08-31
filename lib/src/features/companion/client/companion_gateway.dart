/// The companion app's one seam onto a paired desktop host.
///
/// Loop 70 builds the real protocol client (`features/remote/client/`) in
/// parallel with this UI; the two must not collide, so the companion talks to
/// this interface and the orchestrator wires the real client behind it at
/// integration. The shape deliberately mirrors what `remote/protocol.dart`
/// offers — one method or stream per frame type, nothing the protocol cannot
/// carry — and reuses its types (`CapabilitySet`, `DeviceId`) where they fit.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  /// The scanned or typed input parsed as a Chitragupta code.
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

  /// A narrow copy: only the facts that change while a session is listed.
  CompanionSessionSummary copyWith({
    CompanionSessionStatus? status,
    CompanionAttention? attention,
    DateTime? lastActivityAt,
    bool? archived,
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
  );

  /// What the list groups by: the repository's real identity when the host
  /// sent one, its display name otherwise.
  String get projectKey => projectId ?? 'name:$projectName';
}

/// One transcript turn. Role vocabulary matches the desktop chat view:
/// `user`, `agent`, `tool`, or `error`.
class CompanionChatMessage {
  const CompanionChatMessage({required this.role, required this.text});

  final String role;
  final String text;
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
    this.approveLabel,
    this.approveEffect,
    this.denyLabel,
    this.denyEffect,
  });

  final String id;
  final String sessionId;
  final String agentName;

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

  /// Which path carries the link — [CompanionLinkPath.lan] at home,
  /// [CompanionLinkPath.relay] elsewhere — or null while not connected.
  CompanionLinkPath? get linkPath;
  Stream<CompanionLinkPath?> get linkPathStates;

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

  /// `sessions.list` — one snapshot.
  Future<List<CompanionSessionSummary>> listSessions();

  /// The snapshot plus every `session.changed` folded in.
  Stream<List<CompanionSessionSummary>> watchSessions();

  /// `session.subscribe` + `transcript.get`/`transcript.appended` for one
  /// session, as the full list the chat view renders.
  Stream<List<CompanionChatMessage>> transcript(String sessionId);

  /// The pending approval for one session, or null when nothing is waiting.
  Stream<CompanionApproval?> pendingApproval(String sessionId);

  /// `prompt.send`.
  Future<void> sendPrompt(String sessionId, String text);

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
