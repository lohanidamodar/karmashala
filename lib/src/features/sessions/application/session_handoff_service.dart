import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'delivery_providers.dart';
import 'session_actions.dart';
import 'session_chat_source.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_wait.dart';
import 'session_working_directory.dart';

/// One agent this session could be continued in — including the one already
/// running it: a fresh session is a real answer to a full context window.
class HandoffTarget {
  const HandoffTarget({
    required this.installation,
    required this.descriptor,
    required this.agentName,
    required this.permission,
    required this.isSameAgent,
    this.followsDefault = false,
    this.refusal,
  });

  final AgentInstallation installation;
  final AgentDescriptor? descriptor;
  final String agentName;

  /// What this session's permission mode becomes on the way over.
  final CarriedPermission permission;

  /// Whether this is the agent already running the session.
  final bool isSameAgent;

  /// Whether [permission] is the Settings default rather than a choice — the
  /// dialog has to say so, because a default moves when the setting does.
  final bool followsDefault;

  /// Why this target cannot receive a handoff, or null when it can.
  final String? refusal;

  bool get canReceive => refusal == null;
}

/// Builds handoff packets and starts the sessions that receive them. A handoff
/// is not a new kind of session — a packet in `firstMessage` and a link.
class SessionHandoffService {
  SessionHandoffService(this._ref);

  final Ref _ref;

  /// Every continuation says what it handed over, and how big: Claude Code
  /// collapses any paste over 800 characters into `[Pasted text #N]`.
  static final _log = AppLogger.named('sessions.handoff');

  // --- what can be offered ---------------------------------------------------

  /// The agents [sessionId] could be continued in, in registry order. Empty
  /// when the session, its repository or its own installation is gone.
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

