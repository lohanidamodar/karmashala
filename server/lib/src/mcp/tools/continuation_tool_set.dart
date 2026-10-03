import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/launch.dart';
import 'package:karmashala_session/lineage.dart';

import '../../sessions/launch/session_continuations.dart';
import 'agent_names.dart';
import 'launch_tool_set.dart' show kNoWindowOpen;
import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// **Continuing a session somewhere else**, by the server (slice 5b) —
/// `session_handoff`, `session_fork`, `session_fork_from_checkpoint`. Thin on
/// purpose: every decision is [SessionContinuations]'s; the new session runs
/// in the server, and the window the person last used is asked to show it.
class ContinuationToolSet extends ServerToolSet {
  ContinuationToolSet(this._context, {required this.continuations}) {
    _launches = LaunchDedupe(
      clock: _ContextClock(_context),
      onCollapsed: (tool) => _context.log(
        'A repeat $tool was collapsed onto the identical launch already '
        'made; nothing new was started.',
      ),
    );
  }

  final ServerToolContext _context;
  final SessionContinuations continuations;

  /// One new session per request, however often a caller that timed out
  /// sends it again.
  late final LaunchDedupe _launches;

  @override
  List<Map<String, Object?>> get schemas => sessionHandoffToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> args,
    String? callerSessionId,
  ) {
    if (!schemas.any((s) => s['name'] == tool)) return null;
    if (!startsAnAgent(tool, args)) {
      return _call(tool, args, callerSessionId);
    }
    return _launches.run(
      tool: tool,
      arguments: args,
      callerSessionId: callerSessionId,
      start: () => _call(tool, args, callerSessionId)!,
    );
  }

  Future<Object?>? _call(
    String tool,
    Map<String, dynamic> args,
    String? callerSessionId,
  ) => switch (tool) {
    'session_handoff' => runTool(
      () => _handoff(
        sessionId: args['sessionId'] as String?,
        cli: args['cli'] as String?,
        agentInstallationId: args['agentInstallationId'] as String?,
        instruction: args['instruction'] as String?,
        unresolved: (args['unresolved'] as List?)?.whereType<String>().toList(),
        newWorktree: args['newWorktree'] == true,
        preview: args['preview'] == true,
      ),
    ),
    'session_fork' => runTool(
      () => _fork(
        sessionId: args['sessionId'] as String?,
        instruction: args['instruction'] as String?,
        newWorktree: args['newWorktree'] == true,
        preview: args['preview'] == true,
      ),
    ),
    // Named, never defaulted to the caller: this one rewrites files.
    'session_fork_from_checkpoint' => runTool(() async {
      final sessionId = args['sessionId'] as String?;
      if (sessionId == null) throw ArgumentError('Missing sessionId.');
      final answer = await continuations.forkFromCheckpoint(
        sessionId: sessionId,
        checkpointId: args['checkpointId'] as String?,
        turn: (args['turn'] as num?)?.round(),
        instruction: (args['instruction'] as String?) ?? '',
        newWorktree: args['newWorktree'] == true,
        confirm: args['confirm'] == true,
        preview: args['preview'] == true,
        requestedBy: callerSessionId,
      );
      final started = answer['sessionId'];
      if (started is String) {
        answer['where'] = _show(started);
      }
      return answer;
    }),
    _ => null,
  };

  Future<Object?> _handoff({
    String? sessionId,
    String? cli,
    String? agentInstallationId,
    String? instruction,
    List<String>? unresolved,
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
    final targets = continuations.targetsFor(sessionId);
    if (targets.isEmpty) {
      throw StateError(
        'No agent is installed in that session\'s environment, or the session '
        'no longer exists.',
      );
    }
    final target = _target(targets, cli, agentInstallationId);
    if (!target.canReceive) throw StateError(target.refusal!);
    if (preview) {
      final packet = await continuations.buildPacket(
        sessionId: sessionId,
        targetAgentName: target.agentName,
        instruction: instruction,
        unresolvedTasks: unresolved ?? const [],
      );
      return {
        'preview': true,
        'target': target.agentName,
        'permissionMode': target.permission.selection.canonical,
        'permission': target.permission.summary,
        'packet': packet.render(),
      };
    }
    final started = await continuations.handoff(
      sessionId: sessionId,
      targetInstallationId: target.installation.id,
      instruction: instruction,
      unresolvedTasks: unresolved ?? const [],
      intoNewWorktree: newWorktree,
    );
    return {
      'sessionId': started.sessionId,
      'title': started.session.title,
      'target': target.agentName,
      'parentSessionId': sessionId,
      'link': SessionLink.handoff.name,
      'permissionMode': target.permission.selection.canonical,
      'permission': target.permission.summary,
      if (started.session.worktree != null)
        'worktree': started.session.worktree!.path,
      'where': _show(started.sessionId, started: started),
    };
  }

  /// The target the caller named, an installation id over a CLI name. Never
  /// falls back: the wrong provider is not a smaller right one.
  HandoffTarget _target(
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
      final agentId = agentIdForName(_context.agents, cli);
      for (final target in targets) {
        if (target.installation.agentId == agentId) return target;
      }
      throw StateError('$cli is not installed in that session\'s environment.');
    }
    // No preference: the first agent that is *not* the one running it.
    for (final target in targets) {
      if (!target.isSameAgent && target.canReceive) return target;
    }
    return targets.first;
  }

  Future<Object?> _fork({
    String? sessionId,
    String? instruction,
    bool newWorktree = false,
    bool preview = false,
  }) async {
    if (sessionId == null) throw ArgumentError('Missing sessionId.');
    final plan = continuations.forkPlanFor(sessionId);
    if (preview) {
      return {
        'preview': true,
        'route': plan.kind.name,
        'explanation': plan.explanation,
      };
    }
    if (plan.isRefused) throw StateError(plan.explanation);
    final started = await continuations.fork(
      sessionId: sessionId,
      instruction: instruction ?? '',
      intoNewWorktree: newWorktree,
    );
    return {
      'sessionId': started.sessionId,
      'title': started.session.title,
      'parentSessionId': sessionId,
      'link': SessionLink.fork.name,
      // Said plainly: a native fork shares the agent's own record, a handoff
      // carries a written recap of it.
      'route': plan.kind.name,
      'explanation': plan.explanation,
      if (started.session.worktree != null)
        'worktree': started.session.worktree!.path,
      'where': _show(started.sessionId, started: started),
    };
  }

  /// Asks the person's window to show [sessionId]; says where it runs.
  String _show(String sessionId, {SessionStarted? started}) {
    final row = started?.session;
    final shown = _context.data.tellIntent(
      OpenSessionTab(
        sessionId: sessionId,
        title: row?.title ?? 'Agent session',
        launch: started?.launch,
      ),
    );
    return shown
        ? 'running in the Karmashala server, shown in a tab of the Karmashala '
              'window'
        : 'running in the Karmashala server; $kNoWindowOpen — a window shows '
              'it when it is opened';
  }
}

final class _ContextClock implements Clock {
  const _ContextClock(this._context);
  final ServerToolContext _context;
  @override
  DateTime nowUtc() => _context.now();
}

/// The schemas for continuing a session somewhere else, moved from the app
/// with their words unchanged.
const List<Map<String, Object?>> sessionHandoffToolSchemas = [
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
