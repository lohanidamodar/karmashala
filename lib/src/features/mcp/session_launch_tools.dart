import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agents/application/agent_providers.dart';
import '../agents/application/agent_usage_providers.dart';
import '../agents/domain/agent_ids.dart';
import '../agents/domain/agent_installation.dart';
import '../agents/domain/agent_permission_support.dart';
import '../agents/domain/permission_carry.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../environments/application/environment_providers.dart';
import '../repositories/application/repository_providers.dart';
import '../repositories/domain/repository.dart';
import '../sessions/application/session_handoff_service.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/domain/session.dart';
import '../sessions/domain/session_launch.dart';
import '../sessions/domain/session_lineage.dart';
import '../settings/domain/permission_risk.dart';
import '../terminal/application/system_terminal_providers.dart';
import '../terminal/data/system_terminal_service.dart';
import 'agent_lookup.dart';

/// Starting a session, and continuing one somewhere else.
///
/// The other half of the session family — talking to a session that already
/// runs, and ending it — is [SessionControlTools] in `session_tools.dart`.
/// These stayed in `LauncherControlServer` longest because they were there
/// first; they are here for the reason every other family moved out, which is
/// that the server's job is the transport and the boundary, and a family's only
/// tie to it is the container it reads providers from. They did not go into
/// `session_tools.dart` because that file is already 800 lines of a different
/// question.
///
/// `get_usage` is here rather than with the inventory reads: it is not a read
/// of what Karmashala knows but a live fetch from the agent, and its caller is
/// somebody deciding whether that agent has the budget to be handed the work.
class SessionLaunchTools {
  SessionLaunchTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// Which session is calling, when one is. It is what a session started here
  /// is recorded as a child of, so the spawn-depth cap counts a real chain —
  /// and it comes from the transport, never from an argument.
  final String? callerSessionId;

  static const Set<String> _names = <String>{
    'open_new_session',
    'get_usage',
    'open_session',
    'session_handoff',
    'session_fork',
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
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// The permission named by a caller, or null to let the setting decide.
  ///
  /// This is the one **agent-agnostic** permission surface left: an MCP tool's
  /// schema is fixed when the server starts and cannot name one agent's
  /// vocabulary. So it takes a [PermissionRisk] rung — the cross-agent scale —
  /// and the caller's chosen agent decides what that means, through the same
  /// carry rule a handoff uses. A caller that knows the exact mode may name it
  /// instead, and gets it verbatim.
  ///
  /// Refuses an unknown name rather than falling back to a default: a typo
  /// silently becoming "ask" would look like the tool worked, and a typo
  /// silently becoming anything else would be worse.
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
    if (repos.isEmpty) {
      throw StateError('This project has no repositories to run in.');
    }
    Repository repo;
    if (repositoryId != null) {
      repo = repos.firstWhere(
        (r) => r.id == repositoryId,
        orElse: () => throw StateError('Repository not found in this project.'),
      );
    } else {
      repo = repos.first;
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

    // Through the one launcher, exactly as the New-session dialog is. A session
    // an agent starts is not a second kind of session: same row, same PTY, same
    // permission resolution, same worktree option — and, because it has a row,
    // it is visible to `list_sessions` and reattachable, which a spawned
    // external terminal never was.
    //
    // This is also where the spawn-depth cap applies. `callerSessionId` comes
    // from the bridge's environment, not from the model.
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

  /// Continues [sessionId] in another agent.
  ///
  /// The tool is deliberately thin: every decision — which targets exist,
  /// whether one can be told anything, what the permission mode becomes, what
  /// the packet says — belongs to `SessionHandoffService`, so an agent asking
  /// for a handoff and a user clicking one get the same answer. What is added
  /// here is `preview`, because a model that cannot see the dialog needs some
  /// way to read the packet before spending another agent's first turn on it.
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

  /// Picks the target the caller named, preferring an explicit installation id
  /// over a CLI name. Never falls back to "some other agent": a handoff aimed
  /// at the wrong provider is not a smaller version of the right one.
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
    return {
      'environmentId': install.environmentId,
      'windows': [
        for (final w in usage.windows)
          {
            'label': w.label,
            'percent': w.percent,
            if (w.resetsAt != null) 'resetsAt': w.resetsAt!.toIso8601String(),
          },
      ],
    };
  }

  Future<Object?> _openSession(String? id) async {
    if (id == null) throw ArgumentError('Missing session id.');

    // A native session is reattached, not relaunched: it may still be running in
    // a pane, in which case "open" means bring its tab back — the same thing the
    // background-sessions list does. Only if nothing is live is it restarted,
    // through the one launcher, as a resume.
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
    // Before the terminal is even resolved: this surface had no guard at all,
    // so an agent the resume builder could not express opened a terminal
    // running a *new* conversation and the tool reported success.
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
    // Named in the answer, because the caller cannot see the desktop: this
    // branch is the one that opened a window, and it is the one an automated
    // caller has no way to undo.
    return {
      'opened': session.displayTitle,
      'environmentId': env.id,
      'externalTerminal': terminal.label,
      'note': 'Opened a new external terminal window. Close it yourself.',
    };
  }

  Future<Object?> _openNativeSession(Session session) async {
    // The launcher owns "is it already running, and where" for every surface —
    // this used to be the only place that asked, which is why every other resume
    // path relaunched a session that had never stopped.
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
      // A directory that has gone means the agent is resumed at the repository
      // root instead, and its store is keyed by directory — so the caller is
      // told, rather than being left to wonder why the conversation is empty.
      'note': ?launched.workingDirectoryNotice,
    };
  }
}

/// The schemas for the tools in [SessionLaunchTools] that start or reopen a
/// session, and the usage check that precedes one.
///
/// Two lists rather than one because the served order is a contract the
/// golden test holds: the fan-out schemas sit between these and
/// [sessionHandoffToolSchemas], and always have.
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
        'Get current usage/limit percentages for an agent. cli is "claude" '
        'or "codex"; environmentId is optional (defaults to the first '
        'matching installation).',
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
];
