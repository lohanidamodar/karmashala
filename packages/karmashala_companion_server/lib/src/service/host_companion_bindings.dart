import 'dart:async';

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../protocol/forwarded_bindings.dart';
import 'companion_app_link.dart';
import 'companion_prompts.dart';
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
/// - **The app's, or refused**: everything else that needs the desktop —
///   starting and resuming through the launcher, the composer's attachments,
///   workspaces, usage and a session's model or mode. With no app connected
///   the phone is told "the Karmashala app is not running".
RemoteHostBindings hostCompanionBindings({
  required String hostName,
  required CompanionAppLink app,
  required SessionsAtRest atRest,
  CompanionPrompts? hosted,
  bool Function(String sessionId)? holds,
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
    usage: () => appOnly(forwarded.usage),
    notes: notes,
    registerPush: registerPush,
    listWorkspace: () => appOnly(forwarded.listWorkspace),
    listProjects: () => appOnly(forwarded.listProjects),
    startSession: (request) => appOnly(() => forwarded.startSession(request)),
    addProject: (name, path) => appOnly(() => forwarded.addProject(name, path)),
    resumeSession: (sessionId) =>
        appOnly(() => forwarded.resumeSession(sessionId)),
    beginAttachment: (deviceId, request) =>
        appOnly(() => forwarded.beginAttachment(deviceId, request)),
    writeAttachmentChunk: (deviceId, uploadId, seq, data) => appOnly(
      () => forwarded.writeAttachmentChunk(deviceId, uploadId, seq, data),
    ),
    // Told, not awaited: it runs as a phone's link is torn down, which must not
    // wait on the app. Nothing to drop when the app that staged the bytes is
    // gone: its own store sweeps on its next start.
    discardAttachment: (deviceId) async {
      if (!app.connected) return;
      unawaited(
        forwarded.discardAttachment(deviceId).then((_) {}, onError: (_) {}),
      );
    },
    sessionOptions: (sessionId) =>
        appOnly(() => forwarded.sessionOptions(sessionId)),
    configureSession: (sessionId, {model, permission}) => appOnly(
      () => forwarded.configureSession(
        sessionId,
        model: model,
        permission: permission,
      ),
    ),
  );
}
