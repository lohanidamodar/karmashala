import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/permission_carry.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../environments/domain/environment_path.dart';
import '../../git/application/changes_providers.dart';
import '../../git/domain/file_change.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../settings/domain/permission_mode.dart';
import '../domain/handoff_packet.dart';
import '../domain/session.dart';
import '../domain/session_fork.dart';
import '../domain/session_launch.dart';
import '../domain/session_lineage.dart';
import 'handoff_providers.dart';
import 'session_chat_source.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';

/// One agent this session could be continued in.
///
/// Built for every installation in the session's environment, **including the
/// agent already running it** — "continue this in a fresh Claude session" is a
/// real answer to a full context window, and hiding it would make the menu
/// claim a restriction that does not exist.
class HandoffTarget {
  const HandoffTarget({
    required this.installation,
    required this.descriptor,
    required this.agentName,
    required this.permission,
    required this.isSameAgent,
    this.refusal,
  });

  final AgentInstallation installation;
  final AgentDescriptor? descriptor;
  final String agentName;

  /// What this session's permission mode becomes on the way over.
  final CarriedPermission permission;

  /// Whether this is the agent already running the session.
  final bool isSameAgent;

  /// Why this target cannot receive a handoff, or null when it can.
  final String? refusal;

  bool get canReceive => refusal == null;
}

/// Builds handoff packets and starts the sessions that receive them.
///
/// Everything here ends at [SessionLauncher.launch]. A handed-off session and a
/// forked one are not new kinds of session: same row, same PTY, same permission
/// resolution, same worktree rules — the only additions are the packet in
/// `firstMessage` and the link kind on the row.
class SessionHandoffService {
  SessionHandoffService(this._ref);

  final Ref _ref;

  // --- what can be offered ---------------------------------------------------

  /// The agents [sessionId] could be continued in, in registry order.
  ///
  /// Empty when the session, its repository or its own installation is gone —
  /// the same silence every other action gives for a session that no longer
  /// resolves.
  List<HandoffTarget> targetsFor(String sessionId) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return const [];
    final repo = _ref.read(repositoryDaoProvider).getById(session.repositoryId);
    if (repo == null) return const [];
    final installations = _ref.read(agentInstallationDaoProvider);
    final sourceAgentId = installations
        .getById(session.agentInstallationId)
        ?.agentId;
    final registry = _ref.read(agentRegistryProvider);
    final mode = _ref
        .read(sessionLauncherProvider)
        .effectivePermissionFor(sessionId)
        ?.mode;

