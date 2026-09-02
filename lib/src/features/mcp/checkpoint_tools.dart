import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../checkpoints/application/checkpoint_providers.dart';
import '../checkpoints/application/checkpoint_service.dart';
import '../checkpoints/application/session_checkpoint_recorder.dart';
import '../checkpoints/domain/checkpoint.dart';
import '../git/data/hunk_patch.dart';

/// The per-turn record of a session's working tree, as an agent can read and
/// use it.
///
/// Like the session tools, these default to the caller's own session: the
/// credential in the MCP URL says who is asking, so a checkpoint tool called
/// with no `sessionId` is asking about the conversation it is running in.
///
/// Lifted out of `LauncherControlServer` unchanged, for the reason every other
/// family was: the server's job is the transport and the boundary, and a tool
/// family's only tie to it is the container it reads providers from.
class CheckpointControlTools {
  CheckpointControlTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// The session the transport established as the caller, or null for an
  /// unattributed one.
  final String? callerSessionId;

  static const Set<String> _names = <String>{
    'checkpoint_list',
    'checkpoint_capture',
    'checkpoint_diff',
    'checkpoint_restore',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'checkpoint_list' => _checkpointList(
          args['sessionId'] as String? ?? callerSessionId,
          (args['limit'] as num?)?.round(),
        ),
        'checkpoint_capture' => _checkpointCapture(
          args['sessionId'] as String? ?? callerSessionId,
          args['label'] as String?,
          callerSessionId: callerSessionId,
        ),
        'checkpoint_diff' => _checkpointDiff(args['id'] as String?),
        'checkpoint_restore' => _checkpointRestore(
          args['id'] as String?,
          confirm: args['confirm'] == true,
          paths: (args['paths'] as List?)?.whereType<String>().toList(),
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  Object? _checkpointList(String? sessionId, int? limit) {
    final service = _container.read(checkpointServiceProvider);
    final checkpoints = sessionId == null
        ? service.recent(limit: limit ?? 50)
        : service.forSession(sessionId).reversed.take(limit ?? 50).toList();
    return [for (final checkpoint in checkpoints) _checkpointJson(checkpoint)];
  }

  Future<Object?> _checkpointCapture(
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
    final checkpoint = await _container
        .read(sessionCheckpointRecorderProvider.notifier)
        .captureNow(
          sessionId,
          label: label,
          // A labelled capture lands in the decision record, and the record
          // attributes every row. Null when the bridge has no session of its
          // own, which reads as "not recorded" rather than as the user.
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
    return {'captured': true, 'checkpoint': _checkpointJson(checkpoint)};
  }

  Future<Object?> _checkpointDiff(String? id) async {
    final service = _container.read(checkpointServiceProvider);
    final checkpoint = _requireCheckpoint(service, id);
    return {'id': checkpoint.id, 'diff': await service.diffOf(checkpoint)};
  }

  Future<Object?> _checkpointRestore(
    String? id, {
    required bool confirm,
    List<String>? paths,
  }) async {
    final service = _container.read(checkpointServiceProvider);
    final checkpoint = _requireCheckpoint(service, id);
    try {
      final outcome = await service.restore(
        checkpoint,
        confirm: confirm,
        selection: [
          for (final path in paths ?? const <String>[]) HunkSelection(path),
        ],
      );
      _container.read(checkpointsRevisionProvider.notifier).bump();
      return {
        'restored': !outcome.alreadyThere,
        'alreadyThere': outcome.alreadyThere,
        'checkpoint': _checkpointJson(outcome.restored),
        'safetyCheckpointId': outcome.safetyCheckpoint?.id,
        'files': [
          for (final file in outcome.files)
            {'path': file.path, 'status': file.type.name},
        ],
      };
    } on CheckpointConflict catch (conflict) {
      throw StateError(
        '${conflict.message} Nothing was changed. The current working tree is '
        'saved as checkpoint ${conflict.safetyCheckpoint?.id}.',
      );
    }
  }

  Checkpoint _requireCheckpoint(CheckpointService service, String? id) {
    if (id == null || id.trim().isEmpty) {
      throw ArgumentError('id is required.');
    }
    final checkpoint = service.byId(id);
    if (checkpoint == null) throw StateError('No checkpoint with id $id.');
    return checkpoint;
  }

  Map<String, dynamic> _checkpointJson(Checkpoint checkpoint) => {
    'id': checkpoint.id,
    'sessionId': checkpoint.sessionId,
    'sequence': checkpoint.sequence,
    'reason': checkpoint.reason.name,
    'label': checkpoint.label,
    'createdAt': checkpoint.createdAt.toIso8601String(),
    'repository': checkpoint.repository.path,
    'environmentId': checkpoint.repository.environmentId,
    'commit': checkpoint.commitSha,
    'files': [
      for (final file in checkpoint.files)
        {'path': file.path, 'status': file.type.name},
    ],
  };
}

/// The schemas for [CheckpointControlTools].
const List<Map<String, dynamic>> checkpointControlToolSchemas = [
    {
      'name': 'checkpoint_list',
      'description':
          'List the checkpoints of a session — one per finished turn, plus the '
          'safety checkpoints taken before a restore. Each entry says what '
          'changed since the checkpoint before it. Defaults to the calling '
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
