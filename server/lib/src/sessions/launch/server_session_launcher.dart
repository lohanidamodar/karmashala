import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show ConversationPresence;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:path/path.dart' as p;

import '../../automations/daemon_agents.dart';
import '../../automations/daemon_checkout_facts.dart';
import '../../automations/hosted_agent_launcher.dart';
import '../../domain/session_registry.dart';
import 'capacity/launch_slots.dart';
import 'capacity/session_launch_gate.dart';
import 'launch_settings.dart';

/// The [SessionLaunchGate] kind a session launch waits under.
const String kSessionStartLaunchKind = 'session.start';

/// Asks an agent's own store whether it holds a conversation.
typedef ConversationPresenceIn =
    Future<ConversationPresence> Function(
      String agentId,
      String conversationId,
    );

/// A session, checkout or installation a launch names is not there — refused
/// `notFound` on the wire, `Error:` to an agent.
class LaunchTargetMissing implements Exception {
  const LaunchTargetMissing(this.message);
  final String message;
  @override
  String toString() => message;
}

/// **The one way a session comes into existence** (slice 5b): a person's New
/// session, a resume, an agent's `open_new_session`, a handoff or a fork —
/// every decision the app's launcher made, made here, then started through
/// [HostedAgentLauncher] as a terminal under the session's own id.
///
/// The decisions, in the app's order: a restart cannot also resume or fork;
/// a conversation this server already runs is answered as it is (`adopted`),
/// never a second process; a second process on a held conversation is
/// refused where the agent will not share it; a stored executable that no
/// longer opens is repaired or refused; a row pointed at a conversation its
/// agent never wrote goes back to its own, or is refused; the spawn-depth
/// cap; a directory that has gone falls back to the checkout, in words.
class ServerSessionLauncher {
  ServerSessionLauncher({
    required this.launcher,
    required this.registry,
    required this.sessions,
    required this.rows,
    required this.facts,
    required this.installationsIn,
    this.settings,
    this.presenceOf,
    this.repairAgents,
    this.pathProbe = const LocalPathProbe(),
    this.directoryPresent,
    this.agents = const DaemonAgents(),
    this.registryOfAgents = AgentRegistry.builtIn,
    this.trustScratchFolder,
    this.discardFailedScratch,
    this.writeScratchInstructions,
    this.log,
    this.gate,
  });

  final HostedAgentLauncher launcher;
  final SessionRegistry registry;
  final SessionDao sessions;
  final CheckoutRows rows;
  final DaemonCheckoutFacts facts;

  /// The installations recorded in an environment, oldest first.
  final List<AgentInstallation> Function(String environmentId) installationsIn;

  /// A person's Settings, read on every launch.
  final LaunchSettings Function()? settings;

  /// Whether an agent's own store holds a conversation; null never asks.
  final ConversationPresenceIn? presenceOf;

  /// Repairs every stored agent path that no longer opens (the sweep
  /// Settings runs); null never repairs.
  final Future<void> Function()? repairAgents;
  final PathProbe pathProbe;

  /// Whether a recorded directory is still there; null asks this machine's
  /// disk, and "could not tell" is true.
  final bool Function(EnvironmentPath directory)? directoryPresent;
  final DaemonAgents agents;
  final AgentRegistry registryOfAgents;

  /// Marks a scratch folder trusted in the agent's own settings before it
  /// starts there, so it does not ask about a folder made for it.
  final Future<void> Function(
    AgentInstallation installation,
    EnvironmentPath folder,
  )?
  trustScratchFolder;

  /// Gives a scratch folder its instruction files
  /// (`ProjectFolders.writeScratchInstructions`), answering whether they are
  /// there; null writes none, and every agent is told in words.
  final Future<bool> Function(EnvironmentPath folder)? writeScratchInstructions;

  /// Removes a scratch checkout a fresh launch failed in, when nothing else
  /// is there (`ProjectFolders.discardFailedScratch`); null keeps it.
  final Future<bool> Function(Repository checkout)? discardFailedScratch;
  final void Function(String message)? log;

  /// The concurrency limits every launch passes; null is none.
  final SessionLaunchGate? gate;

  LaunchSettings get _settings => settings?.call() ?? LaunchSettings.none;

  /// Whether this server runs session [sessionId] right now.
  bool runsHere(String sessionId) {
    final session = registry.findProcess(hostSessionIdOf(sessionId));
    return session != null && !session.lifecycle.hasEnded;
  }

