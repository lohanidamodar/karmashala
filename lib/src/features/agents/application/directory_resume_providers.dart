import '../../../core/database/sqlite_row_reader.dart';
import 'package:riverpod/riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_providers.dart';

/// How to continue [session] when no conversation id is recorded, or `null` —
/// not a refusal, but "does not apply", so the caller keeps what it says.
typedef DirectoryResumePlanner =
    Future<DirectoryResumePlan?> Function(Session session);

/// The one place a session with no CLI id is asked whether it can be continued
/// anyway: an agent whose store records each directory's last conversation
/// (`AgentDirectoryConversations`) often can.
final directoryResumePlannerProvider = Provider<DirectoryResumePlanner>((ref) {
  return (session) async {
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final adapter = agentId == null
        ? null
        : ref.read(agentRegistryProvider).adapterFor(agentId);
    // Asked of the adapter, never of an agent's name: this route needs a store
    // whose `{directory: conversation}` map can be read.
    final conversations = adapter?.directoryConversations;
    if (adapter == null || conversations == null) return null;
    final descriptor = adapter.descriptor;

    // The same order of decreasing certainty `sessionWorkingDirectoryOf` uses.
    final directory =
        session.workingDirectory ??
        session.worktree ??
        ref.read(repositoryDaoProvider).getById(session.repositoryId)?.path;
    if (directory == null) return null;

    String? latest;
    try {
      final environments = ref.read(executionEnvironmentDaoProvider).getAll();
      final stores = await ref
          .read(cliStoreLocatorProvider)
          .locate(environments);
      for (final store in stores) {
        // Only the environment the session runs in: the CLI writes its store
        // beside the process, and matching them opens a stranger's chat.
        if (store.environmentId != directory.environmentId) continue;
        final home = store.homeFor(descriptor.id);
        if (home == null) continue;
        latest = conversations.conversationFor(
          await conversations.lastConversations(home, readRows: readSqliteRows),
          directory.path,
        );
        break;
      }
    } on Object {
      // A store we could not read names no conversation, which `planResume`
      // turns into a refusal in words.
      latest = null;
    }

    return conversations.planResume(
      descriptor: descriptor,
      workingDirectory: directory.path,
      conversationId: session.externalSessionId,
      lastConversationForDirectory: latest,
      conversationIdsHeldByOtherSessions: ref
          .read(sessionDaoProvider)
          .heldExternalSessionIds(excludingSessionId: session.id),
    );
  };
});

/// The conversation [plan] would open, or `null` for a refusal.
String? conversationIn(DirectoryResumePlan plan) => switch (plan) {
  DirectoryResumeById(:final conversationId) => conversationId,
  DirectoryContinueLatest(:final conversationId) => conversationId,
  DirectoryResumeRefused() => null,
};

/// What to tell the user before continuing [conversationId], which [session]
/// was never given the id of. It **names its target**, which is why it is not
/// a guess — worded by the session's agent.
String continueLatestNotice(
  Ref ref,
  Session session,
  String conversationId,
  String directory,
) {
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  final conversations = agentId == null
      ? null
      : ref
            .read(agentRegistryProvider)
            .adapterFor(agentId)
            ?.directoryConversations;
  return conversations?.continueNotice(conversationId, directory) ??
      'Continuing $conversationId, the conversation the store records for '
          '$directory.';
}
