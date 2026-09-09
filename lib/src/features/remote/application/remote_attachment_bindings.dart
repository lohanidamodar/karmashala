/// What a file sent to one session may be, where the agent would see it, and
/// what happens to it when a prompt names it.
///
/// One family because it is one rule read at three moments: on the row before
/// anybody picks a photo, at `attachment.begin` before a byte crosses, and at
/// `prompt.send` when the bytes are already on this disk.
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
import '../data/companion_attachment_store.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';
import 'remote_providers.dart';

/// What a file sent to one session may be — the answer the phone is shown on
/// the row, **before** it lets anybody pick a 4 MB photo.
///
/// Three things have to be true at once, and each of them is per session:
///
/// 1. the agent behind it reads a path written into its prompt
///    ([AgentAttachmentSupport], declared per agent with its evidence);
/// 2. that agent runs somewhere this desktop can write a file it will see —
///    which rules SSH out entirely, because the agent is on another machine
///    and a path on this disk means nothing there;
/// 3. there is a live session to type into at all.
///
/// Costs nothing to compute: three DAO reads the snapshot already makes, and
/// no process, no probe and no filesystem call.
RemoteAttachmentSupport remoteAttachmentSupportFor(
  Ref ref,
  String? agentId,
  String? environmentId,
) {
  final descriptor = agentId == null
      ? null
      : AgentRegistry.builtIn.byId(agentId);
  final support = descriptor?.attachments;
  if (support == null || !support.isSupported) {
    return RemoteAttachmentSupport.refused(
      support?.refusal.isNotEmpty ?? false
          ? support!.refusal
          : 'This agent is not known to open a file named in a prompt.',
    );
  }
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
  return RemoteAttachmentSupport(
    mediaTypes: [
      for (final type in support.mediaTypes)
        // Only what this desktop can also *write*: a type the agent would read
        // but the store has no extension for is a path nobody can open.
        if (kAttachmentExtensions.containsKey(type)) type,
    ],
    maxBytes: kMaxAttachmentBytes,
  );
}

/// The path an agent in [environmentId] would use for a file this host wrote.
///
/// Explicit, through [PathTranslator], because constraint 8 forbids the
/// implicit kind — and because getting it wrong hands an agent a path that
/// silently does not exist rather than an error anybody can read.
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

/// Commits the upload and leaves it in the session's own message box.
///
/// **Offered, not sent** — the rule `ComposerDrafts` was written for, and it
/// matters more here than it does for a note: this is a phone telling an agent
/// on somebody's desktop to open a file that has just been written onto that
/// desktop's disk. The path lands where the person sitting at the machine reads
/// it before the agent does, and they press Enter or they do not.
///
/// The conversation is revealed for the same reason `notes_view` reveals it:
/// the composer *is* the conversation, so a group showing its terminal has no
/// box for this to land in.
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
    // The translator's own message quotes the path, and a refusal must not:
    // it would put this machine's directory layout — and the name the user
    // picked — on the wire. See [RemoteApiRefusal.message].
    throw const RemoteApiRefusal(
      ErrorCode.internal,
      'this desktop cannot write a file where that agent could open it',
    );
  }
  // The desktop composer's own wording for the same act, so an agent cannot
  // tell which door the file came through — see `message_composer.dart`.
  final body = text.isEmpty
      ? 'Attached image(s):\n$visible'
      : '$text\n\nAttached image(s):\n$visible';
  ref.read(composerDraftProvider.notifier).queue(sessionId, body);
  ref.read(selectedSessionIdProvider.notifier).select(sessionId);
  final paneId = session?.paneId;
  if (paneId != null) {
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .revealConversationForPane(paneId);
  }
}
