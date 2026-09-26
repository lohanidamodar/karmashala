/// The production wiring of [RemoteHostBindings]: every function points at the
/// SAME provider the desktop UI reads, so the two can never disagree.
library;

import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_actions.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';
import 'remote_approval_bindings.dart';
import '../../sessions/application/session_status_providers.dart';
import 'remote_attachment_bindings.dart';
import 'remote_binding_support.dart';
import 'remote_providers.dart';
import 'remote_session_config_bindings.dart';
import 'remote_session_snapshots.dart';
import 'remote_session_start_bindings.dart';
import 'remote_transcript_bindings.dart';
import 'remote_notes_bindings.dart';
import 'remote_workspace_bindings.dart';

// The seams a test stubs are reached through this library, as they always
// were; moving them into their families must not move anybody's import.
export 'remote_approval_bindings.dart' show remotePromptsProvider;
export 'remote_binding_support.dart'
    show remoteCheckoutBranchProvider, remoteFolderMissingProvider;
export 'remote_session_snapshots.dart'
    show remoteDeliveryStageProvider, remoteSessionPresenceProvider;

final remoteHostBindingsProvider = Provider<RemoteHostBindings>((ref) {
  final projectAdds = <String, Future<RemoteWorkspaceProject>>{};

  ResolvedRemoteSession resolve(String sessionId) =>
      resolveRemoteSession(ref, sessionId);

  return RemoteHostBindings(
    hostName: Platform.localHostname,
    listSessions: () => listRemoteSessions(ref),
    sessionById: (sessionId) {
      final resolved = resolve(sessionId);
      final session = resolved.native;
      if (session != null) return remoteSessionSnapshot(ref, session);
      final imported = resolved.imported;
      return imported == null ? null : remoteImportedSnapshot(ref, imported);
    },
    deliveryStageFor: (sessionId) =>
        ref.read(remoteDeliveryStageProvider)(sessionId),
    transcriptFor: (sessionId) => remoteTranscriptFor(ref, sessionId),
    readRecordState: (sessionId) => remoteRecordReading(ref, sessionId),
    // The composer's own route. Async so an imported-session refusal is a
    // failed future, never a synchronous escape past a caller's error handling.
    sendPrompt: (sessionId, text, {attachment}) async {
      final resolved = resolve(sessionId);
      if (resolved.imported != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — read-only here; '
          'continue it in its own terminal',
        );
      }
      // The LIVE id, never the one the phone asked with: a stale imported id
      // names a record that cannot be typed into.
      final live = resolved.native?.id ?? sessionId;
      // Typed into an open menu or question, the text is lost and its Enter
      // picks whatever is highlighted — "No, exit" on a folder-trust prompt.
      final report = ref.read(sessionStatusLookupProvider)(live);
      if (report != null && (report.hasOpenPrompt || report.hasOpenQuestion)) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session is waiting on a prompt — answer it first, then send',
        );
      }
      if (attachment == null) {
        await ref.read(sessionActionsProvider).continueSession(live, text);
        return RemotePromptDelivery.sent;
      }
      await offerRemoteAttachment(ref, live, text, attachment);
      return RemotePromptDelivery.offered;
    },
    answerApproval: (sessionId, decision) async {
      final resolved = resolve(sessionId);
      if (resolved.imported != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — answer it in its own '
          'terminal',
        );
      }
      return ref
          .read(remotePromptsProvider)
          .answerApproval(resolved.native?.id ?? sessionId, decision);
    },
    answerQuestion: (request) async {
      final resolved = resolve(request.sessionId);
      if (resolved.imported != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — answer it in its own '
          'terminal',
        );
      }
      final native = resolved.native?.id;
      return ref
          .read(remotePromptsProvider)
          .answerQuestion(
            native == null
                ? request
                : RemoteQuestionAnswerRequest(
                    sessionId: native,
                    toolUseId: request.toolUseId,
                    answers: request.answers,
                    decline: request.decline,
                  ),
          );
    },
    notes: () => remoteNotesSnapshot(ref),
    sessionOptions: (sessionId) => remoteSessionOptions(ref, sessionId),
    configureSession: (sessionId, {model, permission}) =>
        remoteConfigureSession(
          ref,
          sessionId,
          model: model,
          permission: permission,
        ),
    answerMenu: (request) async {
      final resolved = resolve(request.sessionId);
      if (resolved.imported != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — answer it in its own '
          'terminal',
        );
      }
      final native = resolved.native?.id;
      return ref
          .read(remotePromptsProvider)
          .answerMenu(
            native == null
                ? request
                : RemoteMenuAnswerRequest(
                    sessionId: native,
                    menuId: request.menuId,
                    option: request.option,
                  ),
          );
    },
    approvalEvidenceFor: (sessionId) =>
        ref.read(remotePromptsProvider).approvalEvidence(sessionId),
    // Never forwarded: the server records a phone's push registration.
    registerPush: (_, _, _, _) async => throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'push registrations are kept by the Karmashala server',
    ),
    listWorkspace: () => listRemoteWorkspace(ref),
    listProjects: () => listRemoteProjects(ref),
    startSession: (request) => startRemoteSession(ref, request),
    beginAttachment: (deviceId, request) async {
      try {
        return await (await ref.read(
          companionAttachmentStoreProvider.future,
        )).begin(deviceId, request);
      } on AttachmentUploadException catch (failure) {
        throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
      }
    },
    writeAttachmentChunk: (deviceId, uploadId, seq, data) async {
      try {
        await (await ref.read(
          companionAttachmentStoreProvider.future,
        )).write(deviceId, uploadId, seq, data);
      } on AttachmentUploadException catch (failure) {
        throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
      }
    },
    discardAttachment: (deviceId) async {
      await (await ref.read(
        companionAttachmentStoreProvider.future,
      )).discard(deviceId);
    },
    addProject: (name, path) async {
      final trimmedName = name.trim();
      if (trimmedName.isEmpty ||
          trimmedName.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'name and an existing absolute local desktop path are required',
        );
      }
      // Resolve before joining the in-flight map: aliases (case variants on
      // Windows included) then share one operation.
      final canonical = await canonicalRemoteProjectPath(path);
      final key = canonicalPathKey(canonical);
      final future = projectAdds.putIfAbsent(
        key,
        () => addRemoteProject(ref, trimmedName, canonical),
      );
      try {
        return await future;
      } finally {
        if (identical(projectAdds[key], future)) {
          unawaited(projectAdds.remove(key));
        }
      }
    },
    resumeSession: (sessionId) => resumeRemoteSession(ref, sessionId),
  );
});