    final targets = <HandoffTarget>[];
    for (final installation in installations.getByEnvironment(
      repo.path.environmentId,
    )) {
      final descriptor = registry.byId(installation.agentId);
      final name = registry.displayNameFor(installation.agentId);
      // Per target, not once for the list: a source that chose nothing is
      // measured against the mode *that* agent will start under.
      final starting = _startingMode(sessionId, installation.agentId);
      targets.add(
        HandoffTarget(
          installation: installation,
          descriptor: descriptor,
          agentName: name,
          permission: carryPermission(
            starting.risk,
            descriptor,
            targetName: name,
          ),
          isSameAgent: installation.agentId == sourceAgentId,
          followsDefault: !starting.chosen,
          refusal: _refusalFor(descriptor, name),
        ),
      );
    }
    return targets;
  }

  /// Why [descriptor] cannot be handed a packet, or null: the packet is the
  /// agent's **opening prompt argument**, and typing it races the CLI startup.
  String? _refusalFor(AgentDescriptor? descriptor, String name) {
    if (descriptor == null) {
      return 'Karmashala has no descriptor for this agent, so it cannot be '
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

  /// Assembles the packet [sessionId] would be handed over with, apart from the
  /// launch so a user can read it first. Best-effort; nothing here throws.
  Future<HandoffPacket> buildPacket({
    required String sessionId,
    required String targetAgentName,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool isFork = false,
    HandoffSourceBrief? sourceBrief,
    HandoffRecapBudget budget = const HandoffRecapBudget(),
    HandoffDecisionBudget decisionBudget = const HandoffDecisionBudget(),
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
    // Charged *before* the recap: the quoted tail is still in the transcript
    // the new agent can read, while a dropped decision is written nowhere else.
    final recorded = _decisionsFor(sessionId, decisionBudget);
    final recap = await _recapFor(
      session,
      agentId,
      sourceName,
      budget.reducedBy(recorded.cost),
    );
    final changes = directory == null ? null : await _changesIn(directory);
    final delivery = directory == null
        ? null
        : await _ref.read(sessionDeliveryProvider(sessionId).future);

    return HandoffPacket(
      sourceAgentName: sourceName,
      targetAgentName: targetAgentName,
      sourceTitle: session.title,
      sourceSessionId: session.externalSessionId ?? session.id,
      instruction: instruction,
      workingDirectory: directory?.path,
      branch: delivery?.branch,
      commitsAhead: delivery?.aheadOfBase,
      baseBranch: delivery?.baseBranch,
      changes: changes,
      recap: recap.turns,
      omittedTurns: recap.omitted,
      decisions: recorded.decisions,
      omittedDecisions: recorded.omitted,
      deadEnds: recorded.deadEnds,
      sourceBrief: sourceBrief,
      unresolvedTasks: [
        for (final task in unresolvedTasks)
          if (task.trim().isNotEmpty) task.trim(),
      ],
      isFork: isFork,
    );
  }

  /// What this session decided, as recorded — no deduplication, and no folding
  /// of a reversal. **Null** is "could not be read", not an empty record.
  ({
    List<HandoffDecision>? decisions,
    List<HandoffClaim>? deadEnds,
    int omitted,
    int cost,
  })
  _decisionsFor(
    String sessionId,
    HandoffDecisionBudget budget,
  ) {
    try {
      final rows = _ref.read(decisionRecordDaoProvider).forSession(sessionId);
      final trimmed = trimDecisions([
        for (final row in rows)
          HandoffDecision(
            kind: row.kind.label,
            summary: row.summary,
            detail: row.detail,
            decidedBy: row.decidedBy,
            origin: row.origin.label,
            originId: row.originId,
            recordedAt: row.recordedAt,
          ),
      ], budget);
      // Partitioned *after* the trim, so the budget is charged once and the
      // split cannot change what survives it. The label comes from the enum.
      final ruledOut = DecisionKind.approachRejected.label;
      return (
        decisions: [
          for (final decision in trimmed.decisions)
            if (decision.kind != ruledOut) decision,
        ],
        deadEnds: [
          for (final decision in trimmed.decisions)
            if (decision.kind == ruledOut) _deadEnd(decision),
        ],
        omitted: trimmed.omitted,
        cost: trimmed.cost,
      );
    } catch (_) {
      return (decisions: null, deadEnds: null, omitted: 0, cost: 0);
    }
  }

  /// A rejected approach as the claim it is — or **"not checked yet"**, which
  /// the claim itself renders rather than dropping the qualifier.
  static HandoffClaim _deadEnd(HandoffDecision decision) {
    final detail = decision.detail?.trim();
    final origin = decision.origin;
    final backing = <String>[
      if (detail != null && detail.isNotEmpty) detail,
      if (origin != null)
        decision.originId == null
            ? 'recorded from $origin'
            : 'recorded from $origin `${decision.originId}`',
    ];
    return HandoffClaim(
      statement: decision.summary,
      evidence: backing.isEmpty ? null : backing.join(' — '),
      attributedTo: decision.decidedBy,
    );
  }

  /// The tail of the conversation, from the **agent's own transcript**. `tool`
  /// records are dropped: they exhaust the budget before anyone's words.
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
                // Named, never "assistant": the reader is itself an assistant.
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
      // Named, because it is the one state that is not the user's own
      // edit: a merge stopped here and both sides are still in the index.
      FileChangeType.conflicted =>
        'conflicted (${(change.conflict ?? MergeConflict.unrecorded).words})',
      // `unknown` is git's own shrug: a wrong verb about a file the next agent
      // is about to edit is worse than an honest one.
      FileChangeType.unknown => 'changed (unrecognised git status)',
    };
    // A conflict is never described as staged: both sides sit in the index
    // because git put them there, and "staged" would read as work the user did.
    if (change.type == FileChangeType.conflicted) return kind;
    if (change.staged && change.unstaged) return '$kind, staged and unstaged';
    if (change.staged) return '$kind, staged';
    return kind;
  }

  /// Asks [sessionId] to write its own handoff summary and waits for it —
  /// offered, never automatic, and every failure is a printable "not written".
  Future<HandoffSourceBrief> requestSourceBrief({
    required String sessionId,
    num? timeoutSeconds,
  }) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) throw StateError('This session no longer exists.');
    final agentId = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;

    // Before the send: a message into a session stopped for a person waits
    // behind that prompt, so this would spend its bound learning nothing.
    if (_ref.read(sessionWaitProvider).blockedOn(sessionId) case final block?) {
      return HandoffSourceBrief.notWritten(
        'it is stopped waiting for a person (${block.kind}), so nothing was '
        'sent — a request would have sat behind that prompt. Answer it and '
        'ask again, or hand off without a brief.',
      );
    }

    final before = (await _agentTurnsIn(session, agentId)).length;
    try {
      await _ref
          .read(sessionActionsProvider)
          .continueSession(sessionId, kSourceBriefRequest);
    } on Object catch (error) {
      return HandoffSourceBrief.notWritten(
        'the request could not be delivered to it ($error).',
      );
    }

    final outcome = await _ref
        .read(sessionWaitProvider)
        .wait(
          sessionId,
          bound: SessionWaitService.boundFor(timeoutSeconds),
          // The fact a caller has to have: the request went in, so asking
          // again would ask twice.
          inputSent: true,
        );

    final after = await _agentTurnsIn(session, agentId);
    // Counted against what was there before the request: the newest turn in an
    // unchanged transcript is something the agent said earlier.
    if (after.length <= before) {
      return HandoffSourceBrief.notWritten(
        switch (outcome.state) {
          SessionWaitState.timeout =>
            'it had not answered when this stopped waiting. The request was '
                'delivered and may still be answered in that session — the '
                'brief is simply not in this packet.',
          SessionWaitState.blocked =>
            'it stopped for a person before answering. Whatever it is asking '
                'is in that session.',
          SessionWaitState.ended =>
            'its pane is gone; nothing is running there to answer.',
          _ =>
            'it settled without saying anything (${outcome.state.name}), so '
                'there is nothing of its own to quote.',
        },
      );
    }
    return HandoffSourceBrief.written(after.last);
  }

  /// Everything the source agent has said, oldest first. Empty when unreadable
  /// — the same answer as nothing said, and the caller compares two readings.
  Future<List<String>> _agentTurnsIn(Session session, String? agentId) async {
    final externalId = session.externalSessionId;
    if (agentId == null || externalId == null || externalId.isEmpty) {
      return const [];
    }
    try {
      final path = await _ref
          .read(sessionTranscriptLocatorProvider)
          .locate(agentId: agentId, externalSessionId: externalId);
      if (path == null) return const [];
      return [
        for (final message in await readCliTranscript(path, agentId))
          if (message.role == 'agent' && message.text.trim().isNotEmpty)
            message.text.trim(),
      ];
    } on Object {
      return const [];
    }
  }

  // --- starting the new session ----------------------------------------------

  /// Continues [sessionId] in another agent, leaving the old session untouched,
  /// so the handoff stays reversible until the user ends it themselves.
  Future<SessionLaunchResult> handoffTo({
    required String sessionId,
    required String targetInstallationId,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    PermissionSelection? permissionMode,
    HandoffSourceBrief? sourceBrief,
  }) => _continue(
    sessionId: sessionId,
    targetInstallationId: targetInstallationId,
    instruction: instruction,
    unresolvedTasks: unresolvedTasks,
    intoNewWorktree: intoNewWorktree,
    link: SessionLink.handoff,
    permissionMode: permissionMode,
    sourceBrief: sourceBrief,
  );

  /// Branches [sessionId] into a session sharing its history, in the **same
  /// agent** — native where [forkPlanFor] says the CLI can, a packet otherwise.
  Future<SessionLaunchResult> forkSession({
    required String sessionId,
    String instruction = '',
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    PermissionSelection? permissionMode,
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
        permissionMode: permissionMode,
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
            // A create, not a continuation: the CLI starts a new conversation
            // seeded from an old one and mints its own id for it.
            purpose: SessionPurpose.newSession,
            forkExternalSessionId: session.externalSessionId,
            firstMessage: instruction.trim().isEmpty ? null : instruction,
            parentSessionId: sessionId,
            parentLink: SessionLink.fork,
            useWorktree: intoNewWorktree,
            existingWorktree: intoNewWorktree ? null : session.worktree,
            // The work is where it is: a session with no worktree may still run
            // in a subdirectory, which `existingWorktree` cannot say alone.
            workingDirectory: intoNewWorktree ? null : session.workingDirectory,
            // The session's own mode unless the user picked another — resolved,
            // not passed through, so "this agent can express it" is checked.
            permissionOverride: _resolvePermission(
              sessionId: sessionId,
              descriptor: context.descriptor,
              targetAgentId: context.installation.agentId,
              targetName: context.agentName,
              chosen: permissionMode,
            ).override,
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
    PermissionSelection? permissionMode,
    HandoffSourceBrief? sourceBrief,
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
    final targetName = context.agentName;
    final descriptor = context.descriptor;

    final refusal = _refusalFor(descriptor, targetName);
    if (refusal != null) throw StateError(refusal);

    final packet = await buildPacket(
      sessionId: sessionId,
      targetAgentName: targetName,
      instruction: instruction,
      unresolvedTasks: unresolvedTasks,
      isFork: isFork,
      sourceBrief: sourceBrief,
    );

    final carried = _resolvePermission(
      sessionId: sessionId,
      descriptor: descriptor,
      targetAgentId: context.installation.agentId,
      targetName: targetName,
      chosen: permissionMode,
    );

    final rendered = packet.render();
    // Which channel the packet is aimed at, from the target's own declared
    // capability; whether it *lands* there is the launcher's line to log.
    final support = descriptor?.launch.systemPromptFile ??
        const AgentSystemPromptFileSupport.unchecked();
    _log.info(
      '${isFork ? 'Fork' : 'Handoff'} from $sessionId to '
      '${context.installation.agentId} ($targetName): '
      'packet=${rendered.length} chars '
      'delivery=${support.isSupported ? support.token : support.wasChecked ? 'typed — $targetName has no system-prompt file option' : 'typed — $targetName has never been checked for one'} '
      'worktree=${intoNewWorktree ? 'new' : 'shared'} '
      'mode=${carried.override?.canonical ?? 'default'}',
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
            // The whole packet when it must be typed, the instruction alone
            // when the rest travels as a file: the packet already ends with it.
            firstMessage: support.isSupported ? instruction.trim() : rendered,
            systemPromptFile: support.isSupported ? rendered : null,
            parentSessionId: sessionId,
            parentLink: link,
            useWorktree: intoNewWorktree,
            existingWorktree: intoNewWorktree ? null : session.worktree,
            // The work is where it is: a session with no worktree may still run
            // in a subdirectory, which `existingWorktree` cannot say alone.
            workingDirectory: intoNewWorktree ? null : session.workingDirectory,
            permissionOverride: carried.override,
          ),
        );
  }

  /// What a continuation into [targetAgentId] starts from, and whether the
  /// source chose it: one that never chose starts at the *target's* default.
  ({PermissionRisk risk, bool chosen}) _startingMode(
    String sessionId,
    String targetAgentId,
  ) {
    final launcher = _ref.read(sessionLauncherProvider);
    final source = launcher.effectivePermissionFor(sessionId);
    if (source != null && !source.inherited) {
      // Measured on the one scale the target also understands:
      // `mode=acceptEdits` means nothing to Codex, but its permissiveness does.
      final risk = source.descriptor?.launch.permission.riskOf(
        source.selection,
      );
      if (risk != null) return (risk: risk, chosen: true);
    }
    final target = _ref.read(agentRegistryProvider).byId(targetAgentId);
    final support = target?.launch.permission;
    final fallback = support?.riskOf(
      launcher.permissionFor(targetAgentId, SessionPurpose.newSession),
    );
    return (risk: fallback ?? reviewPermissionCeiling, chosen: false);
  }

  /// The mode a continuation will run under, resolved once and passed as an
  /// override. [override] is null while the branch still follows the default.
  ({ContinuationPermission permission, PermissionSelection? override})
  _resolvePermission({
    required String sessionId,
    required AgentDescriptor? descriptor,
    required String targetAgentId,
    required String targetName,
    required PermissionSelection? chosen,
  }) {
    final starting = _startingMode(sessionId, targetAgentId);
    final permission = resolveContinuationPermission(
      sessionRisk: starting.risk,
      target: descriptor,
      chosen: chosen,
      targetName: targetName,
    );
    return (
      permission: permission,
      override:
          starting.chosen || permission.wasChosen || permission.carried.changed
          ? permission.selection
          : null,
    );
  }

  ({
    Repository repository,
    AgentInstallation installation,
    AgentDescriptor? descriptor,
    String agentName,
  })
  _contextFor(Session session, String installationId) {
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
    final registry = _ref.read(agentRegistryProvider);
    return (
      repository: repository,
      installation: installation,
      descriptor: registry.byId(installation.agentId),
      agentName: registry.displayNameFor(installation.agentId),
    );
  }

  /// `Fix the parser` → `Fix the parser (fork)`, or `(fork 2)` for the second
  /// branch, counted off the parent so two branches are told apart in a list.
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
/// continued elsewhere, out of one read of the same three rows.
class SessionContinuation {
  const SessionContinuation({required this.targets, required this.plan});

  final List<HandoffTarget> targets;
  final SessionForkPlan plan;

  /// Whether there is anywhere at all for this session to go.
  bool get isPossible =>
      targets.any((target) => target.canReceive) || !plan.isRefused;
}

/// The continuation options for one session. A provider, so a widget test can
/// override it instead of standing up a database for a yes/no question.
final sessionContinuationProvider = Provider.autoDispose
    .family<SessionContinuation, String>((ref, sessionId) {
      // Installing an agent publishes no session change of its own, so it
      // arrives as an untargeted bump, which [SessionSignals.forSession] sees.
      ref.watchSession(sessionId);
      final service = ref.watch(sessionHandoffServiceProvider);
      return SessionContinuation(
        targets: service.targetsFor(sessionId),
        plan: service.forkPlanFor(sessionId),
      );
    });
