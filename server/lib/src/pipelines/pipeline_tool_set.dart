import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;

import '../mcp/tools/server_tool_context.dart';
import '../mcp/tools/server_tool_set.dart';
import 'server_pipelines.dart';

/// `pipeline_templates`, `pipeline_run`, `pipeline_status`,
/// `pipeline_approve`: an agent starts a pipeline as its own run, follows
/// it, and approves its gates — only in runs it started.
class PipelineToolSet extends ServerToolSet {
  PipelineToolSet(ServerToolContext context, {required this.pipelines})
    : _sessions = SessionDao(context.database),
      _repositories = RepositoryDao(context.database);

  final ServerPipelines? Function() pipelines;
  final SessionDao _sessions;
  final RepositoryDao _repositories;

  @override
  List<Map<String, Object?>> get schemas => pipelineToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    if (!pipelineToolSchemas.any((s) => s['name'] == tool)) return null;
    return runTool(() async {
      final work =
          pipelines() ??
          (throw StateError('This server runs no pipelines yet.'));
      return switch (tool) {
        'pipeline_templates' => _templates(work),
        'pipeline_run' => _run(work, arguments, callerSessionId),
        'pipeline_status' => _status(work, arguments),
        'pipeline_approve' => await _approve(work, arguments, callerSessionId),
        _ => throw ArgumentError('Unknown tool: $tool'),
      };
    });
  }

  Map<String, Object?> _templates(ServerPipelines work) => {
    'pipelines': [
      for (final definition in work.definitions())
        {
          'id': definition.id,
          'name': definition.name,
          if (definition.description.isNotEmpty)
            'description': definition.description,
          'builtIn': definition.builtIn,
          'stages': [
            for (final stage in definition.stages)
              {
                'role': stage.role,
                'key': stage.key,
                'workspace': stage.workspace.storedName,
                'gate': stage.gate.storedName,
                'loopBackTo': ?stage.loopBackTo,
              },
          ],
        },
    ],
    'fields': {
      for (final (field, meaning) in kPipelineFieldHelp) field: meaning,
    },
  };

  Map<String, Object?> _run(
    ServerPipelines work,
    Map<String, dynamic> args,
    String? caller,
  ) {
    final input = (args['input'] as String?)?.trim() ?? '';
    final named = args['template'] as String?;
    final raw = args['definition'];
    final PipelineDefinition definition;
    if (raw is Map) {
      definition = PipelineDefinition.fromJson(raw.cast<String, Object?>());
    } else {
      definition = named == null
          ? kPipelineTemplates.first
          : work.definitionNamed(named) ??
                (throw ArgumentError(
                  'No pipeline or template is called "$named"; '
                  'pipeline_templates lists them.',
                ));
    }
    final repositoryId = _repositoryOf(args, caller);
    final run = work.startRun(
      definition: definition,
      repositoryId: repositoryId,
      input: input,
      startedBySessionId: caller,
    );
    return {
      ..._summary(run),
      'note':
          'Each stage is a session of its own, started as your sub-session. '
          'End your turn rather than polling; check pipeline_status when you '
          'next need it. A stage with an approval gate waits for '
          'pipeline_approve.',
    };
  }

  String _repositoryOf(Map<String, dynamic> args, String? caller) {
    final repositoryId = args['repositoryId'] as String?;
    if (repositoryId != null && repositoryId.isNotEmpty) return repositoryId;
    final projectId = args['projectId'] as String?;
    if (projectId != null && projectId.isNotEmpty) {
      final repo = _repositories.getByProject(projectId).firstOrNull;
      if (repo == null) throw StateError('That project has no checkout.');
      return repo.id;
    }
    final session = caller == null ? null : _sessions.getById(caller);
    if (session == null) {
      throw ArgumentError(
        'Name a repositoryId or projectId: this caller is not a session, so '
        'there is no checkout of its own to run in.',
      );
    }
    return session.repositoryId;
  }

  Object _status(ServerPipelines work, Map<String, dynamic> args) {
    final runId = args['runId'] as String?;
    if (runId == null || runId.isEmpty) {
      final limit = (args['limit'] as num?)?.round() ?? 10;
      return {
        'runs': [
          for (final run in work.records.runs(limit: limit.clamp(1, 50)))
            _summary(run),
        ],
      };
    }
    final run =
        work.records.run(runId) ??
        (throw ArgumentError('No pipeline run $runId.'));
    return {
      ..._summary(run),
      'stages': [
        for (final record in run.records)
          {
            'role': record.role,
            'attempt': record.attempt,
            'state': record.state.storedName,
            'sessionId': ?record.sessionId,
            'answer': ?record.answer,
            'handoff': ?record.handoff,
            if (record.artifacts.isNotEmpty)
              'artifacts': [
                for (final a in record.artifacts)
                  {'id': a.id, 'title': a.title},
              ],
            'worktree': ?record.worktreePath,
            'branch': ?record.branch,
            if (record.check case final check?)
              'check': {
                'verdict': check.verdict.name,
                'stale': check.stale,
                'summary': check.summary,
                'verificationRunId': ?check.verificationRunId,
                if (check.identity case final identity?)
                  'identity': identity.toSummaryJson(),
              },
            if (record.duration case final duration?)
              'durationMs': duration.inMilliseconds,
            'reason': ?record.reason,
          },
      ],
    };
  }

  Future<Map<String, Object?>> _approve(
    ServerPipelines work,
    Map<String, dynamic> args,
    String? caller,
  ) async {
    final runId = args['runId'] as String?;
    if (runId == null || runId.isEmpty) {
      throw ArgumentError('runId is required.');
    }
    if (caller == null) {
      throw StateError(
        'Only the session that started a pipeline run may act on it, and '
        'this caller is not a session.',
      );
    }
    final decision = args['decision'] as String? ?? 'approve';
    final run = switch (decision) {
      'approve' => work.runner.approve(
        runId,
        handoff: args['handoff'] as String?,
        bySessionId: caller,
      ),
      'stop' => await work.runner.stop(
        runId,
        reason: 'Stopped by the session that started it.',
        bySessionId: caller,
      ),
      _ => throw ArgumentError('decision is "approve" or "stop".'),
    };
    return _summary(run);
  }

  static Map<String, Object?> _summary(PipelineRun run) {
    final current = run.current;
    return {
      'runId': run.id,
      'pipeline': run.definition.name,
      'state': run.state.storedName,
      if (current != null) ...{
        'stage': current.role,
        'stageState': current.state.storedName,
        'stageSessionId': ?current.sessionId,
        if (current.state == PipelineStageState.approval)
          'handoff': current.handedOn,
      },
      'stages':
          '${run.records.where((r) => r.state.isSettled).length} '
          'settled of ${run.definition.stages.length}',
      'reason': ?run.reason,
    };
  }
}

