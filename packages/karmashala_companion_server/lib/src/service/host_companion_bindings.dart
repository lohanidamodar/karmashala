import 'dart:async';

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../store/companion_attachment_store.dart';
import 'companion_prompts.dart';
import 'hosted_session_control.dart';
import 'hosted_workspace.dart';
import 'sessions_at_rest.dart';

/// What a phone is told when the server was composed without the part a call
/// needs — a server with no store, or one still starting. Never "open the
/// app": since slice 5c no call depends on a desktop being open.
const String kCompanionNotServedHere =
    'this Karmashala server cannot do that right now; try again in a moment';

/// The refusal for [kCompanionNotServedHere]. `badRequest`, because nothing
/// was withheld from this phone.
const RemoteApiRefusal companionNotServedHere = RemoteApiRefusal(
  ErrorCode.badRequest,
  kCompanionNotServedHere,
);

/// The companion bindings the server serves a phone with (slice 5c: **always
/// the server's**, whether or not a desktop is open — nothing is forwarded):
///
/// - Sessions, their attention and what their agents are doing
///   ([atRest]): the store's rows, the imported history, the server's own
///   status and inbox, and the screens of the sessions it runs.
/// - Prompts ([hosted], for the sessions [holds] names): approvals,
///   questions and menus read off the server's own screen and typed into the
///   PTY it holds. A session it does not run is refused in words.
/// - The workspace and adding a project ([workspace]), starting and resuming
///   sessions and a session's model or mode ([control]), attachments
///   ([attachments]), usage ([usage]), notes and push registration.
RemoteHostBindings hostCompanionBindings({
  required String hostName,
  required SessionsAtRest atRest,
  CompanionPrompts? hosted,
  bool Function(String sessionId)? holds,
  HostedWorkspace? workspace,
  HostedSessionControl? control,
  Future<RemoteUsageSnapshot> Function()? usage,
  CompanionAttachmentStore? attachments,
  String? Function(String sessionId)? deliveryStageOf,
  required Future<RemoteNotesSnapshot> Function() notes,
  required Future<void> Function(
    String deviceId,
    String token,
    String platform,
    CompanionPresence presence,
  )
  registerPush,
}) {
  /// [here]'s answer, or [companionNotServedHere] when the server was composed
  /// without it.
  Future<T> served<T, S extends Object>(
    S? here,
    FutureOr<T> Function(S here) answer,
  ) {
    if (here == null) return Future.error(companionNotServedHere);
    return Future.sync(() => answer(here));
  }

  /// A store refusal, in words the wire can carry.
  Future<T> staged<T>(Future<T> Function() write) async {
    try {
      return await write();
    } on AttachmentUploadException catch (failure) {
      throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
    }
  }

  /// The server's answer for a session it runs; anything else is refused in
  /// words — imported history, or a session no server here runs.
  Future<T> prompted<T>(
    String sessionId,
    Future<T> Function(CompanionPrompts prompts) here,
  ) {
    final prompts = hosted;
    if (prompts != null && (holds?.call(sessionId) ?? false)) {
      return here(prompts);
    }
    return Future.error(atRest.notAnswerableHere(sessionId));
  }

  return RemoteHostBindings(
    hostName: hostName,
    listSessions: atRest.list,
    sessionById: atRest.byId,
    // The server's own delivery reading, as its poll last took it; "could
    // not tell" (null) for a session it has not read — a phone is never made
    // to wait on git or the forge.
    deliveryStageFor: (sessionId) async => deliveryStageOf?.call(sessionId),
    transcriptFor: atRest.transcript,
    readRecordState: atRest.recordState,
    sendPrompt: atRest.sendPrompt,
    answerApproval: (sessionId, decision) => prompted(
      sessionId,
      (prompts) => prompts.answerApproval(sessionId, decision),
    ),
    approvalEvidenceFor: (sessionId) =>
        prompted(sessionId, (prompts) => prompts.approvalEvidence(sessionId)),
    answerQuestion: (request) => prompted(
      request.sessionId,
      (prompts) => prompts.answerQuestion(request),
    ),
    answerMenu: (request) =>
        prompted(request.sessionId, (prompts) => prompts.answerMenu(request)),
    usage: () => usage == null ? Future.error(companionNotServedHere) : usage(),
    notes: notes,
    registerPush: registerPush,
    listWorkspace: () => served(workspace, (here) => here.listWorkspace()),
    listProjects: () => served(workspace, (here) => here.listProjects()),
    addProject: (name, path) =>
        served(workspace, (here) => here.addProject(name, path)),
    startSession: (request) => served(control, (here) => here.start(request)),
    resumeSession: (sessionId) =>
        served(control, (here) => here.resume(sessionId)),
    sessionOptions: (sessionId) =>
        served(control, (here) => here.options(sessionId)),
    configureSession: (sessionId, {model, permission}) => served(
      control,
      (here) => here.configure(sessionId, model: model, permission: permission),
    ),
    beginAttachment: (deviceId, request) => served(
      attachments,
      (store) => staged(() => store.begin(deviceId, request)),
    ),
    writeAttachmentChunk: (deviceId, uploadId, seq, data) => served(
      attachments,
      (store) => staged(() => store.write(deviceId, uploadId, seq, data)),
    ),
    // Told, not awaited: it runs as a phone's link is torn down.
    discardAttachment: (deviceId) async => attachments?.discard(deviceId),
  );
}
