import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_comparisons/store.dart';
import 'package:karmashala_projects/store.dart';

import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// `fanout_list`, `fanout_get`: the fan-out comparisons an agent can read —
/// one prompt run on several agents in parallel worktrees — straight from the
/// store. Read-only, and it needs no caller identity.
class FanOutToolSet extends ServerToolSet {
  FanOutToolSet(ServerToolContext context)
    : _comparisons = ComparisonDao(context.database),
      _repositories = RepositoryDao(context.database);

  final ComparisonDao _comparisons;
  final RepositoryDao _repositories;

  @override
  List<Map<String, Object?>> get schemas => fanOutToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(
    () => switch (tool) {
      'fanout_list' => _list(
        repositoryId: arguments['repositoryId'] as String?,
        includeArchived: arguments['includeArchived'] == true,
        limit: (arguments['limit'] as num?)?.round(),
      ),
      'fanout_get' => _get(arguments['id'] as String?),
      _ => throw ArgumentError('Unknown tool: $tool'),
    },
  );

  /// Comparisons, newest first. Compact by design: an agent asking "what did
  /// we try?" wants the shape, not every diff.
  List<Map<String, Object?>> _list({
    String? repositoryId,
    bool includeArchived = false,
    int? limit,
  }) {
    final comparisons = _comparisons.getAll(
      repositoryId: repositoryId,
      includeArchived: includeArchived,
    )..sort(compareComparisons);
    final capped = comparisons.take(limit == null || limit <= 0 ? 20 : limit);
    return [
      for (final comparison in capped)
        {
          'id': comparison.id,
          'prompt': comparison.title,
          'repository': _repositories.getById(comparison.repositoryId)?.name,
          'createdAt': comparison.createdAt.toIso8601String(),
          'outcome': comparison.outcome.name,
          'winner': comparison.winner?.agentId,
          'archived': comparison.archived,
          'candidates': [
            for (final candidate in comparison.candidates)
              {
                'agentId': candidate.agentId,
                'state': candidate.launch.name,
                'diff': candidate.diff?.summary,
              },
          ],
        },
    ];
  }

  /// One comparison in full — still without diff text, which is what
  /// `git diff` in the worktree is for while the worktree exists.
  Map<String, Object?> _get(String? id) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required.');
    }
    final comparison =
        _comparisons.getById(id) ??
        (throw ArgumentError('No comparison with id $id.'));
    return {
      'id': comparison.id,
      'prompt': comparison.prompt,
      'repository': _repositories.getById(comparison.repositoryId)?.name,
      'repositoryId': comparison.repositoryId,
      'createdAt': comparison.createdAt.toIso8601String(),
      'finishedAt': comparison.finishedAt?.toIso8601String(),
      'outcome': comparison.outcome.name,
      'mergedCommit': comparison.mergedCommit,
      'winnerAgentId': comparison.winner?.agentId,
      'archived': comparison.archived,
      'candidates': [
        for (final candidate in comparison.candidates)
          {
            'id': candidate.id,
            'agentId': candidate.agentId,
            'sessionId': candidate.sessionId,
            'state': candidate.launch.name,
            'isWinner': comparison.winnerCandidateId == candidate.id,
            'branch': candidate.branch,
            'worktree': candidate.worktree?.path,
            'worktreeRemoved': candidate.worktreeRemoved,
            if (candidate.diff case final diff?)
              'diff': {
                'summary': diff.summary,
                'filesChanged': diff.filesChanged,
                'insertions': diff.insertions,
                'deletions': diff.deletions,
                'commits': diff.commits,
                'capturedAt': diff.capturedAt.toIso8601String(),
              },
            if (candidate.evidence case final evidence?)
              'verdict': {
                'verdict': evidence.verdict.name,
                'label': evidence.label,
                'runId': evidence.runId,
                // Present even when null: an omitted producer reads as a gap
                // in the tool rather than in the record.
                'producedBySessionId': evidence.producerSessionId,
                'attribution': candidate.evidenceAttribution.name,
                'attributionLabel': candidate.evidenceAttribution.label,
              },
            'failure': candidate.failure,
            'notes': candidate.notes,
          },
      ],
    };
  }
}

/// The schemas for [FanOutToolSet], as the app served them.
const List<Map<String, Object?>> fanOutToolSchemas = [
  {
    'name': 'fanout_list',
    'description':
        'List the fan-out comparisons — one prompt run on several agents in '
        'parallel worktrees. Each row gives the prompt, when it ran, the '
        'outcome (pending/merged/discarded) and every candidate with its '
        'agent and diff stat. Comparisons persist: a merged one whose losing '
        'worktrees were deleted is still listed. Use fanout_get for the full '
        'record of one.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {
          'type': 'string',
          'description': 'Only comparisons for this repository.',
        },
        'includeArchived': {
          'type': 'boolean',
          'description': 'Include comparisons the user archived.',
        },
        'limit': {
          'type': 'number',
          'description': 'Most recent N (default 20).',
        },
      },
    },
  },
  {
    'name': 'fanout_get',
    'description':
        'The full record of one fan-out comparison: the prompt, the winner, '
        'the merge commit, and every candidate with its session, branch, '
        'worktree (and whether that worktree has been removed), diff stat, '
        'verification verdict and failure reason. Each verdict says who '
        'produced it: attribution is "author" when the candidate graded '
        'itself, "independent" when another session did, and "notRecorded" '
        'when nobody recorded a verifier — a self-graded pass is not '
        'evidence, so say which one it was when you report on a '
        'comparison the user ran.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'Comparison id, from fanout_list.',
        },
      },
      'required': ['id'],
    },
  },
];
