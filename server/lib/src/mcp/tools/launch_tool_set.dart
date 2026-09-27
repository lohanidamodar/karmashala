import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' hide Clock;
import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_mcp/launch.dart';
import 'package:karmashala_projects/store.dart' show RepositoryDao;
import 'package:karmashala_session/launch.dart';

import '../../automations/daemon_agents.dart';
import '../../sessions/launch/server_session_launcher.dart';
import 'agent_names.dart';
import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// What an agent is told when a tool would show something and no Karmashala
/// window is connected to show it in.
const String kNoWindowOpen =
    'no Karmashala window is open, so nothing was shown';

/// **Starting a session**, by the server — `open_new_session`, for every
/// session an agent asks for (slice 5b), through [ServerSessionLauncher], the
/// path a person's New session takes. The session runs in the server whether
/// or not a window is open; the window the person last used is asked to show
/// it in a tab ([OpenSessionTab]).
///
/// What the server decides as the app did: the checkout (the project's first,
/// unless named — the project's own folder when none is recorded), the agent
/// (named, or the default Settings names), the spawn-depth cap, and the
/// permission carry — a session an agent starts holds no more than the least
/// of its caller's mode and "autoRun".
class LaunchToolSet extends ServerToolSet {
  LaunchToolSet(
    this._context, {
    required this.launches,
    this.agents = const DaemonAgents(),
  }) : _repositories = RepositoryDao(_context.database) {
    _launches = LaunchDedupe(
      clock: _ContextClock(_context),
      onCollapsed: (tool) => _context.log(
        'A repeat $tool was collapsed onto the identical launch already '
        'made; nothing new was started. The caller most likely timed out '
        'and retried.',
      ),
    );
  }

  /// One agent per request, however often it arrives: a caller that timed
  /// out and retried must not start a second agent.
  late final LaunchDedupe _launches;

  final ServerToolContext _context;
  final ServerSessionLauncher launches;
  final DaemonAgents agents;
  final RepositoryDao _repositories;

