import 'package:riverpod/riverpod.dart';

import '../agents/application/agent_providers.dart';
import '../agents/application/agent_usage_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import '../checkpoints/application/checkpoint_fork.dart';
import '../checkpoints/application/checkpoint_providers.dart';
import '../checkpoints/application/checkpoint_service.dart';
import '../checkpoints/domain/checkpoint.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../environments/application/environment_providers.dart';
import '../explorer/application/checkout.dart';
import '../projects/application/projects_controller.dart';
import '../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../sessions/application/session_handoff_service.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/application/session_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
import '../terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'agent_lookup.dart';

/// Starting a session, and continuing one somewhere else. [SessionControlTools]
/// is the other half: talking to one that already runs, and ending it.
class SessionLaunchTools {
  SessionLaunchTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// Which session is calling, when one is: what a session started here is
  /// recorded as a child of, and it comes from the transport, never an argument.
  final String? callerSessionId;

  static const Set<String> _names = <String>{
    'open_new_session',
    'get_usage',
    'open_session',
    'session_handoff',
    'session_fork',
    'session_fork_from_checkpoint',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'open_new_session' => _openNewSession(
          projectId: args['projectId'] as String?,
          cli: args['cli'] as String?,
          agentInstallationId: args['agentInstallationId'] as String?,
          repositoryId: args['repositoryId'] as String?,
          title: args['title'] as String?,
          prompt: args['prompt'] as String?,
          useWorktree: args['useWorktree'] == true,
          permissionMode: args['permissionMode'] as String?,
          callerSessionId: callerSessionId,
        ),
        'get_usage' => _getUsage(
          cli: args['cli'] as String?,
          environmentId: args['environmentId'] as String?,
        ),
        'open_session' => _openSession(args['id'] as String?),
        'session_handoff' => _sessionHandoff(
          sessionId: args['sessionId'] as String?,
          cli: args['cli'] as String?,
          agentInstallationId: args['agentInstallationId'] as String?,
          instruction: args['instruction'] as String?,
          unresolvedTasks: (args['unresolved'] as List?)
              ?.whereType<String>()
              .toList(),
          newWorktree: args['newWorktree'] == true,
          preview: args['preview'] == true,
        ),
        'session_fork' => _sessionFork(
          sessionId: args['sessionId'] as String?,
          instruction: args['instruction'] as String?,
          newWorktree: args['newWorktree'] == true,
          preview: args['preview'] == true,
        ),
        // Named, never defaulted to the caller: this one rewrites files, and a
        // destructive verb must not pick its own target from an omission.
        'session_fork_from_checkpoint' => _sessionForkFromCheckpoint(
          sessionId: args['sessionId'] as String?,
          checkpointId: args['checkpointId'] as String?,
          turn: (args['turn'] as num?)?.round(),
          instruction: args['instruction'] as String?,
          newWorktree: args['newWorktree'] == true,
          confirm: args['confirm'] == true,
          preview: args['preview'] == true,
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// The permission a caller named, as a [PermissionRisk] rung because a fixed
  /// schema cannot name one agent's vocabulary. An unknown name is refused.
  PermissionSelection? _parsePermissionMode(String? raw, String agentId) {
    if (raw == null || raw.trim().isEmpty) return null;
    final wanted = raw.trim();
    final descriptor = _container.read(agentRegistryProvider).byId(agentId);
    final support = descriptor?.launch.permission;
    final risk = PermissionRisk.byName(wanted);
    if (risk != null) {
      return carryPermission(risk, descriptor).selection;
    }
    // An exact mode in this agent's own vocabulary.
    if (support != null && support.isKnown) {
      for (final selection in support.selections()) {
        if (selection.canonical == wanted) return selection;
      }
    }
    throw ArgumentError(
      'Unknown permissionMode "$raw" for $agentId. One of: '
      '${PermissionRisk.values.map((m) => m.name).join(', ')}'
      '${support != null && support.isKnown ? ', or one of '
                '${support.selections().map((s) => s.canonical).join(', ')}' : ''}.',
    );
  }

  Future<Object?> _openNewSession({
    String? projectId,
    String? cli,
    String? agentInstallationId,
    String? repositoryId,
    String? title,
    String? prompt,
    bool useWorktree = false,
    String? permissionMode,
    String? callerSessionId,
  }) async {
    if (projectId == null) throw ArgumentError('Missing projectId.');
    final repos = _container
        .read(repositoryDaoProvider)
        .getByProject(projectId);
    Repository repo;
    if (repositoryId != null) {
      repo = repos.firstWhere(
        (r) => r.id == repositoryId,
        orElse: () => throw StateError('Repository not found in this project.'),
      );
    } else {
      // Nothing recorded is not nowhere to run: a project runs in its own
      // folder when no checkout was ever discovered under it, git or not.
      repo =
          repos.firstOrNull ??
          _container
              .read(projectsControllerProvider.notifier)
              .ensureRunLocation(projectId);
    }

    final installs = _container
        .read(agentInstallationDaoProvider)
        .getByEnvironment(repo.path.environmentId);
    if (installs.isEmpty) {
      throw StateError('No agent is installed in ${repo.path.environmentId}.');
    }
    AgentInstallation? install;
    if (agentInstallationId != null) {
      for (final i in installs) {
        if (i.id == agentInstallationId) {
          install = i;
          break;
        }
      }
      if (install == null) {
        throw StateError(
          'That agent installation is not available in this project.',
        );
      }
    } else if (cli != null) {
      final agentId = parseCli(_container, cli);
      for (final i in installs) {
        if (i.agentId == agentId) {
          install = i;
          break;
        }
      }
      if (install == null) {
        throw StateError(
          '$cli is not installed in ${repo.path.environmentId}.',
        );
      }
    } else {
      // The launcher's resolution, so "the default agent" means the same thing
      // here as it does in the New-session dialog.
      install =
          _container
              .read(sessionLauncherProvider)
              .defaultInstallationIn(repo.path.environmentId) ??
          installs.first;
    }

    // Through the one launcher, exactly as the New-session dialog is, so an
    // agent's session is an ordinary row; the spawn-depth cap applies here.
    final launcher = _container.read(sessionLauncherProvider);
    try {
      final launched = await launcher.launch(
        SessionLaunchRequest(
          repository: repo,
          installation: install,
          title: (title == null || title.trim().isEmpty)
              ? 'Agent session'
              : title.trim(),
          purpose: SessionPurpose.newSession,
          useWorktree: useWorktree,
          firstMessage: prompt,
          parentSessionId: callerSessionId,
          permissionOverride: _parsePermissionMode(
            permissionMode,
            install.agentId,
          ),
        ),
      );
      return {
        'sessionId': launched.session.id,
        'opened': 'new ${install.agentId} session',
        'title': launched.session.title,
        'repository': repo.name,
        'environmentId': repo.path.environmentId,
        'depth': launcher.depthForChildOf(callerSessionId).depth,
        'permissionMode': launched.session.permissionMode ?? 'not recorded',
        if (launched.session.worktree != null)
          'worktree': launched.session.worktree!.path,
      };
    } on SessionDepthRefused catch (refused) {
      // Fail the caller's turn with the reason, rather than with a generic
      // error it might reasonably retry.
      throw StateError(refused.depth.refusal);
    }
  }

  /// Continues [sessionId] in another agent. Thin on purpose — every decision
  /// belongs to `SessionHandoffService` — except `preview`, which a model needs.
  Future<Object?> _sessionHandoff({
    String? sessionId,
    String? cli,
    String? agentInstallationId,
    String? instruction,
    List<String>? unresolvedTasks,
    bool newWorktree = false,
    bool preview = false,
  }) async {
    if (sessionId == null) throw ArgumentError('Missing sessionId.');
    if (instruction == null || instruction.trim().isEmpty) {
      throw ArgumentError(
        'Missing instruction. The packet carries the conversation; the '
        'instruction is the part it cannot infer.',
      );
    }
    final service = _container.read(sessionHandoffServiceProvider);
    final targets = service.targetsFor(sessionId);
    if (targets.isEmpty) {
      throw StateError(
        'No agent is installed in that session\'s environment, or the session '
        'no longer exists.',
      );
    }
    final target = _handoffTarget(targets, cli, agentInstallationId);
    if (!target.canReceive) throw StateError(target.refusal!);

    if (preview) {
      final packet = await service.buildPacket(
        sessionId: sessionId,
        targetAgentName: target.agentName,
        instruction: instruction,
        unresolvedTasks: unresolvedTasks ?? const [],
      );
      return {
        'preview': true,
        'target': target.agentName,
        'permissionMode': target.permission.selection.canonical,
        'permission': target.permission.summary,
        'packet': packet.render(),
      };
    }

    final launched = await service.handoffTo(
      sessionId: sessionId,
      targetInstallationId: target.installation.id,
      instruction: instruction,
      unresolvedTasks: unresolvedTasks ?? const [],
      intoNewWorktree: newWorktree,
    );
    return {
      'sessionId': launched.session.id,
      'title': launched.session.title,
      'target': target.agentName,
      'parentSessionId': sessionId,
      'link': SessionLink.handoff.name,
      'permissionMode': target.permission.selection.canonical,
      'permission': target.permission.summary,
      if (launched.session.worktree != null)
        'worktree': launched.session.worktree!.path,
    };
  }

  /// Picks the target the caller named, preferring an installation id over a CLI
  /// name. Never falls back: the wrong provider is not a smaller right one.
  HandoffTarget _handoffTarget(
    List<HandoffTarget> targets,
    String? cli,
    String? agentInstallationId,
  ) {
    if (agentInstallationId != null) {
      for (final target in targets) {
        if (target.installation.id == agentInstallationId) return target;
      }
      throw StateError(
        'That agent installation is not available for this session.',
      );
    }
    if (cli != null) {
      final agentId = parseCli(_container, cli);
      for (final target in targets) {
        if (target.installation.agentId == agentId) return target;
      }
      throw StateError('$cli is not installed in that session\'s environment.');
    }
    // No preference stated: the first agent that is *not* the one already
    // running it, because "continue with another agent" is what was asked for.
    for (final target in targets) {
      if (!target.isSameAgent && target.canReceive) return target;
    }
    return targets.first;
  }

  Future<Object?> _sessionFork({
    String? sessionId,
    String? instruction,
    bool newWorktree = false,
    bool preview = false,
  }) async {
    if (sessionId == null) throw ArgumentError('Missing sessionId.');
    final service = _container.read(sessionHandoffServiceProvider);
    final plan = service.forkPlanFor(sessionId);
    if (preview) {
      return {
        'preview': true,
        'route': plan.kind.name,
        'explanation': plan.explanation,
      };
    }
    if (plan.isRefused) throw StateError(plan.explanation);

    final launched = await service.forkSession(
      sessionId: sessionId,
      instruction: instruction ?? '',
      intoNewWorktree: newWorktree,
    );
    return {
      'sessionId': launched.session.id,
      'title': launched.session.title,
      'parentSessionId': sessionId,
      'link': SessionLink.fork.name,
      // Said plainly, because the two are not equivalent: a native fork shares
      // the agent's own record, a handoff carries a written recap of it.
      'route': plan.kind.name,
      'explanation': plan.explanation,
      if (launched.session.worktree != null)
        'worktree': launched.session.worktree!.path,
    };
  }

  /// Forks a session **and** puts its working tree back to a checkpoint. The
  /// two halves are independent, and the answer names each one separately
  /// rather than reporting a fork that only half happened.
  Future<Object?> _sessionForkFromCheckpoint({
    String? sessionId,
    String? checkpointId,
    int? turn,
    String? instruction,
    bool newWorktree = false,
    bool confirm = false,
    bool preview = false,
  }) async {
    if (sessionId == null) throw ArgumentError('Missing sessionId.');
    final checkpoints = _container.read(checkpointServiceProvider);
    final checkpoint = _forkCheckpoint(
      checkpoints,
      sessionId: sessionId,
      checkpointId: checkpointId,
      turn: turn,
    );

    final handoff = _container.read(sessionHandoffServiceProvider);
    final plan = handoff.forkPlanFor(sessionId);
    final others = _sessionsSharing(checkpoint.repository, sessionId);
    final fileRefusal = checkpointForkFileRefusal(
      intoNewWorktree: newWorktree,
      unsupportedEnvironmentReason: checkpoints.unsupportedReason(
        checkpoint.repository,
      ),
      otherSessionsInCheckout: others,
    );

    if (preview) {
      return {
        'preview': true,
        'route': plan.kind.name,
        'explanation': plan.explanation,
        'checkpoint': _forkCheckpointJson(checkpoint),
        'conversation': _forkConversationJson(),
        'files': {
          'wouldRestore': fileRefusal == null,
          'repository': checkpoint.repository.path,
          'reason': ?fileRefusal,
        },
      };
    }
    if (plan.isRefused) throw StateError(plan.explanation);

    // The files first: a refusal here must not leave a session behind, and the
    // fork is meant to start in the tree it was asked for.
    RestoreOutcome? restored;
    if (fileRefusal == null) {
      try {
        restored = await checkpoints.restore(checkpoint, confirm: confirm);
      } on CheckpointConflict catch (conflict) {
        throw StateError(
          '${conflict.message} Nothing was changed and no session was '
          'started. The current working tree is saved as checkpoint '
          '${conflict.safetyCheckpoint?.id}.',
        );
      }
      _container.read(checkpointsRevisionProvider.notifier).bump();
    }

    final launched = await handoff.forkSession(
      sessionId: sessionId,
      instruction: instruction ?? '',
      intoNewWorktree: newWorktree,
    );

    final halves = checkpointForkHalves(
      route: plan.kind.name,
      checkpoint: checkpoint,
      fileRefusal: fileRefusal,
      alreadyThere: restored?.alreadyThere,
      restoredFiles: restored?.files.length ?? 0,
    );
    return {
      'sessionId': launched.session.id,
      'title': launched.session.title,
      'parentSessionId': sessionId,
      'link': SessionLink.fork.name,
      'route': plan.kind.name,
      'explanation': plan.explanation,
      'checkpoint': _forkCheckpointJson(checkpoint),
      // Both halves, always both keys: a caller reading one of them must not
      // have to infer the other from what is missing.
      'delivered': halves.delivered,
      'notDelivered': halves.notDelivered,
      'conversation': _forkConversationJson(),
      'files': {
        'restored': restored != null && !restored.alreadyThere,
        'repository': checkpoint.repository.path,
        'reason': ?fileRefusal,
        if (restored != null) ...{
          'alreadyThere': restored.alreadyThere,
          'safetyCheckpointId': restored.safetyCheckpoint?.id,
          'paths': [
            for (final file in restored.files)
              {'path': file.path, 'status': file.type.name},
          ],
        },
      },
      if (launched.session.worktree != null)
        'worktree': launched.session.worktree!.path,
    };
  }

  /// The checkpoint the caller named, by id or by turn. Refuses rather than
  /// guessing: a checkpoint of another session is not a smaller right answer.
  Checkpoint _forkCheckpoint(
    CheckpointService service, {
    required String sessionId,
    String? checkpointId,
    int? turn,
  }) {
    if ((checkpointId == null) == (turn == null)) {
      throw ArgumentError(
        'Name exactly one of checkpointId or turn. checkpoint_list shows both.',
      );
    }
    if (checkpointId != null) {
      final checkpoint = service.byId(checkpointId);
      if (checkpoint == null) {
        throw StateError('No checkpoint with id $checkpointId.');
      }
      if (checkpoint.sessionId != sessionId) {
        throw StateError(
          'Checkpoint $checkpointId belongs to session '
          '${checkpoint.sessionId}, not $sessionId.',
        );
      }
      return checkpoint;
    }
    final chain = service.forSession(sessionId);
    final checkpoint = checkpointAtTurn(chain, turn!);
    if (checkpoint == null) {
      final available = forkableTurns(chain);
      throw StateError(
        available.isEmpty
            ? 'That session has no checkpoint recorded against a turn, so '
                  'there is no turn to fork from. Name a checkpointId from '
                  'checkpoint_list instead.'
            : 'That session has no checkpoint for turn $turn. It has turns '
                  '${available.join(', ')}.',
      );
    }
    return checkpoint;
  }

  /// The **other** sessions recorded as working in [repository]. Empty is not a
  /// promise of solitude — only a worktree is that — but a non-empty answer is
  /// a directory this call must not rewrite.
  List<String> _sessionsSharing(EnvironmentPath repository, String sessionId) =>
      [
        for (final session in sessionsWorkingIn(
          repository,
          excluding: sessionId,
          among: _container.read(sessionDaoProvider).getAll(),
          pathsMatch: samePath,
        ))
          session.title,
      ];

  Map<String, Object?> _forkCheckpointJson(Checkpoint checkpoint) => {
    'id': checkpoint.id,
    'sequence': checkpoint.sequence,
    'turn': checkpoint.turn,
    'reason': checkpoint.reason.name,
    'label': checkpoint.label,
    'prompt': checkpoint.prompt,
    'createdAt': checkpoint.createdAt.toIso8601String(),
    'repository': checkpoint.repository.path,
    'environmentId': checkpoint.repository.environmentId,
  };

  /// Constant on purpose: there is no route here that rewinds a conversation,
  /// so this key can never come back saying one was.
  Map<String, Object?> _forkConversationJson() => {
    'carried': 'whole',
    'rewoundToTurn': false,
    'note': kForkCarriesTheWholeConversation,
  };

  Future<Object?> _getUsage({String? cli, String? environmentId}) async {
    final agentId = parseCli(_container, cli) ?? AgentIds.claudeCode;
    final install = installFor(_container, agentId, environmentId);
    if (install == null) {
      throw StateError('No $agentId installation found.');
    }
    final environments = _container
        .read(executionEnvironmentDaoProvider)
        .getAll();
    final usage = await _container
        .read(agentUsageServiceProvider)
        .fetch(install, environments);
    // **A window with no reading omits `percent` entirely.** Antigravity's
    // `loadCodeAssist` names tiers and measures nothing; a `0` would be acted on.
    return {
      'environmentId': install.environmentId,
      'windows': [
        for (final w in usage.windows)
          {
            'label': w.label,
            if (w.percent != null) 'percent': w.percent,
            if (w.resetsAt != null) 'resetsAt': w.resetsAt!.toIso8601String(),
          },
      ],
      if (usage.tokenExpiresAt != null)
        'tokenExpiresAt': usage.tokenExpiresAt!.toIso8601String(),
      'fetchedAt': usage.fetchedAt.toIso8601String(),
    };
  }

  Future<Object?> _openSession(String? id) async {
    if (id == null) throw ArgumentError('Missing session id.');

    // A native session is reattached, not relaunched: if a pane is still running
    // it, "open" means bring its tab back.
    final native = _container.read(sessionDaoProvider).getById(id);
    if (native != null) return _openNativeSession(native);

    final session = _container.read(importedSessionDaoProvider).getById(id);
    if (session == null) throw StateError('Session not found: $id');
    // An imported entry can name a conversation one of our own panes is still
    // running: open that, rather than putting a second agent on it.
    final launcher = _container.read(sessionLauncherProvider);
    final running = launcher.runningSessionWithExternalId(session.externalId);
    if (running != null && launcher.reveal(running.id)) {
      return {
        'opened': running.title,
        'sessionId': running.id,
        'reattached': true,
      };
    }
    final repo = _container
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    final env = _container
        .read(executionEnvironmentDaoProvider)
        .getById(session.environmentId);
    final install = installFor(_container, session.cli, session.environmentId);
    if (repo == null || env == null || install == null) {
      throw StateError('Session repository, environment, or agent is missing.');
    }
    // Before the terminal is even resolved: with no guard here, a resume the
    // builder could not express opened a *new* conversation and reported success.
    final refusal = resumeRefusalFor(
      _container.read(agentRegistryProvider),
      session.cli,
      session.externalId,
    );
    if (refusal != null) throw StateError(refusal);
    final terminal = await _container.read(
      defaultSystemTerminalProvider.future,
    );
    if (terminal == null) {
      throw StateError('No external terminal is configured.');
    }
    final command = resumeCommandLine(
      agentExecutable: install.executable.path,
      cli: session.cli,
      externalId: session.externalId,
      environment: env,
      cwd: repo.path,
      permission: resumePermissionFor(_container, session.cli),
      registry: _container.read(agentRegistryProvider),
    );
    await _container
        .read(systemTerminalServiceProvider)
        .launch(
          terminal,
          command: command,
          workingDirectory: env.wslDistribution == null ? repo.path.path : null,
        );
    // Named in the answer, because the caller cannot see the desktop: this is
    // the branch that opened a window, and an automated caller cannot undo it.
    return {
      'opened': session.displayTitle,
      'environmentId': env.id,
      'externalTerminal': terminal.label,
      'note': 'Opened a new external terminal window. Close it yourself.',
    };
  }

  Future<Object?> _openNativeSession(Session session) async {
    // The launcher owns "is it already running, and where" for every surface —
    // every other resume path used to relaunch a session that never stopped.
    if (_container.read(sessionLauncherProvider).reveal(session.id)) {
      return {
        'opened': session.title,
        'sessionId': session.id,
        'reattached': true,
      };
    }

    final repo = _container
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    final install = _container
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (repo == null || install == null) {
      throw StateError('Session repository or agent is missing.');
    }
    final launched = await _container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repo,
            installation: install,
            title: session.title,
            purpose: SessionPurpose.existingSession,
            resumeExternalSessionId: session.externalSessionId,
          ),
        );
    return {
      'opened': launched.session.title,
      'sessionId': launched.session.id,
      'reattached': false,
      // A directory that has gone resumes the agent at the repository root, and
      // its store is keyed by directory — hence an otherwise empty conversation.
      'note': ?launched.workingDirectoryNotice,
    };
  }
}

