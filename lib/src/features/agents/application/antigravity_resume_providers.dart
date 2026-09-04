import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/domain/session.dart';
import '../data/antigravity_session_resume.dart';
import '../data/antigravity_store_reader.dart';
import '../domain/agent_descriptor.dart';
import 'agent_providers.dart';

/// How to continue [session] when the app has no conversation id recorded for
/// it, or `null` when this agent has nothing of the kind to offer.
///
/// `null` is not a refusal — it means the question does not apply, and the
/// caller keeps whatever it already says. Only an agent that both keeps a
/// readable store and declares a scoped "latest conversation here" can be
/// answered at all.
typedef AntigravityResumePlanner =
    Future<AntigravityResumePlan?> Function(Session session);

/// The one place a session with no CLI id is asked whether it can be continued
/// anyway.
///
/// Both surfaces that used to say *"No resumable CLI session id could be
/// found"* now come through here — the Explorer card and "open in system
/// terminal". That sentence was one message for several different situations,
/// and for Antigravity it was wrong in the most annoying way: `agy` records the
/// conversation each directory last used, in
/// `cache/last_conversations.json` — the very file it resolves `--continue`
/// through — so the app could read the conversation it was refusing to open.
///
/// The judgement is `planAntigravityResume`'s and stays there. This provider is
/// the part that needs the workspace: which agent the session runs, which
/// directory it ran in, which environment's store to read, and which
/// conversations other rows already hold.
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
    // store whose `{directory: conversation}` map can be read, and that is what
    // the format says. Every other agent falls through to its caller's own
    // words, which for Claude Code and Codex is the honest answer — neither has
    // a directory-scoped "latest" the app can name before opening it.
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
        // Only the environment the session runs in. `agy` writes its store
        // beside the process, so a Windows install's entries say nothing about
        // a directory inside WSL — and matching one to the other is how a
        // resume opens a stranger's conversation.
        if (store.environmentId != directory.environmentId) continue;
        final home = store.homesByAgentId[descriptor.id];
        if (home == null) continue;
        latest = conversationForDirectory(
          await const AntigravityStoreReader().readLastConversations(home),
          directory.path,
        );
        break;
      }
    } on Object {
      // A store we could not read names no conversation, which
      // `planAntigravityResume` already turns into a refusal in words.
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
/// given the id of.
///
/// It **names its target**. A fallback that can say which conversation it is
/// about to open is not a guess, and saying so is the difference between this
/// and Codex's `--last` picker, which `built_in_agents.dart` declines for being
/// one.
String antigravityContinueNotice(String conversationId, String directory) =>
    'Antigravity never told this session its conversation id. Continuing '
    '$conversationId, the conversation its store records for $directory.';
