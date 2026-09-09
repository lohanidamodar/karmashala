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

import '../domain/companion_presence.dart';
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

/// One read of a session's record: the turns the phone renders, and what that
/// same read says is still in flight.
///
/// A record rather than two bindings because it is **one file**. The poll
/// sweep already re-reads a watched session's whole transcript — the largest in
/// this repo is 53 MB of JSONL — and asking a second time for the activity
/// would double exactly the cost that made that sweep starve the link.
typedef RemoteSessionRecord = ({
  RemoteTranscriptPage page,
  RemoteSessionActivity activity,
});

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
    required this.beginAttachment,
    required this.writeAttachmentChunk,
    required this.discardAttachment,
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
  ///
  /// Answers with the activity that same read implies — see
  /// [RemoteSessionRecord] — derived by `sessionActivityFrom`, the one rule the
  /// desktop strip is also drawn from.
  final Future<RemoteSessionRecord> Function(String sessionId) transcriptFor;

  /// Routes a prompt into the session exactly as the desktop composer does.
  ///
  /// [attachment] names an upload the sending device completed — the device
  /// travels with it because an upload belongs to a link, not to a session. **A prompt carrying
  /// one is offered, not sent**: it lands in the session's composer draft,
  /// where the desktop user reads the path before an agent is told to open a
  /// file off their disk — the rule `ComposerDrafts` was written for. A prompt
  /// without one keeps going straight through, which is what a phone sending
  /// words has always done. Answers which of the two happened.
  final Future<RemotePromptDelivery> Function(
    String sessionId,
    String text, {
    RemoteAttachmentRef? attachment,
  })
  sendPrompt;

  /// Answers a pending approval; [decision] is `approve` or `deny`. Returns
  /// the label of the key actually pressed, or throws [RemoteApiRefusal].
  final Future<String> Function(String sessionId, String decision)
  answerApproval;

  /// The Loop-49 evidence for a pending approval — the agent's words or
  /// nothing.
  final Future<RemoteApprovalRequest> Function(String sessionId)
  approvalEvidenceFor;

  /// Persists a push registration for [deviceId], and the presence the phone
  /// sent with it.
  ///
  /// [presence] is additive and is [CompanionPresence.unknown] for a companion
  /// that says nothing — which is every build before the field existed, and is
  /// why nothing here is required.
  final Future<void> Function(
    String deviceId,
    String token,
    String platform,
    CompanionPresence presence,
  )
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

  /// Opens an upload for one device, after the caller has checked the request
  /// against the session's own [RemoteAttachmentSupport].
  ///
  /// A device has at most one upload in flight; a second [beginAttachment]
  /// abandons the first. Throws [RemoteApiRefusal] for anything the
  /// declaration alone can be refused for.
  final Future<RemoteAttachmentOffer> Function(
    String deviceId,
    RemoteAttachmentBegin request,
  )
  beginAttachment;

  /// Appends one chunk, in order. Out of order is a lost slice, and refused.
  final Future<void> Function(
    String deviceId,
    String uploadId,
    int seq,
    List<int> data,
  )
  writeAttachmentChunk;

  /// Drops whatever [deviceId] left half-sent — called when its link ends, so
  /// staged bytes nothing will ever quote do not outlive the link that made
  /// them.
  final Future<void> Function(String deviceId) discardAttachment;
}

/// One completed upload, named by the link that carried it.
///
/// The device travels with the id because an upload belongs to a **link**: the
/// store keys on the device so two phones cannot reach each other's staged
/// bytes, and a session id would not say which phone this was.
typedef RemoteAttachmentRef = ({String deviceId, String uploadId});
