/// What a file sent to one session may be, and what happens when a prompt names
/// it — one rule read on the row, at `attachment.begin`, and at `prompt.send`.
library;

import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import 'package:agent_cli/process.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_providers.dart';
import '../../notes/application/composer_draft.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';
import 'remote_providers.dart';

/// What a file sent to one session may be, answered before anybody picks a 4 MB
/// photo. An agent on another machine is refused: a path here is nothing there.
RemoteAttachmentSupport remoteAttachmentSupportFor(
  Ref ref,
  String? agentId,
  String? environmentId,
) {
  final support = agentAttachmentSupport(
    agentId == null ? null : AgentRegistry.builtIn.byId(agentId),
  );
  if (support.refusal != null) return support;
  final environment = environmentId == null
      ? null
      : ref.read(executionEnvironmentDaoProvider).getById(environmentId);
  if (environment == null) {
    return const RemoteAttachmentSupport.refused(
      'This desktop cannot tell where that agent runs.',
    );
  }
  if (!isLocalHost(environment.kind) &&
      environment.kind != EnvironmentKind.wsl) {
    // The one case that is not about the CLI at all: the agent has its own
    // filesystem, and a path this desktop writes is not a path it can open.
    return RemoteAttachmentSupport.refused(
      '${environment.name} runs on another machine — a file written here is '
      'not a file it can open.',
    );
  }
  return support;
}

/// The path an agent in [environmentId] would use for a file this host wrote.
/// Getting it wrong hands it a path that silently does not exist.
String _agentVisiblePath(Ref ref, String hostPath, String? environmentId) {
  final environments = ref.read(executionEnvironmentDaoProvider);
  final target = environmentId == null
      ? null
      : environments.getById(environmentId);
  if (target == null || isLocalHost(target.kind)) return hostPath;
  ExecutionEnvironment? here;
  for (final candidate in environments.getAll()) {
    if (candidate.kind == EnvironmentKind.windowsNative) {
      here = candidate;
      break;
    }
  }
  if (here == null) return hostPath;
  return ref
      .read(pathTranslatorProvider)
      .translate(
        EnvironmentPath(environmentId: here.id, path: hostPath),
        from: here,
        to: target,
      )
      .path;
}

/// Commits the upload into the session's message box — **offered, not sent**:
/// the path lands where the person at the machine reads it first.
Future<void> offerRemoteAttachment(
  Ref ref,
  String sessionId,
  String text,
  RemoteAttachmentRef attachment,
) async {
  final store = await ref.read(companionAttachmentStoreProvider.future);
  final File committed;
  try {
    committed = await store.commit(attachment.deviceId, attachment.uploadId);
  } on AttachmentUploadException catch (failure) {
    throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
  }
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  final environmentId = session == null
      ? null
      : ref
            .read(agentInstallationDaoProvider)
            .getById(session.agentInstallationId)
            ?.executable
            .environmentId;
  // The path as the *agent* would spell it. A Windows path handed to a WSL
  // agent names nothing, and constraint 8 forbids working that out implicitly.
  final String visible;
  try {
    visible = _agentVisiblePath(ref, committed.path, environmentId);
  } on PathTranslationException {
    // The translator's own message quotes the path, and a refusal must not: it
    // would put this machine's directory layout on the wire.
    throw const RemoteApiRefusal(
      ErrorCode.internal,
      'this desktop cannot write a file where that agent could open it',
    );
  }
  // The desktop composer's own wording for the same act, so an agent cannot
  // tell which door the file came through — see `message_composer.dart`.
  final body = attachmentPromptBody(text, visible);
  ref.read(composerDraftProvider.notifier).queue(sessionId, body);
  ref.read(selectedSessionIdProvider.notifier).select(sessionId);
  final paneId = session?.paneId;
  if (paneId != null) {
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .revealConversationForPane(paneId);
  }
}
