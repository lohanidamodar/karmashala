import 'dart:async';

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../protocol/forwarded_bindings.dart';
import '../store/companion_attachment_store.dart';
import 'companion_app_link.dart';
import 'companion_prompts.dart';
import 'hosted_session_control.dart';
import 'hosted_workspace.dart';
import 'sessions_at_rest.dart';

/// The companion bindings the session host serves a phone with — one binding
/// per row of the table in docs/daemon-architecture.md, Phase 4:
///
/// - **Always the host's**: `notes.get` and push registration, which are the
///   store and nothing else.
/// - **The app's while it is connected, the host's while it is not**: the
///   session list, a session's transcript and typing into it. The app's view
///   is richer — attention, titles it tracks, imported history, the agent's own
///   record — so it answers when it can; closed, the host answers from its rows
///   and its screens rather than refusing.
/// - **The host's for a session it holds, else the app's**: approvals,
///   questions, menus and the evidence for them — read off the host's own
///   screen by the agent's own rules and typed into the PTY it holds
///   ([hosted], for the sessions [holds] names), whether or not the app is
///   open. A session the host does not hold is the app's, or refused.
/// - **The app's while it is connected, the host's while it is not** — for a
///   phone driving a machine with no desktop: the workspace and adding a
///   project ([workspace]), starting and resuming sessions and a session's
///   model or mode ([control]), usage ([usage]) and attachments
///   ([attachments]). The app's answers are the launcher's, its composer's and
///   its Settings', so it keeps them while it is there. A host composed
///   without one of these refuses it with no app: "the Karmashala app is not
///   running".
RemoteHostBindings hostCompanionBindings({
  required String hostName,
  required CompanionAppLink app,
  required SessionsAtRest atRest,
  CompanionPrompts? hosted,
  bool Function(String sessionId)? holds,
  HostedWorkspace? workspace,
  HostedSessionControl? control,
  Future<RemoteUsageSnapshot> Function()? usage,
  CompanionAttachmentStore? attachments,
  required Future<RemoteNotesSnapshot> Function() notes,
  required Future<void> Function(
    String deviceId,
    String token,
    String platform,
    CompanionPresence presence,
  )
  registerPush,
}) {
  final forwarded = ForwardedBindings(app);

  /// Forwarded, or [companionAppNotRunning] when there is nobody to forward to.
  Future<T> appOnly<T>(Future<T> Function() call) {
    if (!app.connected) return Future.error(companionAppNotRunning);
    return call();
  }

  /// Forwarded while the app is connected, else the host's own answer from
  /// [here] — or [companionAppNotRunning] when the host was composed without
  /// one ([here] is null).
  Future<T> appOrHost<T, S extends Object>(
    S? here,
    Future<T> Function(S here) host,
    Future<T> Function() forward,
  ) {
    if (app.connected) return forward();
    if (here == null) return Future.error(companionAppNotRunning);
    return Future.sync(() => host(here));
  }

  /// A store refusal, in words the wire can carry.
  Future<T> staged<T>(Future<T> Function() write) async {
    try {
      return await write();
    } on AttachmentUploadException catch (failure) {
      throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
    }
  }

  /// The host's own answer for a session it holds, else the app's.
  Future<T> hostedOr<T>(
    String sessionId,
    Future<T> Function(CompanionPrompts prompts) here,
    Future<T> Function() forward,
  ) {
    final prompts = hosted;
    if (prompts != null && (holds?.call(sessionId) ?? false)) {
      return here(prompts);
    }
    return appOnly(forward);
  }

  return RemoteHostBindings(
    hostName: hostName,
    listSessions: () =>
        app.connected ? forwarded.listSessions() : atRest.list(),
    sessionById: (sessionId) => app.connected
        ? forwarded.sessionById(sessionId)
        : atRest.byId(sessionId),
    // "Could not tell" is a first-class answer, and the host cannot.
    deliveryStageFor: (sessionId) async =>
        app.connected ? forwarded.deliveryStage(sessionId) : null,
    transcriptFor: (sessionId) async => app.connected
        ? forwarded.transcript(sessionId)
        : atRest.transcript(sessionId),
    readRecordState: (sessionId) async => app.connected
        ? forwarded.recordState(sessionId)
        : atRest.recordState(sessionId),
    sendPrompt: (sessionId, text, {attachment}) => app.connected
        ? forwarded.sendPrompt(sessionId, text, attachment: attachment)
        : atRest.sendPrompt(sessionId, text, attachment: attachment),
    answerApproval: (sessionId, decision) => hostedOr(
      sessionId,
      (prompts) => prompts.answerApproval(sessionId, decision),
      () => forwarded.answerApproval(sessionId, decision),
    ),
    approvalEvidenceFor: (sessionId) => hostedOr(
      sessionId,
      (prompts) => prompts.approvalEvidence(sessionId),
      () => forwarded.approvalEvidence(sessionId),
    ),
    answerQuestion: (request) => hostedOr(
      request.sessionId,
      (prompts) => prompts.answerQuestion(request),
      () => forwarded.answerQuestion(request),
    ),
    answerMenu: (request) => hostedOr(
      request.sessionId,
      (prompts) => prompts.answerMenu(request),
      () => forwarded.answerMenu(request),
    ),
    usage: () => app.connected
        ? forwarded.usage()
        : usage == null
        ? Future.error(companionAppNotRunning)
        : usage(),
    notes: notes,
    registerPush: registerPush,
    listWorkspace: () => appOrHost(
      workspace,
      (here) async => here.listWorkspace(),
      forwarded.listWorkspace,
    ),
    listProjects: () => appOrHost(
      workspace,
      (here) async => here.listProjects(),
      forwarded.listProjects,
    ),
    addProject: (name, path) => appOrHost(
      workspace,
      (here) => here.addProject(name, path),
      () => forwarded.addProject(name, path),
    ),
    startSession: (request) => appOrHost(
      control,
      (here) => here.start(request),
      () => forwarded.startSession(request),
    ),
    resumeSession: (sessionId) => appOrHost(
      control,
      (here) => here.resume(sessionId),
      () => forwarded.resumeSession(sessionId),
    ),
    sessionOptions: (sessionId) => appOrHost(
      control,
      (here) => here.options(sessionId),
      () => forwarded.sessionOptions(sessionId),
    ),
    configureSession: (sessionId, {model, permission}) => appOrHost(
      control,
      (here) => here.configure(sessionId, model: model, permission: permission),
      () => forwarded.configureSession(
        sessionId,
        model: model,
        permission: permission,
      ),
    ),
    // An upload is staged by whoever will commit it: the app's composer while
    // it is connected, the host's own store while it is not. A prompt that
    // names it goes the same way ([sendPrompt] above).
    beginAttachment: (deviceId, request) => appOrHost(
      attachments,
      (store) => staged(() => store.begin(deviceId, request)),
      () => forwarded.beginAttachment(deviceId, request),
    ),
    writeAttachmentChunk: (deviceId, uploadId, seq, data) => appOrHost(
      attachments,
      (store) => staged(() => store.write(deviceId, uploadId, seq, data)),
      () => forwarded.writeAttachmentChunk(deviceId, uploadId, seq, data),
    ),
    // Told, not awaited: it runs as a phone's link is torn down, which must not
    // wait on the app. Both stores are asked: the bytes are in whichever was
    // serving when they were sent, and dropping nothing is harmless.
    discardAttachment: (deviceId) async {
      await attachments?.discard(deviceId);
      if (!app.connected) return;
      unawaited(
        forwarded.discardAttachment(deviceId).then((_) {}, onError: (_) {}),
      );
    },
  );
}