  @override
  List<Map<String, Object?>> get schemas => launchToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    if (tool != 'open_new_session') return null;
    return _launches.run(
      tool: tool,
      arguments: arguments,
      callerSessionId: callerSessionId,
      start: () => runTool(() => _open(arguments, callerSessionId)),
    );
  }

  Future<Object?> _open(
    Map<String, dynamic> args,
    String? callerSessionId,
  ) async {
    final projectId = args['projectId'] as String?;
    if (projectId == null) throw ArgumentError('Missing projectId.');
    final repositoryId = args['repositoryId'] as String?;
    final repos = _repositories.getByProject(projectId);
    final Repository repo;
    if (repositoryId != null) {
      repo = repos.firstWhere(
        (r) => r.id == repositoryId,
        orElse: () => throw StateError('Repository not found in this project.'),
      );
    } else {
      repo = repos.firstOrNull ?? _runLocationOf(projectId);
    }
    final installs = launches.installationsIn(repo.path.environmentId);
    if (installs.isEmpty) {
      throw StateError('No agent is installed in ${repo.path.environmentId}.');
    }
    final agentInstallationId = args['agentInstallationId'] as String?;
    final cli = args['cli'] as String?;
    AgentInstallation? install;
    if (agentInstallationId != null) {
      install = installs.where((i) => i.id == agentInstallationId).firstOrNull;
      if (install == null) {
        throw StateError(
          'That agent installation is not available in this project.',
        );
      }
    } else if (cli != null) {
      final agentId = agentIdForName(_context.agents, cli);
      install = installs.where((i) => i.agentId == agentId).firstOrNull;
      if (install == null) {
        throw StateError(
          '$cli is not installed in ${repo.path.environmentId}.',
        );
      }
    } else {
      install =
          launches.defaultInstallationIn(repo.path.environmentId) ??
          installs.first;
    }

    final permission = _spawnPermission(
      args['permissionMode'] as String?,
      install.agentId,
      callerSessionId,
    );
    final title = args['title'] as String?;
    final started = await launches.start(
      SessionStartSpec(
        repositoryId: repo.id,
        installationId: install.id,
        title: (title == null || title.trim().isEmpty)
            ? 'Agent session'
            : title.trim(),
        prompt: args['prompt'] as String?,
        worktree: args['useWorktree'] == true,
        permissionMode: permission.selection?.canonical,
        parentSessionId: callerSessionId,
      ),
    );
    final session = started.session;
    final shown = _context.data.tellIntent(
      OpenSessionTab(
        sessionId: session.id,
        title: session.title,
        launch: started.launch,
      ),
    );
    return <String, Object?>{
      'sessionId': session.id,
      'opened': 'new ${install.agentId} session',
      'title': session.title,
      'repository': repo.name,
      'environmentId': repo.path.environmentId,
      'depth': started.depth ?? launches.depthForChildOf(callerSessionId).depth,
      'permissionMode': session.permissionMode ?? 'not recorded',
      if (permission.capped != null) 'permissionCapped': permission.capped,
      if (session.worktree != null) 'worktree': session.worktree!.path,
      'where': shown
          ? 'running in the Karmashala server, shown in a tab of the '
                'Karmashala window'
          : 'running in the Karmashala server; $kNoWindowOpen — a window '
                'shows it when it is opened',
    };
  }

  /// Where a session started at [projectId] runs when the workspace records
  /// no checkout for it: the project's own folder, recorded now.
  Repository _runLocationOf(String projectId) {
    final added = _context.write(CheckoutsAdd(projectId: projectId));
    final first =
        added.firstOrNull ?? _repositories.getByProject(projectId).firstOrNull;
    if (first == null) {
      throw StateError('This project is no longer in the workspace.');
    }
    return first;
  }

  /// The mode a session an agent asked for launches under: the least of what
  /// it named (or the Settings default), what the calling session holds, and
  /// the spawn ceiling. A named mode above that is refused rather than
  /// quietly lowered; an omitted one is lowered and `capped` says so.
  ({PermissionSelection? selection, String? capped}) _spawnPermission(
    String? raw,
    String agentId,
    String? callerSessionId,
  ) {
    final descriptor = agents.descriptorOf(agentId);
    final support = descriptor?.launch.permission;
    final wanted = raw?.trim() ?? '';
    final risk = PermissionRisk.byName(wanted);
    if (support == null || !support.isKnown) {
      if (wanted.isEmpty || risk != null) {
        return (selection: null, capped: null);
      }
      throw _unknownMode(raw!, support);
    }
    final defaultRisk =
        support.riskOf(
          launches.permissionFor(agentId, SessionPurpose.newSession),
        ) ??
        PermissionRisk.ask;
    final callerRisk = _callerRisk(callerSessionId) ?? defaultRisk;

    SpawnCarry carry(PermissionRisk requested) => carrySpawnPermission(
      requested: requested,
      callerRisk: callerRisk,
      target: descriptor,
    );

    if (wanted.isEmpty) {
      final capped = carry(defaultRisk);
      if (!capped.wasCapped) return (selection: null, capped: null);
      return (
        selection: capped.selection,
        capped:
            'Started at ${capped.carried.label} rather than the Settings '
            'default (${defaultRisk.label.toLowerCase()}): ${capped.reason}.',
      );
    }
    if (risk != null) {
      final capped = carry(risk);
      if (capped.wasCapped) throw ArgumentError(capped.refusal);
      return (selection: capped.selection, capped: null);
    }
    for (final selection in support.selections()) {
      if (selection.canonical != wanted) continue;
      final exact = support.riskOf(selection);
      if (exact != null && carry(exact).wasCapped) {
        throw ArgumentError(carry(exact).refusal);
      }
      return (selection: selection, capped: null);
    }
    throw _unknownMode(raw!, support);
  }

  /// How permissive the calling session is, or null when there is no caller
  /// or its rung cannot be established — which reads as the default, never
  /// as unbounded.
  PermissionRisk? _callerRisk(String? callerSessionId) {
    if (callerSessionId == null) return null;
    final effective = launches.effectivePermissionOf(callerSessionId);
    if (effective == null) return null;
    final caller = _context.data.installations
        .where(
          (i) =>
              i.id ==
              launches.sessions.getById(callerSessionId)?.agentInstallationId,
        )
        .firstOrNull;
    if (caller == null) return null;
    final support = agents.descriptorOf(caller.agentId)?.launch.permission;
    return support?.riskOf(effective.selection);
  }

  static ArgumentError _unknownMode(
    String raw,
    AgentPermissionSupport? support,
  ) => ArgumentError(
    'Unknown permissionMode "$raw". One of: '
    '${PermissionRisk.values.map((m) => m.name).join(', ')}'
    '${support != null && support.isKnown ? ', or one of '
              '${support.selections().map((s) => s.canonical).join(', ')}' : ''}.',
  );
}

final class _ContextClock implements Clock {
  const _ContextClock(this._context);
  final ServerToolContext _context;
  @override
  DateTime nowUtc() => _context.now();
}

/// The schemas of the launch tools the server runs, moved from the app with
/// their words unchanged.
const List<Map<String, Object?>> launchToolSchemas = [
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
              'does. A session you start holds no more than the least of your '
              'own mode and "autoRun"; a mode above that is refused, and only '
              'the user can raise it, from the new session\'s permission chip.',
        },
      },
      'required': ['projectId'],
    },
  },
];