    final targets = <HandoffTarget>[];
    for (final installation in installations.getByEnvironment(
      repo.path.environmentId,
    )) {
      final descriptor = registry.byId(installation.agentId);
      final name = registry.displayNameFor(installation.agentId);
      targets.add(
        HandoffTarget(
          installation: installation,
          descriptor: descriptor,
          agentName: name,
          permission: carryPermission(
            mode ?? PermissionMode.ask,
            descriptor,
            targetName: name,
          ),
          isSameAgent: installation.agentId == sourceAgentId,
          refusal: _refusalFor(descriptor, name),
        ),
      );
    }
    return targets;
  }

  /// Why [descriptor] cannot be handed a packet, or null.
  ///
  /// There is exactly one requirement and it is not obvious: the packet is
  /// delivered as the agent's **opening prompt argument**, so an agent that
  /// takes no prompt argument would be launched into the right directory
  /// having been told nothing at all — a blank session wearing a handoff's
  /// name. Typing it into the PTY instead is not a substitute: that races the
  /// agent's own startup, which takes seconds and shows no reliable ready
  /// marker (see `SessionLauncher.sendTo`'s callers).
  String? _refusalFor(AgentDescriptor? descriptor, String name) {
    if (descriptor == null) {
      return 'Chitragupta has no descriptor for this agent, so it cannot be '
          'told anything at launch.';
    }
    if (!descriptor.launch.acceptsPromptArgument) {
      return '$name takes no opening prompt, so the handoff packet could not '
          'be delivered — the new session would start knowing nothing.';
    }
    return null;
  }

  /// What forking [sessionId] would actually do.
  SessionForkPlan forkPlanFor(String sessionId) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      return SessionForkPlan.decide(descriptor: null, agentName: 'this agent');
    }
    final agentId = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final registry = _ref.read(agentRegistryProvider);
    return SessionForkPlan.decide(
      descriptor: agentId == null ? null : registry.byId(agentId),
      agentName: agentId == null
          ? 'this agent'
          : registry.displayNameFor(agentId),
      externalSessionId: session.externalSessionId,
    );
  }

  // --- the packet ------------------------------------------------------------

  /// Assembles the packet [sessionId] would be handed over with.
  ///
  /// Separate from the launch so the user can *read it before it is sent*.
  /// A handoff is a one-way door — the receiving agent's first turn is spent on
  /// whatever this says — and a preview is the only point at which a wrong
  /// recap or a missing instruction costs nothing.
  ///
  /// Every input is gathered best-effort and a failure becomes the null the
  /// packet renders as an admission. Nothing here throws for a git that would
  /// not answer.
  Future<HandoffPacket> buildPacket({
    required String sessionId,
    required String targetAgentName,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool isFork = false,
    HandoffRecapBudget budget = const HandoffRecapBudget(),
  }) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) throw StateError('This session no longer exists.');
    final registry = _ref.read(agentRegistryProvider);
    final agentId = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final sourceName = agentId == null
        ? 'a previous agent'
        : registry.displayNameFor(agentId);

    final directory = sessionWorkingDirectory(_ref, sessionId);
    final recap = await _recapFor(session, agentId, sourceName, budget);
    final changes = directory == null ? null : await _changesIn(directory);
    final repoState = directory == null
        ? null
        : await _ref.read(sessionHandoffStateProvider(sessionId).future);

    return HandoffPacket(
      sourceAgentName: sourceName,
      targetAgentName: targetAgentName,
      sourceTitle: session.title,
      sourceSessionId: session.externalSessionId ?? session.id,
      instruction: instruction,
      workingDirectory: directory?.path,
      branch: repoState?.branch,
      commitsAhead: repoState?.commitsAhead,
      baseBranch: repoState?.defaultBranch == null
          ? null
          : 'origin/${repoState!.defaultBranch}',
      changes: changes,
      recap: recap.turns,
      omittedTurns: recap.omitted,
      unresolvedTasks: [
        for (final task in unresolvedTasks)
          if (task.trim().isNotEmpty) task.trim(),
      ],
      isFork: isFork,
    );
  }

  /// The tail of the conversation, read from the **agent's own transcript** —
  /// the same file the chat view renders (Loop 41), not a second copy.
  ///
  /// `tool` records are dropped. A recap made of tool calls and their output is
  /// mostly file contents the receiving agent can read for itself, and it
  /// exhausts the budget several turns before reaching anything either party
  /// said. What is kept is the conversation; what was *done* is in the working
  /// tree, which the packet lists separately.
  Future<({List<HandoffTurn> turns, int omitted})> _recapFor(
    Session session,
    String? agentId,
    String sourceName,
    HandoffRecapBudget budget,
  ) async {
    final externalId = session.externalSessionId;
    if (agentId == null || externalId == null || externalId.isEmpty) {
      return (turns: const <HandoffTurn>[], omitted: 0);
    }
    try {
      final path = await _ref
          .read(sessionTranscriptLocatorProvider)
          .locate(agentId: agentId, externalSessionId: externalId);
      if (path == null) return (turns: const <HandoffTurn>[], omitted: 0);
      final messages = await readCliTranscript(path, agentId);
      final turns = <HandoffTurn>[
        for (final message in messages)
          if (message.role == 'user' || message.role == 'agent')
            if (message.text.trim().isNotEmpty)
              HandoffTurn(
                // Named, never "assistant": the reader is itself an assistant,
                // and an unqualified label is the exact confusion the packet
                // exists to prevent.
                speaker: message.role == 'user' ? 'The user' : sourceName,
                text: message.text.trim(),
              ),
      ];
      return trimRecap(turns, budget);
    } catch (_) {
      // An unreadable transcript is the same answer as an empty one, and the
      // packet says which by carrying the count it could not quote.
      return (turns: const <HandoffTurn>[], omitted: 0);
    }
  }

  Future<List<HandoffChange>?> _changesIn(EnvironmentPath directory) async {
    try {
      final changes = await _ref
          .read(changesServiceProvider)
          .changes(directory);
      return [
        for (final change in changes)
          HandoffChange(
            path: change.path,
            state: _stateWords(change),
            originalPath: change.originalPath,
          ),
      ];
    } catch (_) {
      // Null, not empty: "git could not be asked" and "the tree is clean" are
      // opposite answers, and the packet renders them differently.
      return null;
    }
  }

  String _stateWords(FileChange change) {
    final kind = switch (change.type) {
      FileChangeType.added => 'added',
      FileChangeType.modified => 'modified',
      FileChangeType.deleted => 'deleted',
      FileChangeType.renamed => 'renamed',
      FileChangeType.copied => 'copied',
      FileChangeType.untracked => 'untracked',
      // `unknown` is git's own shrug at a status code we do not model, and it
      // is reported as that rather than folded into "modified" — a wrong verb
      // about a file the next agent is about to edit is worse than an honest
      // one.
      FileChangeType.unknown => 'changed (unrecognised git status)',
    };
    if (change.staged && change.unstaged) return '$kind, staged and unstaged';
    if (change.staged) return '$kind, staged';
    return kind;
  }

  // --- starting the new session ----------------------------------------------

  /// Continues [sessionId] in another agent.
  ///
  /// The old session is **not touched**: not ended, not detached, not marked.
  /// Since Loop 38 a session's lifetime is independent of any view of it, so
  /// leaving it exactly as it was is both possible and correct — the user
  /// decides whether to end it, and until they do the handoff is reversible by
  /// simply going back to it.
  Future<SessionLaunchResult> handoffTo({
    required String sessionId,
    required String targetInstallationId,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
  }) => _continue(
    sessionId: sessionId,
    targetInstallationId: targetInstallationId,
    instruction: instruction,
    unresolvedTasks: unresolvedTasks,
    intoNewWorktree: intoNewWorktree,
    link: SessionLink.handoff,
  );

  /// Branches [sessionId] into a new session that shares its history.
  ///
  /// Runs in the **same agent** — a fork is a branch of one conversation, not a
  /// change of provider — and takes the native route when [forkPlanFor] says
  /// the CLI can do it, falling back to a packet when it cannot. The plan's
  /// explanation is what the UI must have shown first.
  Future<SessionLaunchResult> forkSession({
    required String sessionId,
    String instruction = '',
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
  }) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) throw StateError('This session no longer exists.');
    final plan = forkPlanFor(sessionId);
    if (plan.isRefused) throw StateError(plan.explanation);

    if (!plan.isNative) {
      return _continue(
        sessionId: sessionId,
        targetInstallationId: session.agentInstallationId,
        instruction: instruction.trim().isEmpty
            ? 'Continue from here.'
            : instruction,
        unresolvedTasks: unresolvedTasks,
        intoNewWorktree: intoNewWorktree,
        link: SessionLink.fork,
        isFork: true,
      );
    }

    final context = _contextFor(session, session.agentInstallationId);
    return _ref
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: context.repository,
            installation: context.installation,
            title: _forkTitle(sessionId, session.title),
            // A create, not a continuation: the CLI is starting a new
            // conversation that happens to be seeded from an old one, and it
            // will mint its own id for it.
            purpose: SessionPurpose.newSession,
            forkExternalSessionId: session.externalSessionId,
            firstMessage: instruction.trim().isEmpty ? null : instruction,
            parentSessionId: sessionId,
            parentLink: SessionLink.fork,
            useWorktree: intoNewWorktree,
            existingWorktree: intoNewWorktree ? null : session.worktree,
            // The session's own mode, carried as-is: the fork runs the same
            // agent, so there is nothing to translate.
            permissionOverride: _ref
                .read(sessionLauncherProvider)
                .effectivePermissionFor(sessionId)
                ?.mode,
          ),
        );
  }

  Future<SessionLaunchResult> _continue({
    required String sessionId,
    required String targetInstallationId,
    required String instruction,
    required List<String> unresolvedTasks,
    required bool intoNewWorktree,
    required SessionLink link,
    bool isFork = false,
  }) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) throw StateError('This session no longer exists.');
    if (instruction.trim().isEmpty) {
      throw StateError(
        'Say what the next agent should do. The packet carries the '
        'conversation; the instruction is the part only you can write.',
      );
    }
    final context = _contextFor(session, targetInstallationId);
    final registry = _ref.read(agentRegistryProvider);
    final targetName = registry.displayNameFor(context.installation.agentId);
    final descriptor = registry.byId(context.installation.agentId);

    final refusal = _refusalFor(descriptor, targetName);
    if (refusal != null) throw StateError(refusal);

    final packet = await buildPacket(
      sessionId: sessionId,
      targetAgentName: targetName,
      instruction: instruction,
      unresolvedTasks: unresolvedTasks,
      isFork: isFork,
    );

    // The mode is resolved *here*, once, and passed as an override, so the
    // command line and the sentence the user was shown before launching come
    // from the same call. Reading the target's default instead would silently
    // ignore the session's own choice, which Loop 49 exists to have stopped.
    final carried = carryPermission(
      _ref
              .read(sessionLauncherProvider)
              .effectivePermissionFor(sessionId)
              ?.mode ??
          PermissionMode.ask,
      descriptor,
      targetName: targetName,
    );

    return _ref
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: context.repository,
            installation: context.installation,
            title: isFork
                ? _forkTitle(sessionId, session.title)
                : '${session.title} · $targetName',
            purpose: SessionPurpose.newSession,
            firstMessage: packet.render(),
            parentSessionId: sessionId,
            parentLink: link,
            useWorktree: intoNewWorktree,
            existingWorktree: intoNewWorktree ? null : session.worktree,
            permissionOverride: carried.mode,
          ),
        );
  }

  ({Repository repository, AgentInstallation installation}) _contextFor(
    Session session,
    String installationId,
  ) {
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    if (repository == null) {
      throw StateError('This session\'s repository is no longer available.');
    }
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(installationId);
    if (installation == null) {
      throw StateError(
        'That agent is not installed any more. Run "Discover agents" in '
        'Settings.',
      );
    }
    return (repository: repository, installation: installation);
  }

  /// `Fix the parser` → `Fix the parser (fork)`, or `(fork 2)` for the second
  /// branch of the same conversation, counted off the parent's existing forks
  /// so two branches are told apart in a list without the user naming them.
  String _forkTitle(String parentId, String title) {
    final existing = _ref
        .read(sessionDaoProvider)
        .childrenOf(parentId)
        .where((child) => child.parentLink == SessionLink.fork)
        .length;
    return existing == 0 ? '$title (fork)' : '$title (fork ${existing + 1})';
  }
}