  /// "The default agent" of [environmentId], as the New-session dialog means
  /// it: the one Settings names, else the first installed, in the form
  /// chosen for it.
  AgentInstallation? defaultInstallationIn(String environmentId) {
    final installs = installationsIn(environmentId);
    if (installs.isEmpty) return null;
    return installationFor(
      _settings.defaultInstallationAmong(installs) ?? installs.first,
    );
  }

  /// [install]'s agent on its machine as [form] — refused when that form is
  /// not installed there — else in the form a person chose for the agent,
  /// where it is installed, else [install] itself.
  AgentInstallation installationFor(
    AgentInstallation install, {
    AgentRunForm? form,
  }) {
    final registry = agents.registry;
    final installs = installationsIn(install.environmentId);
    if (form != null) {
      return registry.inForm(install, installs, form) ??
          (throw StateError(
            '${registry.foldedNameOf(install.agentId)} is not installed as '
            '${form.name} in ${install.environmentId}.',
          ));
    }
    final chosen = _settings.chosenRunFormOf(
      registry.foldedIdOf(install.agentId),
    );
    if (chosen == null) return install;
    return registry.inForm(install, installs, chosen) ?? install;
  }

  /// The mode [agentId] starts under for [purpose], [sessionMode] first,
  /// then Settings, then the agent's declared default.
  PermissionSelection permissionFor(
    String agentId,
    SessionPurpose purpose, {
    String? sessionMode,
  }) {
    final policy = _settings;
    return agents.permissionOf(
      agentId,
      resolveSessionPermission(
        sessionMode: sessionMode,
        newSessionDefault: policy.newSessionModes[agentId],
        existingSessionDefault: policy.existingSessionModes[agentId],
        purpose: purpose,
      ).stored,
    );
  }

  /// The mode [sessionId] runs under next, and whether it chose it.
  ({PermissionSelection selection, bool chosen})? effectivePermissionOf(
    String sessionId,
  ) {
    final session = sessions.getById(sessionId);
    if (session == null) return null;
    final agentId = rows.installation(session.agentInstallationId)?.agentId;
    if (agentId == null) return null;
    final policy = _settings;
    final resolved = resolveSessionPermission(
      sessionMode: session.permissionMode,
      newSessionDefault: policy.newSessionModes[agentId],
      existingSessionDefault: policy.existingSessionModes[agentId],
      purpose: SessionPurpose.existingSession,
    );
    return (
      selection: agents.permissionOf(agentId, resolved.stored),
      chosen: resolved.chosen,
    );
  }

  /// How deep a child of [parentSessionId] would be.
  SessionDepth depthForChildOf(String? parentSessionId) =>
      SessionDepth.forChildOf(parentSessionId, sessions.parentOf);

