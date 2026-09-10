import '../../../core/database/sqlite_row_reader.dart';
import 'package:riverpod/riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/domain/session.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_providers.dart';

/// How to continue [session] when no conversation id is recorded, or `null` —
/// not a refusal, but "does not apply", so the caller keeps what it says.
typedef AntigravityResumePlanner =
    Future<AntigravityResumePlan?> Function(Session session);

/// The one place a session with no CLI id is asked whether it can be continued
/// anyway: `agy` records each directory's last conversation, so it often can.
final antigravityResumePlannerProvider = Provider<AntigravityResumePlanner>((
  ref,
) {
  return (session) async {
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final descriptor = agentId == null
        ? null
        : ref.read(agentRegistryProvider).byId(agentId);
    // Asked of the descriptor, never of an agent's name: this route needs a
    // store whose `{directory: conversation}` map can be read.
    if (descriptor == null ||
        descriptor.store?.format != AgentStoreFormat.antigravityStore) {
      return null;
    }

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
        // Only the environment the session runs in: `agy` writes its store
        // beside the process, and matching them opens a stranger's chat.
        if (store.environmentId != directory.environmentId) continue;
        final home = store.homesByAgentId[descriptor.id];
        if (home == null) continue;
        latest = conversationForDirectory(
          await const AntigravityStoreReader(
            readRows: readSqliteRows,
          ).readLastConversations(home),
          directory.path,
        );
        break;
      }
    } on Object {
      // A store we could not read names no conversation, which
      // `planAntigravityResume` turns into a refusal in words.
      latest = null;
    }

    return planAntigravityResume(
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
String? conversationIn(AntigravityResumePlan plan) => switch (plan) {
  AntigravityResumeById(:final conversationId) => conversationId,
  AntigravityContinueLatest(:final conversationId) => conversationId,
  AntigravityResumeRefused() => null,
};

/// What to tell the user before continuing a conversation the app was never
/// given the id of. It **names its target**, which is why it is not a guess.
String antigravityContinueNotice(String conversationId, String directory) =>
    'Antigravity never told this session its conversation id. Continuing '
    '$conversationId, the conversation its store records for $directory.';
