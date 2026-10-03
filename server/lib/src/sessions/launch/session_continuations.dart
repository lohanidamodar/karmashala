import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart'
    show TranscriptMessage, kAgentSwitchRole, readCliTranscript;
import 'package:karmashala_host_protocol/protocol.dart'
    show SessionEndedWithoutCode;
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart' show CheckpointDao;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart' show Repository;
import 'package:karmashala_session/delivery.dart' show SessionDelivery;
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart'
    show DecisionRecordDao, SessionAgentSpanDao, SessionDao;

import '../../automations/daemon_agents.dart';
import '../../checkpoints/daemon_checkpoints.dart';
import '../../data/conversations_handler.dart' show TranscriptStores;
import '../../domain/uuid.dart';
import '../../mcp/tools/checkout_delivery.dart';
import '../../mcp/tools/checkout_reach.dart';
import '../../status/hosted_session_wait.dart';
import '../session_agent_stitching.dart' show kSwitchInstruction;
import 'server_session_launcher.dart';

export '../session_agent_stitching.dart' show kSwitchInstruction;

/// How many of the source's snapshots a packet offers.
const int kHandoffCheckpointCount = 8;

/// One agent a session could be continued in — including the one already
/// running it: a fresh session is a real answer to a full context window.
class HandoffTarget {
  const HandoffTarget({
    required this.installation,
    required this.descriptor,
    required this.agentName,
    required this.permission,
    required this.isSameAgent,
    this.refusal,
    this.resumesConversation = false,
  });

  final AgentInstallation installation;
  final AgentDescriptor? descriptor;
  final String agentName;

  /// What the session's permission mode becomes on the way over.
  final CarriedPermission permission;
  final bool isSameAgent;

  /// Why this target cannot receive a handoff, or null when it can.
  final String? refusal;

  /// For a switch in place: this agent ran the session before, and its own
  /// conversation is resumed rather than a new one started.
  final bool resumesConversation;

  bool get canReceive => refusal == null;
}