final sessionHandoffServiceProvider = Provider<SessionHandoffService>(
  (ref) => SessionHandoffService(ref),
);

/// Everything the composer needs to decide whether — and how — a session can be
/// continued elsewhere.
///
/// A read model rather than two calls from the widget, because both answers
/// come from the same three rows (the session, its repository, the
/// installations in its environment) and a widget that asked twice would read
/// them twice on every rebuild.
class SessionContinuation {
  const SessionContinuation({required this.targets, required this.plan});

  final List<HandoffTarget> targets;
  final SessionForkPlan plan;

  /// Whether there is anywhere at all for this session to go.
  bool get isPossible =>
      targets.any((target) => target.canReceive) || !plan.isRefused;
}

/// The continuation options for one session.
///
/// A provider rather than a service call in `build` — the row is a widget, and
/// this is the seam a widget test overrides instead of standing up a database
/// to answer a yes/no question.
final sessionContinuationProvider = Provider.autoDispose
    .family<SessionContinuation, String>((ref, sessionId) {
      // The session's own row and the installed agents both move under this;
      // the revision is what every other session mutation already bumps.
      ref.watch(sessionsRevisionProvider);
      final service = ref.watch(sessionHandoffServiceProvider);
      return SessionContinuation(
        targets: service.targetsFor(sessionId),
        plan: service.forkPlanFor(sessionId),
      );
    });