/// The schemas for the tools in [SessionLaunchTools] that start or reopen a
/// session. Two lists, because the served order is a contract the golden holds.
const List<Map<String, dynamic>> sessionLaunchToolSchemas = [
  {
    'name': 'open_new_session',
    'description':
        'Start a NEW agent session (not a resume) in a project, as a terminal '
        'tab in Karmashala. Choose the agent with agentInstallationId (from '
        'list_agents) or cli ("claude"/"codex"); omit both to use the '
        "configured default. repositoryId is optional (defaults to the "
        "project's first repository). The agent must be installed in the "
        "project's environment. Sessions you start this way are recorded as "
        'your children, and nesting is capped: if the call is refused for '
        'depth, do the work yourself instead of delegating it further.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {
          'type': 'string',
          'description': 'Project id from list_projects.',
        },
        'cli': {
          'type': 'string',
          'description': 'Agent CLI to use: "claude" or "codex".',
        },
        'agentInstallationId': {
          'type': 'string',
          'description': 'Specific installation id from list_agents.',
        },
        'repositoryId': {'type': 'string'},
        'title': {
          'type': 'string',
          'description': 'Short name for the session, shown in the tab.',
        },
        'prompt': {
          'type': 'string',
          'description':
              'Opening instruction for the new agent. Sent as its first '
              'message, prefixed with a line naming this session.',
        },
        'useWorktree': {
          'type': 'boolean',
          'description':
              'Run in a dedicated Git worktree instead of the repository '
              'itself. Use this when the new session will edit files and you '
              'are still working in the same repository.',
        },
        'permissionMode': {
          'type': 'string',
          'enum': permissionRiskNames,
          'description':
              'How much the new agent may do without asking, on the scale '
              'every agent shares. The chosen agent is given the closest '
              'mode it really has, never one it does not — Codex, for '
              'instance, has nothing at "ask". Omit to use the mode '
              'configured in Settings, which is what the New-session dialog '
              'does. "bypass" skips every prompt and is never a default; ask '
              'the user before choosing it for them.',
        },
      },
      'required': ['projectId'],
    },
  },
  {
    'name': 'get_usage',
    'description':
        'An agent account\'s usage against its limits, read live. cli is '
        '"claude", "codex" or "antigravity"; environmentId is optional '
        '(defaults to the first matching installation). Each window carries a '
        'label and, when the agent reported one, a "percent" used and a '
        '"resetsAt". A window with no "percent" was not measured — '
        'Antigravity names the account\'s tiers and reports no quota against '
        'them — and that absence means unknown, never zero. "fetchedAt" is '
        'when the reading was taken.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'cli': {'type': 'string'},
        'environmentId': {'type': 'string'},
      },
      'required': ['cli'],
    },
  },
  {
    'name': 'open_session',
    'description':
        'Open one session by its id. A Karmashala session that is still '
        'running is reattached to a tab; anything else is resumed. An '
        'imported CLI session opens a new external terminal window every '
        'time this is called, and nothing here closes one — do not call it '
        'over a list of sessions.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'Session id from list_sessions.',
        },
      },
      'required': ['id'],
    },
  },
];

