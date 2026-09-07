/// What the host session API needs from the rest of the desktop app, as a
/// bag of functions.
///
/// The production wiring (`remote_bindings.dart`) points every one of these at
/// the SAME provider the desktop UI reads — the composer's send path, the
/// Loop-49 approval keys, the chat view's transcript source — so the phone can
/// never see a different truth than the screen. Tests hand in closures over
/// plain maps, which is what keeps the protocol tests free of processes,
/// terminals and agents.
library;

import '../domain/remote_payloads.dart';
import '../protocol.dart';

/// A handler refusing a request for a reason the protocol can carry.
class RemoteApiRefusal implements Exception {
  const RemoteApiRefusal(this.code, this.message);

  final ErrorCode code;

  /// Safe to put on the wire: names the refusal, never quotes content.
  final String message;

  @override
  String toString() => 'RemoteApiRefusal(${code.wire}: $message)';
}

class RemoteHostBindings {
  const RemoteHostBindings({
    required this.hostName,
    required this.listSessions,
    required this.sessionById,
    required this.deliveryStageFor,
    required this.transcriptFor,
    required this.sendPrompt,
    required this.answerApproval,
    required this.approvalEvidenceFor,
    required this.registerPush,
    required this.listWorkspace,
    required this.listProjects,
    required this.startSession,
    required this.addProject,
    required this.resumeSession,
  });

  /// What `host.status` calls this desktop.
  final String hostName;

  /// Every session the desktop would list — imported CLI history included,
  /// flagged — already shaped for the wire. Stage is deliberately absent
  /// here (it costs a git/gh probe per session); [HostSessionApi] folds it
  /// in via [deliveryStageFor] when it answers `sessions.list`.
  final List<RemoteSessionSnapshot> Function() listSessions;

  final RemoteSessionSnapshot? Function(String sessionId) sessionById;

  /// The delivery stage of one *subscribed* session, or null for "could not
  /// tell". Production reads `sessionDeliveryProvider` — the same probe the
  /// desktop strip pays for a session on screen.
  final Future<String?> Function(String sessionId) deliveryStageFor;

  /// The full transcript, from the same source the desktop chat view reads:
  /// the agent's own record for a PTY session, the engine's event log
  /// otherwise. Attribution is rebuilt from typed fields, never parsed out.
  final Future<RemoteTranscriptPage> Function(String sessionId) transcriptFor;

  /// Routes a prompt into the session exactly as the desktop composer does.
  final Future<void> Function(String sessionId, String text) sendPrompt;

  /// Answers a pending approval; [decision] is `approve` or `deny`. Returns
  /// the label of the key actually pressed, or throws [RemoteApiRefusal].
  final Future<String> Function(String sessionId, String decision)
  answerApproval;

  /// The Loop-49 evidence for a pending approval — the agent's words or
  /// nothing.
  final Future<RemoteApprovalRequest> Function(String sessionId)
  approvalEvidenceFor;

  /// Persists a push registration for [deviceId]. Delivery is Loop D.
  final Future<void> Function(String deviceId, String token, String platform)
  registerPush;

  /// What could be started here: the desktop's projects, their checkouts, and
  /// the agents actually installed where each checkout lives.
  ///
  /// Reported from the same DAOs the Explorer draws, so a checkout the desktop
  /// does not hold is absent rather than guessed at from a session that
  /// mentions it. Synchronous, like [listSessions], and for the same reason:
  /// it must not start a process per repository.
  final List<RemoteWorkspaceProject> Function() listWorkspace;
  final List<RemoteWorkspaceProject> Function() listProjects;

  /// Starts a new session, through the one write path the desktop's own New
  /// session dialog uses.
  ///
  /// Everything the launcher decides stays the launcher's: the permission
  /// mode it stamps, the depth cap, the resume and fork guards, and the
  /// refusal of an opening message an agent's CLI cannot take. Nothing here
  /// re-implements any of it — this binding resolves the two ids, hands the
  /// user's chosen mode over as the override, and turns whatever comes back
  /// out into a [RemoteApiRefusal] the phone can read.
  final Future<RemoteSessionStarted> Function(
    RemoteSessionStartRequest request,
  )
  startSession;

  final Future<RemoteWorkspaceProject> Function(String name, String path)
  addProject;

  final Future<RemoteSessionStarted> Function(String sessionId) resumeSession;
}
