/// What the host session API needs from the rest of the desktop app, as a bag
/// of functions. The production wiring points every one at the SAME provider
/// the desktop UI reads, so the phone can never see a different truth than the
/// screen; tests hand in closures over plain maps.
library;

import '../domain/companion_presence.dart';
import '../domain/remote_payloads.dart';
import '../domain/remote_usage.dart';
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
/// same read says is still in flight. A record rather than two bindings because
/// it is **one file** — asking a second time would double exactly the cost that
/// made the poll sweep starve the link.
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
    this.answerQuestion = _noQuestions,
    this.answerMenu = _noMenus,
    this.usage = _noUsage,
  });

  /// What `host.status` calls this desktop.
  final String hostName;

  /// Every session the desktop would list, imported CLI history included,
  /// already shaped for the wire. Stage is deliberately absent — it costs a
  /// git/gh probe per session — and [HostSessionApi] folds it in later.
  final List<RemoteSessionSnapshot> Function() listSessions;

  final RemoteSessionSnapshot? Function(String sessionId) sessionById;

  /// The delivery stage of one *subscribed* session, or null for "could not
  /// tell". Production reads `sessionDeliveryProvider` — the same probe the
  /// desktop strip pays for a session on screen.
  final Future<String?> Function(String sessionId) deliveryStageFor;

  /// The full transcript, from the same source the desktop chat view reads.
  /// Attribution is rebuilt from typed fields, never parsed out. Answers with
  /// the activity that same read implies — see [RemoteSessionRecord].
  final Future<RemoteSessionRecord> Function(String sessionId) transcriptFor;

  /// Routes a prompt into the session exactly as the desktop composer does.
  /// **A prompt carrying an [attachment] is offered, not sent**: it lands in the
  /// session's composer draft, where the desktop user reads the path before an
  /// agent is told to open a file off their disk. Answers which of the two happened.
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
  /// sent with it. [presence] is additive, and [CompanionPresence.unknown] for
  /// a companion that says nothing.
  final Future<void> Function(
    String deviceId,
    String token,
    String platform,
    CompanionPresence presence,
  )
  registerPush;

  /// What could be started here: the desktop's projects, their checkouts and
  /// the agents installed where each lives. Reported from the same DAOs the
  /// Explorer draws, and synchronous, so it starts no process per repository.
  final List<RemoteWorkspaceProject> Function() listWorkspace;
  final List<RemoteWorkspaceProject> Function() listProjects;

  /// Starts a new session, through the one write path the desktop's New session
  /// dialog uses. Everything the launcher decides stays the launcher's; this
  /// resolves the two ids, hands the user's mode over as the override, and
  /// turns whatever comes back into a [RemoteApiRefusal] the phone can read.
  final Future<RemoteSessionStarted> Function(
    RemoteSessionStartRequest request,
  )
  startSession;

  final Future<RemoteWorkspaceProject> Function(String name, String path)
  addProject;

  final Future<RemoteSessionStarted> Function(String sessionId) resumeSession;

  /// Opens an upload for one device, after the caller has checked the request
  /// against the session's own [RemoteAttachmentSupport]. A device has at most
  /// one upload in flight; a second [beginAttachment] abandons the first.
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

  /// Answers, or declines, the multiple-choice question [request] names.
  /// Returns a short word for what was done, or throws [RemoteApiRefusal].
  /// Defaults to refusing: a host that never learned questions answers none.
  final Future<String> Function(RemoteQuestionAnswerRequest request)
  answerQuestion;

  /// Chooses the option [request] names of the menu on the session's screen.
  /// Returns the option's words, or throws [RemoteApiRefusal] with nothing
  /// chosen. Defaults to refusing: a host that never learned menus reads none.
  final Future<String> Function(RemoteMenuAnswerRequest request) answerMenu;

  /// Every agent account's usage limits, read through the desktop's own
  /// throttle — asking from the phone never costs a request the throttle would
  /// not have allowed. Defaults to refusing.
  final Future<RemoteUsageSnapshot> Function() usage;
}

Future<RemoteUsageSnapshot> _noUsage() async => throw const RemoteApiRefusal(
  ErrorCode.badRequest,
  'this host cannot report usage',
);

Future<String> _noQuestions(RemoteQuestionAnswerRequest request) async =>
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'this host cannot answer questions',
    );

Future<String> _noMenus(RemoteMenuAnswerRequest request) async =>
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'this host cannot answer menus',
    );

/// One completed upload, named by the link that carried it. The device travels
/// with the id because an upload belongs to a **link**: the store keys on the
/// device, so two phones cannot reach each other's staged bytes.
typedef RemoteAttachmentRef = ({String deviceId, String uploadId});
