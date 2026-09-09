import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import '../../git/domain/file_change.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../domain/decision_record.dart';
import '../domain/handoff_packet.dart';
import '../domain/session.dart';
import '../domain/session_fork.dart';
import '../domain/session_launch.dart';
import '../domain/session_lineage.dart';
import 'delivery_providers.dart';
import 'session_actions.dart';
import 'session_chat_source.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_wait.dart';
import 'session_working_directory.dart';

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

  /// Whether [permission] is the Settings default rather than a choice.
  ///
  /// True when the source session never chose a mode: this row's mode is then
  /// **this target's** new-session default, and the continuation will go on
  /// following it. The dialog has to say so — presenting a default as a
  /// decision hides that it moves when the setting does.
  final bool followsDefault;

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

  /// Every continuation says what it handed over, and how big it was.
  ///
  /// A handoff is the one action here that produces a *second* session out of a
  /// first, so when it goes wrong there are two rows and no record of which
  /// decision joined them. The packet's length is on the line for a specific
  /// reason: it is rendered into `firstMessage` and typed into the pane, and
  /// Claude Code collapses any paste over 800 characters into
  /// `[Pasted text #N]` — so a packet's size is the difference between the next
  /// agent reading the brief and reading a placeholder.
  static final _log = AppLogger.named('sessions.handoff');

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
    // Charged *before* the recap, on purpose. Both come out of one packet the
    // receiving agent pays for on its first turn, and if something has to give
    // it must be the quoted tail: a dropped turn is still in the transcript
    // the new agent can read, while a dropped decision is the thing nobody
    // wrote down twice.
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

  /// What this session decided, as recorded at the time.
  ///
  /// A straight read of the append-only record — no interpretation, no
  /// deduplication, no folding of a reversal into its reversal. The rows were
  /// written by explicit acts and the packet prints them; the only work done
  /// here is turning the stored enums into the words the packet renders.
  ///
  /// A database that will not answer yields **null**, which the packet renders
  /// as "could not be read". That is a different admission from an empty
  /// record, which means nobody wrote anything down — and the packet says so
  /// in different words, because an agent taking over a long session must not
  /// read either as "nothing was decided".
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
      // Partitioned *after* the trim, so the budget is charged once over the
      // whole record and the split cannot change what survives it. A rejected
      // approach is not a second copy of a decision — it moves, because the
      // reader needs it before they start work rather than among the rest.
      // From the enum rather than spelled again: the heading and the split
      // must not be able to drift apart.
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

  /// A rejected approach as the claim it is: what was ruled out, who said so,
  /// and what backs it — or **"not checked yet"**, which the claim itself
  /// renders rather than leaving the qualifier off.
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
      // Named, because it is the one state that is not the user's own
      // edit: a merge stopped here and both sides are still in the index.
      FileChangeType.conflicted =>
        'conflicted (${(change.conflict ?? MergeConflict.unrecorded).words})',
      // `unknown` is git's own shrug at a status code we do not model, and it
      // is reported as that rather than folded into "modified" — a wrong verb
      // about a file the next agent is about to edit is worse than an honest
      // one.
      FileChangeType.unknown => 'changed (unrecognised git status)',
    };
    // A conflict is never described as staged: both sides sit in the index
    // because git put them there, and "staged" would read as work the user did.
    if (change.type == FileChangeType.conflicted) return kind;
    if (change.staged && change.unstaged) return '$kind, staged and unstaged';
    if (change.staged) return '$kind, staged';
    return kind;
  }

  /// Asks [sessionId] to write its own handoff summary, and waits for it.
  ///
  /// **Offered, never automatic.** It spends a turn of the source agent's
  /// quota, and running out of that quota is one of the reasons people hand
  /// off at all — so the person asks for this, and declining leaves the packet
  /// exactly as it was.
  ///
  /// The request is Codex's own compaction prompt ([kSourceBriefRequest]),
  /// sent down the same path the message box uses, and the wait is the same
  /// event-driven machinery `session_wait` runs on: nothing here polls and
  /// nothing counts seconds of its own.
  ///
  /// **A handoff is never blocked on an agent that does not answer.** The
  /// wait's bound is the whole of the limit, and every way this can fail comes
  /// back as a [HandoffSourceBrief.notWritten] the packet prints — including
  /// the one that matters most, a source that answered nothing, which must not
  /// be reported as an empty brief.
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

    // Every sentence below is a *reason*, and the packet supplies the subject
    // — it names the source agent already, so naming it again here would put
    // that name in two places that could disagree.
    //
    // Before the send, exactly as `session_send` asks it: a message into a
    // session that has stopped for a person sits behind that prompt, and this
    // would then spend its whole bound learning nothing.
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
    // Counted, not timed, and counted against what was there before the
    // request: the newest turn in an unchanged transcript is something the
    // agent said earlier, and printing that as its brief would be the packet
    // inventing an answer.
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

  /// Everything the source agent has said, oldest first, read from its own
  /// transcript. Empty for a session whose transcript cannot be found or read,
  /// which is the same answer as one that has said nothing — and the caller
  /// only ever compares two readings of it, so the two cannot be confused.
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

  /// Continues [sessionId] in another agent.
  ///
  /// The old session is **not touched**: not ended, not detached, not marked.
  /// Since Loop 38 a session's lifetime is independent of any view of it, so
  /// leaving it exactly as it was is both possible and correct — the user
  /// decides whether to end it, and until they do the handoff is reversible by
  /// simply going back to it.
  ///
  /// [permissionMode] is the mode the user picked for *this* target in the
  /// dialog. It is resolved against the target the same way the sentence they
  /// read was, so a pick the target cannot express is downgraded rather than
  /// dropped. Null means nobody picked, and the session's own mode is carried.
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
            // The work is where it is. A session with no worktree can still be
            // running in a subdirectory — an adopted one usually is — and
            // `existingWorktree` cannot say so without also claiming a
            // worktree the session does not have.
            workingDirectory: intoNewWorktree ? null : session.workingDirectory,
            // The session's own mode unless the user picked another for the
            // branch. Still resolved rather than passed through: the fork runs
            // the same agent, so a pick can only ever be one that agent
            // expresses, but the resolution is where that stops being an
            // assumption.
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
    // Which channel the packet is aimed at, decided by the target's own
    // declared capability. Whether it *lands* there is the launcher's answer —
    // it writes the file and logs the outcome — and the two lines together are
    // what say why a packet was typed at a given CLI.
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
            // The whole packet when it has to be typed, and the instruction
            // alone when the rest of it travels as a file: the packet's own
            // last section is that instruction, so repeating it would spend
            // the receiving agent's first turn reading it twice.
            firstMessage: support.isSupported ? instruction.trim() : rendered,
            systemPromptFile: support.isSupported ? rendered : null,
            parentSessionId: sessionId,
            parentLink: link,
            useWorktree: intoNewWorktree,
            existingWorktree: intoNewWorktree ? null : session.worktree,
            // The work is where it is. A session with no worktree can still be
            // running in a subdirectory — an adopted one usually is — and
            // `existingWorktree` cannot say so without also claiming a
            // worktree the session does not have.
            workingDirectory: intoNewWorktree ? null : session.workingDirectory,
            permissionOverride: carried.override,
          ),
        );
  }

  /// What a continuation of [sessionId] into [targetAgentId] starts from, and
  /// whether that was the source session's own decision.
  ///
  /// A source that chose a mode hands that mode down. One that never chose is
  /// following the Settings default, and the honest starting point is then the
  /// **target's** new-session default — what the continuation will actually run
  /// under if it is left following the default too. Reading the source agent's
  /// existing-session default here instead would put a mode in the handoff
  /// dialog that the launch would never use.
  ({PermissionRisk risk, bool chosen}) _startingMode(
    String sessionId,
    String targetAgentId,
  ) {
    final launcher = _ref.read(sessionLauncherProvider);
    final source = launcher.effectivePermissionFor(sessionId);
    if (source != null && !source.inherited) {
      // The source agent's own mode, measured on the one scale the target also
      // understands. Its *vocabulary* cannot cross — `mode=acceptEdits` means
      // nothing to Codex — but how permissive it is can.
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

  /// The mode a continuation of [sessionId] into [descriptor] will run under,
  /// and what to record for it on the new session's row.
  ///
  /// Resolved *here*, once, and passed as an override, so the command line and
  /// the sentence the user read before launching come from the same call —
  /// [resolveContinuationPermission], which is also what the dialog's picker
  /// renders. Reading the target's own default instead would silently ignore
  /// both the session's mode and the user's pick, which is what Loop 49 exists
  /// to have stopped.
  ///
  /// [override] is null when there is nothing to record: a continuation
  /// inherits the source's **state**, not a snapshot of it, so a branch of a
  /// session that never chose goes on following the Settings default and moves
  /// with it exactly as its parent does. Three things make it a decision worth
  /// stamping — the source had chosen, the user picked one for this target, or
  /// the carry rule had to change it to fit this agent. The last matters most:
  /// a reduction left unrecorded would climb back to the unexpressible mode on
  /// the branch's next resume.
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
      // The session's own row and the installed agents both move under this.
      // Narrowed to the row: an agent being installed publishes no session
      // change of its own, so it still arrives as an untargeted bump, which
      // [SessionSignals.forSession] deliberately counts.
      ref.watchSession(sessionId);
      final service = ref.watch(sessionHandoffServiceProvider);
      return SessionContinuation(
        targets: service.targetsFor(sessionId),
        plan: service.forkPlanFor(sessionId),
      );
    });
