import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;

import '../mcp/tools/server_tool_set.dart';
import 'daemon_checkpoints.dart';

/// `checkpoint_list`, `checkpoint_capture`, `checkpoint_diff`,
/// `checkpoint_restore`: the per-turn record of a session's working tree, run
/// by the server's own recorder (slice 2b). Like the session tools, they
/// default to the caller's own session, named by its MCP credential. A
/// checkout the server cannot run git in (SSH) is refused in words; nothing
/// is handed to the app.
class CheckpointToolSet extends ServerToolSet {
  const CheckpointToolSet(this._checkpoints);

  final DaemonCheckpoints _checkpoints;

  @override
  List<Map<String, Object?>> get schemas => checkpointToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(() async {
    try {
      return await switch (tool) {
        'checkpoint_list' => _list(
          arguments['sessionId'] as String? ?? callerSessionId,
          (arguments['limit'] as num?)?.round(),
        ),
        'checkpoint_capture' => _capture(
          arguments['sessionId'] as String? ?? callerSessionId,
          arguments['label'] as String?,
          callerSessionId: callerSessionId,
        ),
        'checkpoint_diff' => _diff(arguments['id'] as String?),
        'checkpoint_restore' => _restore(
          arguments['id'] as String?,
          confirm: arguments['confirm'] == true,
          paths: (arguments['paths'] as List?)?.whereType<String>().toList(),
        ),
        _ => throw ArgumentError('Unknown tool: $tool'),
      };
    } on DataRefused catch (refusal) {
      // A checkout this server cannot reach, in the server's words.
      throw StateError(refusal.message);
    }
  });

  Future<Object?> _list(String? sessionId, int? limit) async {
    final checkpoints = sessionId == null
        ? _checkpoints.recent(limit: limit ?? 50)
        : _checkpoints.forSession(sessionId).reversed.take(limit ?? 50);
    return [
      for (final checkpoint in checkpoints) checkpointToolJson(checkpoint),
    ];
  }

  Future<Object?> _capture(
    String? sessionId,
    String? label, {
    String? callerSessionId,
  }) async {
    if (sessionId == null) {
      throw ArgumentError(
        'sessionId is required for checkpoint_capture when the caller is not '
        'itself a Karmashala session.',
      );
    }
    final checkpoint = await _checkpoints.recorder.captureNow(
      sessionId,
      label: label,
      // A labelled capture lands in the decision record, which attributes
      // every row; null reads as "not recorded" rather than as the user.
      decidedBy: callerSessionId == null
          ? null
          : 'an agent in session $callerSessionId',
      decidedBySessionId: callerSessionId,
    );
    if (checkpoint == null) {
      return {
        'captured': false,
        'reason':
            'Nothing has changed since the last checkpoint, or the session has '
            'no repository to checkpoint.',
      };
    }
    return {'captured': true, 'checkpoint': checkpointToolJson(checkpoint)};
  }

  Future<Object?> _diff(String? id) async {
    final checkpoint = _requireCheckpoint(id);
    return {'id': checkpoint.id, 'diff': await _checkpoints.diffOf(checkpoint)};
  }

  Future<Object?> _restore(
    String? id, {
    required bool confirm,
    List<String>? paths,
  }) async {
    final checkpoint = _requireCheckpoint(id);
    final answer = await _checkpoints.restore(
      checkpoint,
      confirm: confirm,
      paths: paths ?? const [],
    );
    final conflict = answer.conflict;
    if (conflict != null) {
      throw StateError(
        '${conflict.message} Nothing was changed. The current working tree is '
        'saved as checkpoint ${conflict.safetyCheckpoint?.id}.',
      );
    }
    final outcome = answer.outcome!;
    return {
      'restored': !outcome.alreadyThere,
      'alreadyThere': outcome.alreadyThere,
      'checkpoint': checkpointToolJson(outcome.restored),
      'safetyCheckpointId': outcome.safetyCheckpoint?.id,
      'files': [
        for (final file in outcome.files)
          {'path': file.path, 'status': file.type.name},
      ],
    };
  }

  Checkpoint _requireCheckpoint(String? id) {
    if (id == null || id.trim().isEmpty) {
      throw ArgumentError('id is required.');
    }
    final checkpoint = _checkpoints.byId(id);
    if (checkpoint == null) throw StateError('No checkpoint with id $id.');
    return checkpoint;
  }
}

/// One checkpoint as the agent tools describe it: the panel's title, and
/// what changed since the previous checkpoint of its repository.
Map<String, Object?> checkpointToolJson(Checkpoint checkpoint) => {
  'id': checkpoint.id,
  'sessionId': checkpoint.sessionId,
  'sequence': checkpoint.sequence,
  'title': checkpointTitle(checkpoint),
  'reason': checkpoint.reason.name,
  'label': checkpoint.label,
  'createdAt': checkpoint.createdAt.toIso8601String(),
  'repository': checkpoint.repository.path,
  'environmentId': checkpoint.repository.environmentId,
  'commit': checkpoint.commitSha,
  'turn': checkpoint.turn,
  'prompt': checkpoint.prompt,
  'additions': checkpoint.additions,
  'deletions': checkpoint.deletions,
  'files': [
    for (final file in checkpoint.files)
      {
        'path': file.path,
        'status': file.type.name,
        if (checkpoint.lineStats[file.path] case final stat?) ...{
          'additions': stat.added,
          'deletions': stat.removed,
        },
      },
  ],
};

/// The schemas for [CheckpointToolSet], as the app served them.
const List<Map<String, Object?>> checkpointToolSchemas = [
  {
    'name': 'checkpoint_list',
    'description':
        'List the checkpoints of a session — taken as each agent turn '
        'starts and ends in every repository it changed, plus manual and '
        'pre-restore safety checkpoints. Each entry says its title (the '
        'panel\'s words, including when a before-turn snapshot may already '
        'hold the turn\'s first edit), turn, prompt and what changed since '
        'the previous checkpoint of its repository. '
        'Defaults to the calling '
        "session's own checkpoints.",
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Session to list. Defaults to the caller.',
        },
        'limit': {'type': 'number', 'description': 'Most recent N.'},
      },
    },
  },
  {
    'name': 'checkpoint_capture',
    'description':
        'Record the working tree as it is right now, so it can be restored '
        'later. Nothing in the repository is staged, committed or moved: the '
        'snapshot is a git tree written through a private index.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'label': {
          'type': 'string',
          'description': 'What this checkpoint is, for a human reading it.',
        },
      },
    },
  },
  {
    'name': 'checkpoint_diff',
    'description':
        'The unified diff a checkpoint represents: what changed between the '
        'checkpoint before it and it.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Checkpoint id.'},
      },
      'required': ['id'],
    },
  },
  {
    'name': 'checkpoint_restore',
    'description':
        'Put the working tree back to a checkpoint. DESTRUCTIVE: it discards '
        'edits made since. A checkpoint of the current tree is always taken '
        'first, so the restore can itself be undone. If anything has changed '
        'since the most recent checkpoint the call is refused unless '
        '"confirm" is true — ask the user before setting it. The index is '
        'not touched.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Checkpoint id to restore.'},
        'confirm': {
          'type': 'boolean',
          'description':
              'Restore even though the working tree has moved since the last '
              'checkpoint. Requires the user to have said so.',
        },
        'paths': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Restore only these paths. Omit to restore everything.',
        },
      },
      'required': ['id'],
    },
  },
];