  /// Starts what [spec] asks for. Throws [LaunchTargetMissing], or
  /// [StateError] / [ArgumentError] in the words a person or agent reads.
  ///
  /// Under a concurrency limit the launch may wait: the answer then carries
  /// [SessionStarted.wait], a new session's row is written `created`, and it
  /// starts by itself when a slot frees. [priority] says whose launch it is;
  /// [startAnyway] is a person's confirmed override of the limits.
  Future<SessionStarted> start(
    SessionStartSpec spec, {
    String? freshConversationId,
    LaunchPriority priority = LaunchPriority.interactive,
    bool startAnyway = false,
    LaunchReservation? reservation,
    String? waitingRowId,
  }) async {
    if (spec.restartSessionId != null &&
        (spec.resumeConversationId != null ||
            spec.forkConversationId != null)) {
      throw ArgumentError(
        'A launch cannot restart a session and also resume or fork a '
        'conversation.',
      );
    }
    if (spec.resumeConversationId != null && spec.forkConversationId != null) {
      throw ArgumentError(
        'A launch cannot both resume and fork a conversation.',
      );
    }
    if (spec.worktree && spec.existingWorktree != null) {
      throw ArgumentError(
        'A launch cannot both create a worktree and join an existing one.',
      );
    }
    final repository =
        rows.repository(spec.repositoryId) ??
        (throw const LaunchTargetMissing(
          'That checkout is not in the workspace any more.',
        ));
    var installation =
        rows.installation(spec.installationId) ??
        (throw const LaunchTargetMissing(
          'That agent is not installed any more. Run "Discover agents" in '
          'Settings.',
        ));
    final environment = rows.environment(repository.path.environmentId);
    if (environment != null &&
        environment.kind == EnvironmentKind.wsl &&
        !facts.isHere(environment)) {
      throw StateError(
        '${environment.name} is a WSL distribution, and this server is not '
        'on Windows, so it cannot start an agent there.',
      );
    }
    final agentId = installation.agentId;

    // Already running here, with no second process wanted: that *is* it.
    final held = _heldRowFor(spec, repository);
    if (held != null) return _adopted(held);

    _refuseIfForbidden(agentId, spec.resumeConversationId);
    installation = await _usable(installation);

    var resumeId = spec.resumeConversationId;
    Session? reused =
        _reusableForResume(spec, repository, installation) ??
        _reusableForRestart(spec, repository, installation);
    final resolved = await _conversationToResume(
      spec,
      installation,
      repository,
      reused,
    );
    if (resolved != null) {
      resumeId = resolved.conversationId;
      reused = resolved.row ?? reused;
    }

    final depth = depthForChildOf(spec.parentSessionId);
    if (!depth.isAllowed) throw StateError(depth.refusal);

    // A restart keeps the row and starts a fresh conversation in it.
    final restarting = spec.restartSessionId != null && reused != null;

    // The directory: the worktree being joined, a new one, or where this
    // conversation actually runs — falling back, in words, off one that went.
    EnvironmentPath? workingDirectory;
    var recordDirectory = true;
    String? notice;
    if (spec.existingWorktree == null && !spec.worktree) {
      final wanted =
          spec.workingDirectory ?? reused?.workingDirectory ?? reused?.worktree;
      if (wanted != null && wanted != repository.path) {
        if (_present(wanted)) {
          workingDirectory = wanted;
        } else {
          workingDirectory = repository.path;
          recordDirectory = false;
          notice =
              '${wanted.path} no longer exists, so this session starts in '
              '${repository.path.path} instead.';
        }
      }
    }
    final launchDirectory =
        spec.existingWorktree ?? workingDirectory ?? repository.path;
    final caveat = _elsewhereCaveat(
      agentId,
      resumeId ?? spec.forkConversationId,
      launchDirectory,
    );

    // A session another one started names its parent in the prompt, the only
    // channel it has — built from the row, never pattern-matched.
    final parent = spec.parentSessionId == null
        ? null
        : sessions.getById(spec.parentSessionId!);
    final attribution = parent == null
        ? null
        : SessionAttribution(sessionId: parent.id, title: parent.title);
    final attributed = spec.prompt == null || attribution == null
        ? spec.prompt
        : attribution.render(spec.prompt!);
    // A fresh conversation in a scratch folder is told where it is and that
    // the repositories are its to attach; a resumed one was told already. An
    // agent that reads its folder's instruction files reads it there, so its
    // first message is only what the person wrote.
    final freshConversation =
        !restarting && resumeId == null && spec.forkConversationId == null;
    final inScratch = rows.isScratchProject(repository.projectId);
    final toldByFile =
        freshConversation &&
        inScratch &&
        await _instructScratch(installation, launchDirectory);
    final prompt = freshConversation && inScratch && !toldByFile
        ? withScratchPreamble(launchDirectory.path, attributed)
        : attributed;
    if (inScratch) await _trustScratch(installation, launchDirectory);

    final rowId = reused?.id ?? waitingRowId ?? launcher.newId();
    var reserved = reservation;
    final gate = this.gate;
    if (reserved == null &&
        gate != null &&
        spec.surface != SessionSurface.external) {
      final label =
          reused?.title ??
          newSessionTitle(spec.title, typed: spec.titleTyped).title;
      final admission = gate.acquire(
        sessionLaunchClaim(
          kind: kSessionStartLaunchKind,
          priority: priority,
          environmentId: launchDirectory.environmentId,
          installation: installation,
          projectId: repository.projectId,
          label: label,
          sessionId: rowId,
          payload: {
            'spec': spec.toJson(),
            'freshConversationId': ?freshConversationId,
          },
        ),
        startAnyway: startAnyway,
      );
      switch (admission) {
        case LaunchGranted(:final reservation):
          reserved = reservation;
        case LaunchWaiting():
          final row =
              reused ??
              _waitingRow(rowId, spec, repository, installation, label);
          log?.call('Waiting ${row.id}: ${admission.reason}');
          return SessionStarted(session: row, wait: admission.asSessionWait);
      }
    }

    final HostedStart started;
    try {
      started = await launcher.startDetailed(
        HostedLaunch(
          repository: repository,
          installation: installation,
          title: spec.title,
          titleTyped: spec.titleTyped,
          permissionMode: spec.permissionMode,
          modelId: spec.modelId,
          prompt: prompt,
          worktree: spec.worktree,
          worktreeBranch: spec.worktreeBranch,
          worktreeBase: spec.worktreeBase,
          worktreeExistingBranch: spec.worktreeExistingBranch,
          existingWorktree: spec.existingWorktree,

          workingDirectory: workingDirectory,
          recordDirectory: recordDirectory,
          resuming: reused,
          fresh: restarting,
          freshConversationId: restarting ? freshConversationId : null,
          resumeConversationId: restarting ? null : resumeId,
          forkConversationId: spec.forkConversationId,
          parentSessionId: spec.parentSessionId,
          parentLink: spec.parentLink,
          additionalRepositoryIds: spec.additionalRepositoryIds,
          systemPrompt: spec.systemPrompt,
          view: spec.view,
          surface: spec.surface,
          columns: spec.columns,
          rows: spec.rows,
          followSettings: true,
          id: reused == null ? rowId : null,
        ),
      );
    } on Object {
      // A folder made for this launch must not outlive it.
      if (inScratch && freshConversation && reused == null) {
        await discardFailedScratch?.call(repository);
      }
      rethrow;
    } finally {
      reserved?.release();
    }
    final words = [?notice, ?caveat, ?started.attachNotice].join(' ');
    log?.call(
      'Started ${started.session.id}: agent=$agentId '
      'conversation=${resumeId ?? spec.forkConversationId ?? 'new'} '
      'surface=${spec.surface.name} worktree=${spec.worktree}',
    );
    return SessionStarted(
      session: started.session,
      launch: started.launch,
      external: started.external,
      workingDirectoryNotice: words.isEmpty ? null : words,
      credentialNotice: started.credentialNotice,
      depth: spec.parentSessionId == null ? null : depth.depth,
    );
  }