const List<Map<String, Object?>> pipelineToolSchemas = [
  {
    'name': 'pipeline_templates',
    'description':
        'The pipelines you can run: the built-in templates (Plan → Implement '
        '→ Review, Implement → Test → Fix loop, Research → Write) and any the '
        'person saved. Each lists its stages with their workspace, gate and '
        'loop-back, plus the template fields an instruction can use.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
  {
    'name': 'pipeline_run',
    'description':
        'Start a pipeline: ordered stages, each a real agent session started '
        'as your sub-session, each handed the previous stage\'s answer, '
        'artifacts and worktree. Gates between stages go on by themselves, '
        'wait for pipeline_approve, or run checks. Answers at once with the '
        'run id; follow it with pipeline_status.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'input': {
          'type': 'string',
          'description': 'What the run is to do: {{input}} in every stage.',
        },
        'template': {
          'type': 'string',
          'description':
              'A pipeline id or name from pipeline_templates. Default: Plan '
              '→ Implement → Review.',
        },
        'definition': {
          'type': 'object',
          'description':
              'A whole definition in place of template: {name, stages: '
              '[{role, instruction, workspace: source|new_worktree|'
              'previous_worktree, gate: auto|approval|check, checkCommand, '
              'loopBackTo, loopCap, agentInstallationId, modelId, '
              'permissionMode}]}.',
        },
        'repositoryId': {
          'type': 'string',
          'description': 'The checkout to run in. Default: your own.',
        },
        'projectId': {
          'type': 'string',
          'description': "A project whose first checkout to run in.",
        },
      },
      'required': ['input'],
    },
  },
  {
    'name': 'pipeline_status',
    'description':
        'A pipeline run in full — each stage attempt with its session, '
        'answer, artifacts, worktree, branch, checks (with the code they ran '
        'on, and whether that reading is stale) and duration — or, with no '
        'runId, the recent runs one line each.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'runId': {'type': 'string', 'description': 'From pipeline_run.'},
        'limit': {
          'type': 'number',
          'description': 'Without runId: the most recent N (default 10).',
        },
      },
    },
  },
  {
    'name': 'pipeline_approve',
    'description':
        'Approve the hand-off a pipeline run is waiting on at an approval '
        'gate, optionally edited, or stop the run. Only in runs you started: '
        "another session's run, or a person's, is refused.",
    'inputSchema': {
      'type': 'object',
      'properties': {
        'runId': {'type': 'string'},
        'decision': {
          'type': 'string',
          'enum': ['approve', 'stop'],
          'description': 'Default approve.',
        },
        'handoff': {
          'type': 'string',
          'description':
              'The hand-off to pass on in place of the stage\'s answer.',
        },
      },
      'required': ['runId'],
    },
  },
];
