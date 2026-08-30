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

/// Whether the phone can currently talk to the host it is paired with.
enum CompanionLinkState { disconnected, connecting, connected }

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
    this.projectPath,
    this.status = CompanionSessionStatus.unknown,
    this.whereabouts,
    this.branch,
    this.subPath,
    this.worktree = false,
    this.lastActivityAt,
    this.attention,
  });

  final String id;
  final String title;

  /// "Claude Code · running" — the card's first line, worded by the host so
  /// the phone never invents a claim about a process it cannot see.
  final String agentLabel;

  final String projectName;
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
  });

  final String sessionId;
  final String sessionTitle;
  final CompanionAttentionKind kind;
  final DateTime at;
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

  /// What the desktop granted at pairing; [CapabilitySet.none] when unpaired.
  CapabilitySet get capabilities;

  /// Pairs from a scanned QR payload (the JSON the desktop displays).
  Future<CompanionPairing> pairWithQr(String qrPayload);

  /// Pairs from the 8-character short code shown on the desktop.
  Future<CompanionPairing> pairWithCode(String shortCode);

  /// Forgets the pairing on this phone. (Revoking the phone's key on the host
  /// is the desktop's verb, not this one.)
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