/// The schemas for continuing a session somewhere else.
const List<Map<String, dynamic>> sessionHandoffToolSchemas = [
  {
    'name': 'session_handoff',
    'description':
        'Continue an existing session in a different agent. Builds a handoff '
        'packet from that session — a quoted recap of its conversation, the '
        'files changed in the working tree, the current branch, anything '
        'listed as unresolved, and your instruction — and starts a new '
        'session with the packet as its first message, in the SAME worktree '
        'and on the SAME branch by default. The packet states its '
        'provenance: the new agent is told the conversation is not its own. '
        'The original session is left running and untouched; ending it is '
        'the user\'s decision. Use preview:true to read the packet without '
        'starting anything.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Session id from list_sessions (kind "native").',
        },
        'cli': {
          'type': 'string',
          'description':
              'Agent to continue in: "claude" or "codex". Ignored when '
              'agentInstallationId is given.',
        },
        'agentInstallationId': {
          'type': 'string',
          'description': 'Specific installation id from list_agents.',
        },
        'instruction': {
          'type': 'string',
          'description':
              'What the receiving agent should do. Required: the packet '
              'carries the conversation, this is the part it cannot infer.',
        },
        'unresolved': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Work still open, listed for the new agent.',
        },
        'newWorktree': {
          'type': 'boolean',
          'description':
              'Start in a fresh Git worktree instead of continuing in the '
              'same one. Default false, which is what a handoff usually '
              'wants.',
        },
        'preview': {
          'type': 'boolean',
          'description':
              'Return the packet without starting anything. Read it before '
              'handing over work you care about.',
        },
      },
      'required': ['sessionId', 'instruction'],
    },
  },
  {
    'name': 'session_fork',
    'description':
        'Branch a session into a new one that shares its history up to now '
        'and then diverges. Runs the SAME agent — a fork is a branch of one '
        'conversation, not a change of provider. Uses the CLI\'s own fork '
        'when it has one and Karmashala knows the conversation id; '
        'otherwise it falls back to a handoff packet, and the result says '
        'which happened. The original session is untouched. Use preview:true '
        'to see which route would be taken before committing to it.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Session id from list_sessions (kind "native").',
        },
        'instruction': {
          'type': 'string',
          'description':
              'Optional opening message for the branch. Leave it out to fork '
              'and wait.',
        },
        'newWorktree': {
          'type': 'boolean',
          'description':
              'Fork into a fresh Git worktree so the two branches do not '
              'edit the same files. Default false.',
        },
        'preview': {
          'type': 'boolean',
          'description': 'Report the plan without starting anything.',
        },
      },
      'required': ['sessionId'],
    },
  },
  {
    'name': 'session_fork_from_checkpoint',
    'description':
        'Fork a session AND put its working tree back to one of its '
        'checkpoints, named by checkpointId or by turn. TWO HALVES, and only '
        'one of them is a rewind: the files go back to the checkpoint, and '
        'the CONVERSATION IS CARRIED WHOLE — no agent CLI here can resume a '
        'conversation at a turn, so the fork still remembers everything said '
        'after that point, including edits the files no longer hold. Say what '
        'you rolled back in "instruction". The result lists "delivered" and '
        '"notDelivered" separately and never claims a half it did not do. '
        'DESTRUCTIVE on the file half: it discards edits made since that '
        'checkpoint, exactly as checkpoint_restore does, taking a safety '
        'checkpoint first and refusing a tree that has moved unless "confirm" '
        'is true. It refuses the file half outright — and says so rather than '
        'failing — when another session is working in that checkout, when the '
        'repository cannot be checkpointed from here, or when newWorktree is '
        'true, because a checkpoint restores only into the checkout it was '
        'taken in. Use preview:true to read both decisions before committing.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description':
              'Session to fork, from list_sessions (kind "native"). Named, '
              'never defaulted to you: this one rewrites files.',
        },
        'checkpointId': {
          'type': 'string',
          'description':
              'Checkpoint id from checkpoint_list. Name this or "turn", not '
              'both. It must belong to the session being forked.',
        },
        'turn': {
          'type': 'number',
          'description':
              'Fork from the state that turn began in — the turnStart '
              'checkpoint of that turn, or the earliest one recorded for it.',
        },
        'instruction': {
          'type': 'string',
          'description':
              'Opening message for the fork. This is where the fork learns '
              'what was rolled back; it cannot tell from its own memory.',
        },
        'newWorktree': {
          'type': 'boolean',
          'description':
              'Fork into a fresh Git worktree. Default false. True gives the '
              'branches separate files and gives up the restore: the worktree '
              'is a fresh checkout of the branch, not the checkpoint.',
        },
        'confirm': {
          'type': 'boolean',
          'description':
              'Restore even though the working tree has moved since the last '
              'checkpoint. Requires the user to have said so.',
        },
        'preview': {
          'type': 'boolean',
          'description':
              'Report both halves without starting anything and without '
              'touching a file.',
        },
      },
      'required': ['sessionId'],
    },
  },
];