/// **Continuing a session somewhere else, by the server** (slice 5b): the
/// handoff packet (a quoted recap from the agent's own transcript, the
/// working tree's changes, the branch, the decisions recorded, the
/// checkpoints to go back to, what is unresolved, and the instruction), the
/// source's own brief when asked for, and the new session — a handoff into
/// another agent, a fork of the same one (native where the CLI can), or a
/// fork that also puts the files back to a checkpoint. Each new session is
/// started through [ServerSessionLauncher], and the decision record follows
/// the work into it.
class SessionContinuations {
  SessionContinuations({
    required this.launches,
    required this.sessions,
    required this.rows,
    required this.decisions,
    required this.checkpoints,
    required this.reach,
    required this.transcripts,
    required this.carryDecision,
    this.forks,
    this.waits,
    this.send,
    this.spans,
    this.conversationOf,
    this.turnRunning,
    this.nextMessageOrdinal,
    this.onSwitched,
    this.cancelResume,
    this.holdQueue,
    this.releaseQueue,
    this.agents = const DaemonAgents(),
    this.registry = AgentRegistry.builtIn,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final ServerSessionLauncher launches;
  final SessionDao sessions;
  final CheckoutRows rows;
  final DecisionRecordDao decisions;
  final CheckpointDao checkpoints;
  final CheckoutReach reach;
  final TranscriptStores transcripts;

  /// Writes one carried decision as the server, so every client is told.
  final void Function(DecisionRecord record) carryDecision;

  /// The server's checkpoints, for a fork that restores one; null refuses.
  final DaemonCheckpoints? forks;

  /// Waits on a session the server runs, for its own brief; null writes none.
  final HostedSessionWait? waits;

  /// Types a message into a session the server runs; false when nothing runs
  /// it.
  final Future<bool> Function(String sessionId, String text)? send;

  /// Each agent a session ran under; null refuses a switch in place.
  final SessionAgentSpanDao? spans;

  /// A session's transcript as the server serves it — stitched across its
  /// agents, each row tagged — for a switch's recap; null reads the agent's
  /// own file as a handoff does.
  final Future<List<TranscriptMessage>> Function(String sessionId)?
  conversationOf;

  /// Whether a session's turn is running, or a message is on its way to it.
  final bool Function(String sessionId)? turnRunning;

  /// The ordinal the next `session_messages` row of a session takes.
  final int Function(String sessionId)? nextMessageOrdinal;

  /// Cancels a session's armed resume with the reason given; true when one
  /// was waiting. A switch cancels the leaving agent's: at its reset the
  /// resume would type that agent's message into another.
  final bool Function(String sessionId, String reason)? cancelResume;

  /// Holds a session's queue busy while its agent is switched, and lets it
  /// go: a send meanwhile waits for the new agent.
  final void Function(String sessionId)? holdQueue;
  final void Function(String sessionId)? releaseQueue;

  /// Told once a session's agent was switched and the new one started.
  final void Function(String sessionId, List<SessionAgentSpan> spans)?
  onSwitched;
  final DaemonAgents agents;
  final AgentRegistry registry;
  final void Function(String message)? log;
  final DateTime Function() _now;

  // --- what can be offered ---------------------------------------------------

  /// The agents [sessionId] could be continued in, in registry order. [inPlace]
  /// judges each as a switch of this session rather than a new one.
  List<HandoffTarget> targetsFor(String sessionId, {bool inPlace = false}) {
    final session = sessions.getById(sessionId);
    if (session == null) return const [];
    final repository = rows.repository(session.repositoryId);
    if (repository == null) return const [];
    final sourceAgentId = rows
        .installation(session.agentInstallationId)
        ?.agentId;
    return [
      for (final installation in launches.installationsIn(
        repository.path.environmentId,
      ))
        _target(session, installation, sourceAgentId, inPlace: inPlace),
    ];
  }

  HandoffTarget _target(
    Session session,
    AgentInstallation installation,
    String? sourceAgentId, {
    bool inPlace = false,
  }) {
    final descriptor = registry.byId(installation.agentId);
    final name = registry.displayNameFor(installation.agentId);
    final starting = _startingMode(session.id, installation.agentId);
    final same = installation.agentId == sourceAgentId;
    return HandoffTarget(
      installation: installation,
      descriptor: descriptor,
      agentName: name,
      permission: carryPermission(starting.risk, descriptor, targetName: name),
      isSameAgent: same,
      // Another installation of the same agent is a switch like any other:
      // it starts its own conversation, never the other one's.
      refusal: inPlace
          ? (installation.id == session.agentInstallationId
                ? '$name already runs this session.'
                : _refusalFor(
                    descriptor,
                    name,
                    speaksAcp: _speaksAcp(installation.agentId),
                  ))
          : _refusalFor(descriptor, name),
      resumesConversation:
          inPlace && _earlierConversation(session, installation.id) != null,
    );
  }

  bool _speaksAcp(String agentId) => agents.adapterOf(agentId)?.acp != null;

  String? _refusalFor(
    AgentDescriptor? descriptor,
    String name, {
    bool speaksAcp = false,
  }) {
    if (descriptor == null) {
      return 'Karmashala has no descriptor for this agent, so it cannot be '
          'told anything at launch.';
    }
    // Over ACP the packet is the first prompt, never argv.
    if (!speaksAcp && !descriptor.launch.acceptsPromptArgument) {
      return '$name takes no opening prompt, so the handoff packet could not '
          'be delivered — the new session would start knowing nothing.';
    }
    return null;
  }

  /// What forking [sessionId] would actually do.
  SessionForkPlan forkPlanFor(String sessionId) {
    final session = sessions.getById(sessionId);
    if (session == null) {
      return SessionForkPlan.decide(descriptor: null, agentName: 'this agent');
    }
    final agentId = rows.installation(session.agentInstallationId)?.agentId;
    return SessionForkPlan.decide(
      descriptor: agentId == null ? null : registry.byId(agentId),
      agentName: agentId == null
          ? 'this agent'
          : registry.displayNameFor(agentId),
      externalSessionId: session.externalSessionId,
      switched: spans?.hasSpans(sessionId) ?? false,
    );
  }

  // --- the packet ------------------------------------------------------------

  /// The packet [sessionId] would be handed over with. Best-effort: every part
  /// that cannot be read says so rather than failing the packet.
  Future<HandoffPacket> buildPacket({
    required String sessionId,
    required String targetAgentName,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool isFork = false,
    HandoffSourceBrief? sourceBrief,
    HandoffRecapBudget budget = const HandoffRecapBudget(),
    HandoffDecisionBudget decisionBudget = const HandoffDecisionBudget(),
    List<TranscriptMessage>? conversation,
    String? missedBy,
  }) async {
    final session =
        sessions.getById(sessionId) ??
        (throw const LaunchTargetMissing('This session no longer exists.'));
    final agentId = rows.installation(session.agentInstallationId)?.agentId;
    final sourceName = agentId == null
        ? 'a previous agent'
        : registry.displayNameFor(agentId);
    final repository = rows.repository(session.repositoryId);
    final directory =
        session.workingDirectory ?? session.worktree ?? repository?.path;
    final recorded = _decisionsFor(sessionId, decisionBudget);
    // A switched session's thread is every agent's turns, stitched; the
    // current agent's own record holds only its part.
    final thread =
        conversation ??
        (spans?.hasSpans(sessionId) ?? false
            ? await _conversationOf(sessionId)
            : null);
    final recap = thread != null
        ? _recapOf(
            missedTurns(thread, missedBy),
            sourceName,
            budget.reducedBy(recorded.cost),
          )
        : await _recapFor(
            session,
            agentId,
            sourceName,
            budget.reducedBy(recorded.cost),
          );
    final changes = directory == null ? null : await _changesIn(directory);
    final delivery = repository == null
        ? null
        : await _deliveryOf(repository.path, session.worktree);
    return HandoffPacket(
      sourceAgentName: sourceName,
      targetAgentName: targetAgentName,
      sourceTitle: session.title,
      sourceSessionId: session.id,
      sourceConversationId: session.externalSessionId,
      checkpoints: _checkpointsFor(sessionId),
      recapUnreadable: recap.unreadable,
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

  /// What the next agent would be told, as text: the packet, except for a
  /// fork the CLI performs itself, which carries its own conversation and is
  /// told only the source's brief (when one was written) and the instruction.
  Future<String> preview({
    required String sessionId,
    required String targetAgentName,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool isFork = false,
    HandoffSourceBrief? sourceBrief,
  }) async {
    if (isFork && forkPlanFor(sessionId).isNative) {
      final session =
          sessions.getById(sessionId) ??
          (throw const LaunchTargetMissing('This session no longer exists.'));
      final forked = ForkBrief.of(
        sourceAgentName: _agentNameOf(session),
        brief: sourceBrief,
        instruction: instruction,
      );
      return forked?.render() ?? instruction.trim();
    }
    return (await buildPacket(
      sessionId: sessionId,
      targetAgentName: targetAgentName,
      instruction: instruction,
      unresolvedTasks: unresolvedTasks,
      isFork: isFork,
      sourceBrief: sourceBrief,
    )).render();
  }

  List<HandoffCheckpoint> _checkpointsFor(String sessionId) {
    try {
      final chain = checkpoints.forSession(sessionId);
      return [
        for (final row in chain.reversed.take(kHandoffCheckpointCount))
          HandoffCheckpoint(
            id: row.id,
            label:
                row.label ??
                (row.turn == null
                    ? row.reason.name
                    : '${row.reason.name}, turn ${row.turn}'),
            takenAt: row.createdAt,
            files: row.files.length,
          ),
      ];
    } on Object {
      return const [];
    }
  }

  ({
    List<HandoffDecision>? decisions,
    List<HandoffClaim>? deadEnds,
    int omitted,
    int cost,
  })
  _decisionsFor(String sessionId, HandoffDecisionBudget budget) {
    try {
      final trimmed = trimDecisions([
        for (final row in decisions.forSession(sessionId))
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
    } on Object {
      return (decisions: null, deadEnds: null, omitted: 0, cost: 0);
    }
  }

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

  /// The tail of the conversation, from the agent's own transcript. **Not the
  /// same answer as an empty transcript** when it cannot be read.
  Future<({List<HandoffTurn> turns, int omitted, bool unreadable})> _recapFor(
    Session session,
    String? agentId,
    String sourceName,
    HandoffRecapBudget budget,
  ) async {
    final externalId = session.externalSessionId;
    if (agentId == null || externalId == null || externalId.isEmpty) {
      return (turns: const <HandoffTurn>[], omitted: 0, unreadable: false);
    }
    try {
      final path = await transcripts.locate(agentId, externalId);
      if (path == null) {
        return (turns: const <HandoffTurn>[], omitted: 0, unreadable: true);
      }
      final messages = await readCliTranscript(path, agentId);
      final trimmed = trimRecap([
        for (final message in messages)
          if (message.role == 'user' || message.role == 'agent')
            if (message.text.trim().isNotEmpty)
              HandoffTurn(
                speaker: message.role == 'user' ? 'The user' : sourceName,
                text: message.text.trim(),
              ),
      ], budget);
      return (
        turns: trimmed.turns,
        omitted: trimmed.omitted,
        unreadable: false,
      );
    } on Object {
      return (turns: const <HandoffTurn>[], omitted: 0, unreadable: true);
    }
  }

  /// [conversation]'s spoken turns, each agent's named by its own row tag.
  ({List<HandoffTurn> turns, int omitted, bool unreadable}) _recapOf(
    List<TranscriptMessage> conversation,
    String sourceName,
    HandoffRecapBudget budget,
  ) {
    final names = <String, String>{};
    String speaker(TranscriptMessage message) {
      if (message.role == 'user') return 'The user';
      final installation = message.agentInstallationId;
      if (installation == null) return sourceName;
      return names[installation] ??= switch (rows
          .installation(installation)
          ?.agentId) {
        final String agentId => registry.displayNameFor(agentId),
        null => sourceName,
      };
    }

    final trimmed = trimRecap([
      for (final message in conversation)
        if (message.role == 'user' || message.role == 'agent')
          if (message.text.trim().isNotEmpty)
            HandoffTurn(speaker: speaker(message), text: message.text.trim()),
    ], budget);
    return (turns: trimmed.turns, omitted: trimmed.omitted, unreadable: false);
  }

  /// The installation [session] would resume [installationId]'s own
  /// conversation under: the one it left when it last switched away.
  String? _earlierConversation(Session session, String installationId) {
    if (session.agentInstallationId == installationId) return null;
    final known = spans?.forSession(session.id) ?? const <SessionAgentSpan>[];
    for (final span in known.reversed) {
      if (span.agentInstallationId != installationId) continue;
      final id = span.externalSessionId;
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  Future<List<HandoffChange>?> _changesIn(EnvironmentPath directory) async {
    try {
      final status = await reach.ask(
        directory,
        (git, at) => git.statusWithBranch(at),
      );
      return [
        for (final change in status.changes)
          HandoffChange(
            path: change.path,
            state: _stateWords(change),
            originalPath: change.originalPath,
          ),
      ];
    } on Object {
      // Null, not empty: "git could not be asked" is not "the tree is clean".
      return null;
    }
  }

  Future<SessionDelivery?> _deliveryOf(
    EnvironmentPath repository,
    EnvironmentPath? worktree,
  ) async {
    try {
      final reader = CheckoutDeliveryReader(reach);
      return worktree == null
          ? await reader.local(repository)
          : await reader.worktree(repository, worktree);
    } on Object {
      return null;
    }
  }

  static String _stateWords(FileChange change) {
    final kind = switch (change.type) {
      FileChangeType.added => 'added',
      FileChangeType.modified => 'modified',
      FileChangeType.deleted => 'deleted',
      FileChangeType.renamed => 'renamed',
      FileChangeType.copied => 'copied',
      FileChangeType.untracked => 'untracked',
      FileChangeType.conflicted =>
        'conflicted (${(change.conflict ?? MergeConflict.unrecorded).words})',
      FileChangeType.unknown => 'changed (unrecognised git status)',
    };
    if (change.type == FileChangeType.conflicted) return kind;
    if (change.staged && change.unstaged) return '$kind, staged and unstaged';
    if (change.staged) return '$kind, staged';
    return kind;
  }

  /// Asks [sessionId] to write its own handoff summary and waits for it —
  /// offered, never automatic, and every failure a printable "not written".
  Future<HandoffSourceBrief> sourceBrief(
    String sessionId, {
    num? timeoutSeconds,
  }) async {
    final session =
        sessions.getById(sessionId) ??
        (throw const LaunchTargetMissing('This session no longer exists.'));
    final agentId = rows.installation(session.agentInstallationId)?.agentId;
    final waiting = waits;
    final type = send;
    if (waiting == null || type == null || !launches.runsHere(sessionId)) {
      return const HandoffSourceBrief.notWritten(
        'nothing is running that session, so there is nobody to ask.',
      );
    }
    if (waiting.blockedOn(sessionId) case final block?) {
      return HandoffSourceBrief.notWritten(
        'it is stopped waiting for a person (${block.kind}), so nothing was '
        'sent — a request would have sat behind that prompt. Answer it and '
        'ask again, or hand off without a brief.',
      );
    }
    final before = (await _agentTurnsIn(session, agentId)).length;
    try {
      if (!await type(sessionId, kSourceBriefRequest)) {
        return const HandoffSourceBrief.notWritten(
          'the request could not be delivered to it: its process ended.',
        );
      }
    } on Object catch (error) {
      return HandoffSourceBrief.notWritten(
        'the request could not be delivered to it ($error).',
      );
    }
    final outcome = await waiting.wait(
      sessionId,
      bound: sessionWaitBoundFor(timeoutSeconds),
      inputSent: true,
    );
    final after = await _agentTurnsIn(session, agentId);
    if (after.length <= before) {
      return HandoffSourceBrief.notWritten(switch (outcome.state) {
        SessionWaitState.timeout =>
          'it had not answered when this stopped waiting. The request was '
              'delivered and may still be answered in that session — the '
              'brief is simply not in this packet.',
        SessionWaitState.blocked =>
          'it stopped for a person before answering. Whatever it is asking '
              'is in that session.',
        SessionWaitState.ended =>
          'its process is gone; nothing is running there to answer.',
        _ =>
          'it settled without saying anything (${outcome.state.name}), so '
              'there is nothing of its own to quote.',
      });
    }
    return HandoffSourceBrief.written(after.last);
  }

  Future<List<String>> _agentTurnsIn(Session session, String? agentId) async {
    final externalId = session.externalSessionId;
    if (agentId == null || externalId == null || externalId.isEmpty) {
      return const [];
    }
    try {
      final path = await transcripts.locate(agentId, externalId);
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

  /// Continues [sessionId] in [targetInstallationId], leaving the source
  /// running and untouched.
  Future<SessionStarted> handoff({
    required String sessionId,
    required String targetInstallationId,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    String? permissionMode,
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

  /// Branches [sessionId] into a session of the **same agent** — the CLI's
  /// own fork where [forkPlanFor] says it has one, a packet otherwise.
  Future<SessionStarted> fork({
    required String sessionId,
    String instruction = '',
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    String? permissionMode,
    HandoffSourceBrief? sourceBrief,
  }) async {
    final session =
        sessions.getById(sessionId) ??
        (throw const LaunchTargetMissing('This session no longer exists.'));
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
        sourceBrief: sourceBrief,
      );
    }
    final context = _contextFor(session, session.agentInstallationId);
    // The CLI carries the conversation; the brief the source spent a turn on
    // goes beside it, the way a handoff's packet does — a system-prompt file
    // where the agent takes one, otherwise the opening message (which ends
    // with the instruction, so nothing typed is lost).
    final brief = ForkBrief.of(
      sourceAgentName: context.agentName,
      brief: sourceBrief,
      instruction: instruction,
    )?.render();
    if (brief != null) {
      final support =
          context.descriptor?.launch.systemPromptFile ??
          const AgentSystemPromptFileSupport.unchecked();
      log?.call(
        'Fork of $sessionId carries its brief: ${brief.length} chars '
        'delivery=${support.isSupported ? support.token : 'typed'}',
      );
    }
    final carried = _resolvePermission(
      sessionId: sessionId,
      descriptor: context.descriptor,
      targetAgentId: context.installation.agentId,
      targetName: context.agentName,
      chosen: permissionMode == null
          ? null
          : PermissionSelection.parse(permissionMode),
    );
    final started = await launches.start(
      SessionStartSpec(
        repositoryId: context.repository.id,
        installationId: context.installation.id,
        title: _forkTitle(sessionId, session.title),
        forkConversationId: session.externalSessionId,
        prompt: instruction.trim().isEmpty ? null : instruction,
        systemPrompt: brief,
        parentSessionId: sessionId,
        parentLink: SessionLink.fork,
        worktree: intoNewWorktree,
        existingWorktree: intoNewWorktree ? null : session.worktree,
        workingDirectory: intoNewWorktree ? null : session.workingDirectory,
        permissionMode: carried?.canonical,
      ),
    );
    _carryDecisions(from: sessionId, into: started.sessionId);
    return started;
  }

  /// **Hands [sessionId] to [targetInstallationId] in place**: the same row
  /// and chat, the running agent stopped (`switched`), the new one started
  /// with what it missed — resuming its own conversation when it ran this
  /// session before and can resume, else a new one with the whole packet.
  /// Refused mid-turn, on an archived or external session, and for an agent
  /// that could not be told anything.
  Future<SessionStarted> switchAgent({
    required String sessionId,
    required String targetInstallationId,
    String instruction = '',
    String? permissionMode,
  }) async {
    final ledger =
        spans ??
        (throw StateError('This server cannot switch a session\'s agent.'));
    final session =
        sessions.getById(sessionId) ??
        (throw const LaunchTargetMissing('This session no longer exists.'));
    if (session.isArchived) {
      throw StateError('This session is archived; restore it to switch.');
    }
    if (session.surface == SessionSurface.external) {
      throw StateError(
        'This session runs in a terminal window Karmashala does not own, so '
        'its agent cannot be stopped to switch.',
      );
    }
    final context = _contextFor(session, targetInstallationId);
    final sourceAgentId = rows
        .installation(session.agentInstallationId)
        ?.agentId;
    final target = _target(
      session,
      context.installation,
      sourceAgentId,
      inPlace: true,
    );
    if (target.refusal case final refusal?) throw StateError(refusal);
    if (turnRunning?.call(sessionId) ?? false) {
      throw StateError(
        'A turn is running in this session. Switch once it settles, or stop '
        'it first.',
      );
    }
    // Held busy until the new agent runs: a send meanwhile queues for it
    // rather than racing its start.
    holdQueue?.call(sessionId);
    try {
      return await _switchHeld(
        session: session,
        context: context,
        ledger: ledger,
        sourceAgentId: sourceAgentId,
        instruction: instruction,
        permissionMode: permissionMode,
      );
    } finally {
      releaseQueue?.call(sessionId);
    }
  }

  Future<SessionStarted> _switchHeld({
    required Session session,
    required ({
      Repository repository,
      AgentInstallation installation,
      AgentDescriptor? descriptor,
      String agentName,
    })
    context,
    required SessionAgentSpanDao ledger,
    required String? sourceAgentId,
    required String instruction,
    required String? permissionMode,
  }) async {
    final sessionId = session.id;
    final targetInstallationId = context.installation.id;

    final targetAcp = _speaksAcp(context.installation.agentId);
    final sourceAcp = sourceAgentId != null && _speaksAcp(sourceAgentId);
    final earlier = _earlierConversation(session, targetInstallationId);
    final resumable =
        earlier != null &&
        (targetAcp || (context.descriptor?.launch.resume.isSupported ?? false));
    final conversation = await _conversationOf(sessionId);
    final said = instruction.trim().isEmpty
        ? kSwitchInstruction
        : instruction.trim();
    final packet = await buildPacket(
      sessionId: sessionId,
      targetAgentName: context.agentName,
      instruction: said,
      conversation: conversation,
      missedBy: resumable ? targetInstallationId : null,
    );
    final carried = _resolvePermission(
      sessionId: sessionId,
      descriptor: context.descriptor,
      targetAgentId: context.installation.agentId,
      targetName: context.agentName,
      chosen: permissionMode == null
          ? null
          : PermissionSelection.parse(permissionMode),
    );
    final rendered = packet.render();
    final support =
        context.descriptor?.launch.systemPromptFile ??
        const AgentSystemPromptFileSupport.unchecked();
    // The packet as a system-prompt file where the agent takes one, resumed
    // or not: a prompt file outside the workspace makes it ask to read it.
    final asFile = !targetAcp && support.isSupported;
    log?.call(
      'Switch of $sessionId from ${sourceAgentId ?? 'unknown'} to '
      '${context.installation.agentId}: '
      '${resumable ? 'resuming $earlier' : 'new conversation'} '
      'packet=${rendered.length} chars '
      'delivery=${asFile ? support.token : 'typed'} '
      'mode=${carried?.canonical ?? 'default'}',
    );

    await launches.end(
      sessionId,
      quietly: true,
      reason: SessionEndedWithoutCode.switched,
    );
    final firstSwitch = !ledger.hasSpans(sessionId);
    final span = ledger.recordSwitch(
      session: session,
      toInstallationId: targetInstallationId,
      toExternalSessionId: resumable ? earlier : null,
      at: _now(),
      firstMessageOrdinal: targetAcp
          ? nextMessageOrdinal?.call(sessionId) ?? 0
          : null,
      leavingFirstMessageOrdinal: sourceAcp ? 0 : null,
      carriedPacket: rendered,
    );
    // The row's mode and model were the last agent's words for them.
    sessions
      ..updatePermissionMode(sessionId, carried?.canonical)
      ..updateModel(sessionId, null);
    // An agent that takes our id starts under the row's — unless an earlier
    // agent of this row already holds it, as another installation of the
    // same agent does: one id is never claimed by two conversations.
    final rowIdTaken = ledger
        .forSession(sessionId)
        .any((s) => s.externalSessionId == sessionId);
    final SessionStarted started;
    try {
      started = await launches.resume(
        sessionId,
        prompt: asFile ? said : rendered,
        systemPrompt: asFile ? rendered : null,
        freshConversationId: !resumable && rowIdTaken ? newUuid() : null,
      );
    } on Object catch (error) {
      ledger.undoSwitch(session, fromSeq: firstSwitch ? 0 : span.seq);
      sessions.updatePermissionMode(sessionId, session.permissionMode);
      sessions.updateModel(sessionId, session.modelId);
      onSwitched?.call(sessionId, ledger.forSession(sessionId));
      // The agent that was stopped for the switch is started again, so a
      // failed switch leaves the session as it found it where it can.
      final previous = _agentNameOf(session);
      final why = error is StateError ? error.message : '$error';
      var restored = false;
      try {
        await launches.resume(sessionId);
        restored = true;
      } on Object catch (again) {
        log?.call(
          'Switch of $sessionId failed, and $previous did not '
          'start again either: $again',
        );
      }
      throw StateError(
        restored
            ? '${context.agentName} did not start ($why). $previous runs '
                  'this session again.'
            : '${context.agentName} did not start ($why), and $previous, '
                  'stopped for the switch, did not start again. Send a '
                  'message, or resume it, to continue with $previous.',
      );
    }
    onSwitched?.call(sessionId, ledger.forSession(sessionId));
    final leaving = _agentNameOf(session);
    final cancelled =
        cancelResume?.call(
          sessionId,
          'The session switched from $leaving to ${context.agentName}, so '
          'the resume scheduled for $leaving was cancelled.',
        ) ??
        false;
    if (!cancelled) return started;
    return started.withNotice(
      'The resume scheduled for $leaving was cancelled: it would have '
      'typed $leaving\'s message into ${context.agentName}.',
    );
  }

  Future<List<TranscriptMessage>?> _conversationOf(String sessionId) async {
    final read = conversationOf;
    if (read == null) return null;
    try {
      return await read(sessionId);
    } on Object {
      return null;
    }
  }

  Future<SessionStarted> _continue({
    required String sessionId,
    required String targetInstallationId,
    required String instruction,
    required List<String> unresolvedTasks,
    required bool intoNewWorktree,
    required SessionLink link,
    bool isFork = false,
    String? permissionMode,
    HandoffSourceBrief? sourceBrief,
  }) async {
    final session =
        sessions.getById(sessionId) ??
        (throw const LaunchTargetMissing('This session no longer exists.'));
    if (instruction.trim().isEmpty) {
      throw StateError(
        'Say what the next agent should do. The packet carries the '
        'conversation; the instruction is the part only you can write.',
      );
    }
    final context = _contextFor(session, targetInstallationId);
    final refusal = _refusalFor(context.descriptor, context.agentName);
    if (refusal != null) throw StateError(refusal);
    final packet = await buildPacket(
      sessionId: sessionId,
      targetAgentName: context.agentName,
      instruction: instruction,
      unresolvedTasks: unresolvedTasks,
      isFork: isFork,
      sourceBrief: sourceBrief,
    );
    final carried = _resolvePermission(
      sessionId: sessionId,
      descriptor: context.descriptor,
      targetAgentId: context.installation.agentId,
      targetName: context.agentName,
      chosen: permissionMode == null
          ? null
          : PermissionSelection.parse(permissionMode),
    );
    final rendered = packet.render();
    final support =
        context.descriptor?.launch.systemPromptFile ??
        const AgentSystemPromptFileSupport.unchecked();
    log?.call(
      '${isFork ? 'Fork' : 'Handoff'} from $sessionId to '
      '${context.installation.agentId} (${context.agentName}): '
      'packet=${rendered.length} chars '
      'delivery=${support.isSupported ? support.token : 'typed'} '
      'worktree=${intoNewWorktree ? 'new' : 'shared'} '
      'mode=${carried?.canonical ?? 'default'}',
    );
    final started = await launches.start(
      SessionStartSpec(
        repositoryId: context.repository.id,
        installationId: context.installation.id,
        title: isFork
            ? _forkTitle(sessionId, session.title)
            : '${session.title} · ${context.agentName}',
        // The whole packet when it must be typed, the instruction alone when
        // the rest travels as a file (the packet ends with it anyway).
        prompt: support.isSupported ? instruction.trim() : rendered,
        systemPrompt: support.isSupported ? rendered : null,
        parentSessionId: sessionId,
        parentLink: link,
        worktree: intoNewWorktree,
        existingWorktree: intoNewWorktree ? null : session.worktree,
        workingDirectory: intoNewWorktree ? null : session.workingDirectory,
        permissionMode: carried?.canonical,
      ),
    );
    _carryDecisions(from: sessionId, into: started.sessionId);
    return started;
  }

  /// Forks [sessionId] **and** puts its working tree back to a checkpoint;
  /// answers both halves separately, as `session_fork_from_checkpoint` reads
  /// them, never a fork that only half happened described as whole.
  Future<Map<String, Object?>> forkFromCheckpoint({
    required String sessionId,
    String? checkpointId,
    int? turn,
    String instruction = '',
    bool newWorktree = false,
    bool confirm = false,
    bool preview = false,
    String? requestedBy,
  }) async {
    final work =
        forks ??
        (throw StateError('This server keeps no checkpoints to fork from.'));
    final checkpoint = work.forkCheckpoint(
      sessionId: sessionId,
      checkpointId: checkpointId,
      turn: turn,
    );
    final plan = forkPlanFor(sessionId);
    final fileRefusal = work.forkFileRefusal(
      checkpoint,
      sessionId: sessionId,
      intoNewWorktree: newWorktree,
      requestedBy: requestedBy,
    );
    if (preview) {
      return {
        'preview': true,
        'route': plan.kind.name,
        'explanation': plan.explanation,
        'checkpoint': _checkpointJson(checkpoint),
        'conversation': _conversationJson(),
        'files': {
          'wouldRestore': fileRefusal == null,
          'repository': checkpoint.repository.path,
          'reason': ?fileRefusal,
        },
      };
    }
    if (plan.isRefused) throw StateError(plan.explanation);
    // The files first: a refusal here must not leave a session behind.
    RestoreOutcome? restored;
    Checkpoint? undo;
    if (fileRefusal == null) {
      // No safety checkpoint is taken of a tree already recorded; then the
      // latest checkpoint is the way back.
      final before = latestCheckpointIn(
        work.forSession(sessionId),
        repository: checkpoint.repository,
      );
      restored = await work.restoreForFork(
        checkpoint,
        confirm: confirm,
        requestedBy: requestedBy,
      );
      undo = restored.safetyCheckpoint ?? before;
    }
    final SessionStarted started;
    try {
      started = await fork(
        sessionId: sessionId,
        instruction: instruction,
        intoNewWorktree: newWorktree,
      );
    } on Object catch (error) {
      if (restored == null || restored.alreadyThere) rethrow;
      final count = restored.files.length;
      throw StateError(
        'No session was started: $error. The files were already restored '
        'to checkpoint ${checkpoint.sequence} ($count file'
        '${count == 1 ? '' : 's'}) in ${checkpoint.repository.path}'
        '${undo == null ? '.' : '; checkpoint_restore ${undo.id} puts them '
                  'back as they were.'}',
      );
    }
    final wrote = restored != null && !restored.alreadyThere;
    final halves = checkpointForkHalves(
      route: plan.kind.name,
      checkpoint: checkpoint,
      fileRefusal: fileRefusal,
      alreadyThere: restored?.alreadyThere,
      restoredFiles: restored?.files.length ?? 0,
      undoCheckpointId: wrote ? undo?.id : null,
    );
    return {
      'sessionId': started.sessionId,
      'title': started.session.title,
      'parentSessionId': sessionId,
      'link': SessionLink.fork.name,
      'route': plan.kind.name,
      'explanation': plan.explanation,
      'checkpoint': _checkpointJson(checkpoint),
      'delivered': halves.delivered,
      'notDelivered': halves.notDelivered,
      'conversation': _conversationJson(),
      'files': {
        'restored': restored != null && !restored.alreadyThere,
        'repository': checkpoint.repository.path,
        'reason': ?fileRefusal,
        if (restored != null) ...{
          'alreadyThere': restored.alreadyThere,
          'safetyCheckpointId': restored.safetyCheckpoint?.id,
          if (wrote) 'undoCheckpointId': undo?.id,
          'paths': [
            for (final file in restored.files)
              {'path': file.path, 'status': file.type.name},
          ],
        },
      },
      if (started.session.worktree != null)
        'worktree': started.session.worktree!.path,
    };
  }

  static Map<String, Object?> _checkpointJson(Checkpoint checkpoint) => {
    'id': checkpoint.id,
    'sequence': checkpoint.sequence,
    'turn': checkpoint.turn,
    'title': checkpointTitle(checkpoint),
    'reason': checkpoint.reason.name,
    'label': checkpoint.label,
    'prompt': checkpoint.prompt,
    'createdAt': checkpoint.createdAt.toIso8601String(),
    'repository': checkpoint.repository.path,
    'environmentId': checkpoint.repository.environmentId,
  };

  /// Constant on purpose: no route here rewinds a conversation.
  static Map<String, Object?> _conversationJson() => {
    'carried': 'whole',
    'rewoundToTurn': false,
    'note': kForkCarriesTheWholeConversation,
  };

  /// What a continuation into [targetAgentId] starts from, and whether the
  /// source chose it: one that never chose starts at the target's default.
  ({PermissionRisk risk, bool chosen}) _startingMode(
    String sessionId,
    String targetAgentId,
  ) {
    final source = launches.effectivePermissionOf(sessionId);
    final sourceAgent = rows
        .installation(sessions.getById(sessionId)?.agentInstallationId ?? '')
        ?.agentId;
    if (source != null && source.chosen && sourceAgent != null) {
      final risk = registry
          .byId(sourceAgent)
          ?.launch
          .permission
          .riskOf(source.selection);
      if (risk != null) return (risk: risk, chosen: true);
    }
    final support = registry.byId(targetAgentId)?.launch.permission;
    final fallback = support?.riskOf(
      launches.permissionFor(targetAgentId, SessionPurpose.newSession),
    );
    return (risk: fallback ?? reviewPermissionCeiling, chosen: false);
  }

  /// The mode a continuation runs under, as the selection to pass, or null
  /// while it still follows the default.
  PermissionSelection? _resolvePermission({
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
    return starting.chosen || permission.wasChosen || permission.carried.changed
        ? permission.selection
        : null;
  }

  ({
    Repository repository,
    AgentInstallation installation,
    AgentDescriptor? descriptor,
    String agentName,
  })
  _contextFor(Session session, String installationId) {
    final repository = rows.repository(session.repositoryId);
    if (repository == null) {
      throw const LaunchTargetMissing(
        'This session\'s repository is no longer available.',
      );
    }
    final installation = rows.installation(installationId);
    if (installation == null) {
      throw const LaunchTargetMissing(
        'That agent is not installed any more. Run "Discover agents" in '
        'Settings.',
      );
    }
    return (
      repository: repository,
      installation: installation,
      descriptor: registry.byId(installation.agentId),
      agentName: registry.displayNameFor(installation.agentId),
    );
  }

  /// The display name of the agent running [session].
  String _agentNameOf(Session session) {
    final agentId = rows.installation(session.agentInstallationId)?.agentId;
    return agentId == null ? 'this agent' : registry.displayNameFor(agentId);
  }

  /// `Fix the parser` → `Fix the parser (fork)`, or `(fork 2)` for the second.
  String _forkTitle(String parentId, String title) {
    final existing = sessions
        .childrenOf(parentId)
        .where((child) => child.parentLink == SessionLink.fork)
        .length;
    return existing == 0 ? '$title (fork)' : '$title (fork ${existing + 1})';
  }

  /// The decision record follows the work: copied, as the server, into the
  /// new session. Never a reason to fail a launch that happened.
  void _carryDecisions({required String from, required String into}) {
    if (from == into) return;
    try {
      final source = decisions.forSession(from);
      for (final decision in source) {
        carryDecision(
          DecisionRecord(
            sessionId: into,
            kind: decision.kind,
            summary: decision.summary,
            detail: decision.detail,
            decidedBy: decision.decidedBy,
            recordedBySessionId: decision.recordedBySessionId ?? from,
            origin: decision.origin,
            originId: decision.originId,
            recordedAt: decision.recordedAt,
          ),
        );
      }
      if (source.isNotEmpty) {
        log?.call(
          'Carried ${source.length} decision(s) from $from into $into.',
        );
      }
    } on Object catch (error) {
      log?.call('Could not carry decisions from $from: $error');
    }
  }
}

/// The turns of [conversation] after [installationId] last spoke in it —
/// all of them when it never did, or when [installationId] is null.
List<TranscriptMessage> missedTurns(
  List<TranscriptMessage> conversation,
  String? installationId,
) {
  if (installationId == null) return conversation;
  for (var i = conversation.length - 1; i >= 0; i--) {
    final message = conversation[i];
    if (message.agentInstallationId == installationId &&
        message.role != kAgentSwitchRole) {
      return conversation.sublist(i + 1);
    }
  }
  return conversation;
}