  /// Continues session [sessionId] on its own conversation (a fresh one in
  /// its own row when it never named one), in its own directory and mode.
  /// One already running here is answered as it is. [restart] ends it first.
  /// A resume of a row another resume is still starting waits for that one,
  /// so two callers never start two processes (a boot's automatic continue
  /// and a client reopening the same row).
  Future<SessionStarted> resume(
    String sessionId, {
    bool restart = false,
    String? prompt,
    String? systemPrompt,
    String? freshConversationId,
    int columns = 120,
    int rows = 40,
    LaunchPriority priority = LaunchPriority.interactive,
  }) {
    Future<SessionStarted> now() => _resume(
      sessionId,
      priority: priority,
      restart: restart,
      prompt: prompt,
      systemPrompt: systemPrompt,
      freshConversationId: freshConversationId,
      columns: columns,
      rows: rows,
    );
    final inFlight = _resuming[sessionId];
    final started = inFlight == null
        ? now()
        : inFlight.then((_) => now(), onError: (Object _) => now());
    _resuming[sessionId] = started;
    unawaited(
      started.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_resuming[sessionId], started)) {
          _resuming.remove(sessionId);
        }
      }),
    );
    return started;
  }

  final Map<String, Future<SessionStarted>> _resuming = {};

  Future<SessionStarted> _resume(
    String sessionId, {
    required bool restart,
    required String? prompt,
    required int columns,
    required int rows,
    required LaunchPriority priority,
    String? systemPrompt,
    String? freshConversationId,
  }) async {
    final row =
        sessions.getById(sessionId) ??
        (throw const LaunchTargetMissing('This session no longer exists.'));
    if (restart) {
      final conversation = row.externalSessionId;
      if (conversation == null || conversation.isEmpty) {
        final agent = this.rows.installation(row.agentInstallationId)?.agentId;
        throw StateError(
          '${agent == null ? 'The agent' : agents.nameOf(agent)} has not '
          'named a conversation for this session yet, so restarting it would '
          'open a new conversation instead of continuing this one.',
        );
      }
      await end(sessionId, quietly: true);
    } else if (runsHere(sessionId)) {
      return _adopted(row);
    }
    final conversation = row.externalSessionId;
    final hasConversation = conversation != null && conversation.isNotEmpty;
    return start(
      SessionStartSpec(
        repositoryId: row.repositoryId,
        installationId: row.agentInstallationId,
        title: row.title,
        newSession: !hasConversation,
        resumeConversationId: hasConversation ? conversation : null,
        restartSessionId: hasConversation ? null : row.id,
        existingWorktree: row.worktree,
        workingDirectory: row.workingDirectory,
        prompt: prompt,
        systemPrompt: systemPrompt,
        columns: columns,
        rows: rows,
      ),
      freshConversationId: freshConversationId,
      priority: priority,
    );
  }

  /// Ends the agent behind [sessionId]; the row and transcript stay, and the
  /// ending is recorded as the server's. Throws [LaunchTargetMissing] when
  /// nothing runs it (unless [quietly]).
  Future<void> end(
    String sessionId, {
    bool quietly = false,
    String? reason,
  }) async {
    final hostId = hostSessionIdOf(sessionId);
    final session = registry.findProcess(hostId);
    if (session == null || session.lifecycle.hasEnded) {
      final waiting = gate?.ticketForSession(sessionId);
      if (waiting != null) {
        gate!.cancel(waiting.id);
        return;
      }
      if (quietly) return;
      throw const LaunchTargetMissing(
        'Nothing is running that session, so there is nothing to end.',
      );
    }
    try {
      await registry.close(hostId, reason: reason);
    } on UnknownSession {
      if (quietly) return;
      throw const LaunchTargetMissing(
        'Nothing is running that session, so there is nothing to end.',
      );
    }
  }

  /// The row a new session waits in for a slot: `created`, so it shows and
  /// can be cancelled, and the start that follows fills it in.
  Session _waitingRow(
    String id,
    SessionStartSpec spec,
    Repository repository,
    AgentInstallation installation,
    String title,
  ) {
    final existing = sessions.getById(id);
    if (existing != null) return existing;
    final named = newSessionTitle(spec.title, typed: spec.titleTyped);
    final row = Session(
      id: id,
      repositoryId: repository.id,
      agentInstallationId: installation.id,
      title: named.title,
      titleByUser: named.byUser,
      useWorktree: false,
      status: SessionStatus.created,
      createdAt: DateTime.now().toUtc(),
      surface: spec.surface,
      view: spec.view ?? agents.defaultView(installation.agentId),
      permissionMode: spec.permissionMode,
      modelId: spec.modelId,
      parentSessionId: spec.parentSessionId,
      parentLink: spec.parentSessionId == null
          ? null
          : (spec.parentLink ?? SessionLink.spawn),
    );
    sessions.insertWithPrimaryRepository(row);
    launcher.onRowWritten?.call(id);
    return row;
  }

  /// Starts a launch the gate granted after it waited — after a restart too.
  /// A waiting row that was cancelled or archived meanwhile is left alone.
  Future<void> startGranted(
    LaunchTicket ticket,
    LaunchReservation reservation,
  ) async {
    final raw = ticket.claim.payload['spec'];
    if (raw is! Map) return;
    final spec = SessionStartSpec.fromJson(raw.cast<String, Object?>());
    final rowId = ticket.claim.sessionId;
    final row = rowId == null ? null : sessions.getById(rowId);
    if (row == null || row.isArchived) return;
    final waitingNew = row.status == SessionStatus.created;
    if (!waitingNew && runsHere(row.id)) return;
    try {
      await start(
        spec,
        freshConversationId:
            ticket.claim.payload['freshConversationId'] as String?,
        priority: ticket.claim.priority,
        reservation: reservation,
        waitingRowId: waitingNew ? row.id : null,
      );
    } on Object catch (error) {
      log?.call('Waited launch ${row.id} did not start: $error');
      if (waitingNew) {
        sessions.updateStatus(row.id, SessionStatus.failed);
        launcher.onRowWritten?.call(row.id);
      }
      rethrow;
    }
  }

  /// A wait taken out of line: a new session's waiting row is cancelled.
  void waitCancelled(LaunchTicket ticket) {
    final rowId = ticket.claim.sessionId;
    final row = rowId == null ? null : sessions.getById(rowId);
    if (row == null || row.status != SessionStatus.created) return;
    sessions.updateStatus(row.id, SessionStatus.cancelled);
    launcher.onRowWritten?.call(row.id);
  }

  SessionStarted _adopted(Session row) =>
      SessionStarted(session: row, adopted: true, launch: _storedLaunchOf(row));

  /// What a pane stores for [row]'s running terminal: enough to name its
  /// session and agent; its command line is the server's.
  AgentPaneLaunch? _storedLaunchOf(Session row) {
    final installation = rows.installation(row.agentInstallationId);
    if (installation == null) return null;
    // An ACP session has no terminal for a pane to attach to.
    if (agents.adapterOf(installation.agentId)?.acp != null) return null;
    final directory =
        row.workingDirectory ??
        row.worktree ??
        rows.repository(row.repositoryId)?.path;
    final environment = directory == null
        ? null
        : rows.environment(directory.environmentId);
    return AgentPaneLaunch(
      agentId: installation.agentId,
      executable: installation.executable.path,
      workingDirectory: directory?.path,
      wslDistribution: environment?.kind == EnvironmentKind.wsl
          ? environment?.wslDistribution
          : null,
      sessionId: row.id,
      title: row.title,
    );
  }

  /// The row a resume of [spec]'s conversation would continue, when this
  /// server already runs it: a launch answers that instead.
  Session? _heldRowFor(SessionStartSpec spec, Repository repository) {
    final conversation = spec.resumeConversationId;
    if (conversation == null || conversation.isEmpty) return null;
    for (final candidate in sessions.getAllByExternalSessionId(conversation)) {
      if (candidate.isArchived) continue;
      if (candidate.repositoryId != repository.id) continue;
      if (runsHere(candidate.id)) return candidate;
    }
    return null;
  }

  /// A resume that would be a second agent on a conversation one of ours is
  /// writing, refused where that agent will not share it.
  void _refuseIfForbidden(String agentId, String? conversation) {
    if (conversation == null || conversation.isEmpty) return;
    if (agents.allowsConcurrentResume(agentId)) return;
    for (final other in sessions.getAllByExternalSessionId(conversation)) {
      if (!runsHere(other.id)) continue;
      throw StateError(
        '"${other.title}" is already running in Karmashala. '
        '${resumeBlockedMessage(agents.nameOf(agentId))}',
      );
    }
  }

  /// [installation] with an executable that opens — a stored path is state,
  /// and whether it resolves is a measurement. Only this machine's own paths
  /// are judged here; the sweep Settings runs repairs one that moved.
  Future<AgentInstallation> _usable(AgentInstallation installation) async {
    final reading = _localReading(installation);
    if (reading == null || reading.isUsable) return installation;
    await repairAgents?.call();
    final repaired = rows.installation(installation.id);
    final after = repaired == null ? null : _localReading(repaired);
    if (repaired != null && (after == null || after.isUsable)) {
      log?.call(
        'Repaired ${repaired.agentId} before launching it: '
        '${installation.executable.path} -> ${repaired.executable.path}',
      );
      return repaired;
    }
    throw StateError(
      agentExecutableRefusal(
        agentName: agents.nameOf(installation.agentId),
        path: (repaired ?? installation).executable.path,
        reachability: after?.reachability ?? reading.reachability,
      ),
    );
  }

  ExecutableReading? _localReading(AgentInstallation installation) {
    final environment = rows.environment(installation.environmentId);
    if (environment == null || !isLocalHost(environment.kind)) return null;
    if (!facts.isHere(environment)) return null;
    return readExecutable(
      installation.executable.path,
      pathProbe,
      context: usesWindowsPaths(environment.kind) ? p.windows : p.posix,
    );
  }

  Session? _reusableForResume(
    SessionStartSpec spec,
    Repository repository,
    AgentInstallation installation,
  ) {
    final conversation = spec.resumeConversationId;
    if (conversation == null || conversation.isEmpty) return null;
    if (spec.worktree || spec.parentSessionId != null) return null;
    for (final candidate in sessions.getAllByExternalSessionId(conversation)) {
      if (candidate.isArchived) continue;
      if (candidate.repositoryId != repository.id) continue;
      if (candidate.agentInstallationId != installation.id) continue;
      if (candidate.surface != spec.surface) continue;
      if (runsHere(candidate.id)) continue;
      return candidate;
    }
    return null;
  }

  Session? _reusableForRestart(
    SessionStartSpec spec,
    Repository repository,
    AgentInstallation installation,
  ) {
    final rowId = spec.restartSessionId;
    if (rowId == null || rowId.isEmpty) return null;
    if (spec.worktree || spec.parentSessionId != null) return null;
    final candidate = sessions.getById(rowId);
    if (candidate == null || candidate.isArchived) return null;
    if (candidate.repositoryId != repository.id) return null;
    if (candidate.agentInstallationId != installation.id) return null;
    if (runsHere(candidate.id)) return null;
    return candidate;
  }

  /// The conversation [spec] can actually resume, and the row to continue: a
  /// row pointed at a conversation its agent never wrote goes back to the one
  /// named after it — its own, from launch — and the row is repaired. Null
  /// leaves the launch as asked ("could not tell" goes ahead). Throws when
  /// the store was read to the end and holds neither.
  Future<({String conversationId, Session? row})?> _conversationToResume(
    SessionStartSpec spec,
    AgentInstallation installation,
    Repository repository,
    Session? reused,
  ) async {
    final conversation = spec.resumeConversationId;
    final presence = presenceOf;
    if (conversation == null || conversation.isEmpty || presence == null) {
      return null;
    }
    final agentId = installation.agentId;
    if (!agents.assignsOwnSessionId(agentId)) return null;
    final existing = sessions.getById(conversation);
    final minted =
        existing != null && existing.externalSessionId == conversation
        ? existing
        : null;
    final row = minted ?? reused;
    if (row == null || row.isArchived) return null;
    if (await presence(agentId, conversation) != ConversationPresence.absent) {
      return null;
    }
    final name = agents.nameOf(agentId);
    if (minted == null) {
      final holder = sessions.getByExternalSessionId(row.id);
      if ((holder == null || holder.id == row.id) &&
          await presence(agentId, row.id) == ConversationPresence.present) {
        _refuseIfForbidden(agentId, row.id);
        sessions.updateExternalSessionId(row.id, row.id);
        log?.call(
          'Session ${row.id} named conversation $conversation, which $name '
          'has no record of; resuming its own conversation ${row.id} instead '
          'and repairing the row.',
        );
        return (conversationId: row.id, row: sessions.getById(row.id) ?? row);
      }
      throw StateError(
        '"${row.title}" cannot be resumed: '
        '${resumeLostConversationMessage(name)} '
        '(conversation id $conversation)',
      );
    }
    throw StateError(
      '"${minted.title}" cannot be resumed: '
      '${resumeMissingConversationMessage(name)} '
      '(conversation id $conversation)',
    );
  }

  String? _elsewhereCaveat(
    String agentId,
    String? conversation,
    EnvironmentPath launchDirectory,
  ) {
    if (conversation == null || conversation.isEmpty) return null;
    final holder = sessions.getByExternalSessionId(conversation);
    final recorded = holder?.workingDirectory ?? holder?.worktree;
    if (recorded == null) return null;
    return resumeDirectoryCaveatFor(
      registryOfAgents,
      agentId,
      conversation,
      recordedDirectory: recorded.path,
      launchDirectory: launchDirectory.path,
    );
  }

  /// [trustScratchFolder] for [folder], never failing the launch: an agent
  /// that still asks about the folder is a prompt, not a refusal.
  /// Whether [folder]'s instruction files reach [installation]'s agent: it
  /// reads only files a scratch folder is given, and they were written.
  Future<bool> _instructScratch(
    AgentInstallation installation,
    EnvironmentPath folder,
  ) async {
    final write = writeScratchInstructions;
    final declared = registryOfAgents
        .byId(installation.agentId)
        ?.instructionFiles;
    if (write == null || declared == null || !scratchFilesCover(declared)) {
      return false;
    }
    final written = await write(folder);
    if (!written) {
      log?.call(
        '${folder.path} has no instruction files; telling the agent in '
        'its first message',
      );
    }
    return written;
  }

  Future<void> _trustScratch(
    AgentInstallation installation,
    EnvironmentPath folder,
  ) async {
    final trust = trustScratchFolder;
    if (trust == null) return;
    try {
      await trust(installation, folder);
    } on Object catch (error) {
      log?.call(
        '${folder.path} could not be marked trusted for '
        '${installation.agentId}: $error',
      );
    }
  }

  bool _present(EnvironmentPath directory) {
    final probe = directoryPresent;
    if (probe != null) return probe(directory);
    final environment = rows.environment(directory.environmentId);
    // Another machine's disk says nothing here: "could not tell" is present.
    if (environment == null || !facts.isHere(environment)) return true;
    if (environment.kind == EnvironmentKind.wsl) return true;
    try {
      return Directory(directory.path).existsSync();
    } on Object {
      return true;
    }
  }
}
