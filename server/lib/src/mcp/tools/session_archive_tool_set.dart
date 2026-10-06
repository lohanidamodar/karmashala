import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;

import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// `session_archive` and `session_unarchive`: an agent hides the sessions it
/// spawned once their work is done — only its own descendants, only once
/// they have ended. Archiving hides; the transcript and worktree stay.
class SessionArchiveToolSet extends ServerToolSet {
  SessionArchiveToolSet(this._context)
    : _sessions = SessionDao(_context.database);

  final ServerToolContext _context;
  final SessionDao _sessions;

  @override
  List<Map<String, Object?>> get schemas => sessionArchiveToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => switch (tool) {
    'session_archive' => runTool(
      () => _act(arguments, callerSessionId, archive: true),
    ),
    'session_unarchive' => runTool(
      () => _act(arguments, callerSessionId, archive: false),
    ),
    _ => null,
  };

  Object? _act(
    Map<String, dynamic> arguments,
    String? caller, {
    required bool archive,
  }) {
    final named = (arguments['sessionId'] as String?)?.trim() ?? '';
    if (named.isEmpty) {
      throw ArgumentError(
        'sessionId is required: name the sub-session, never yourself.',
      );
    }
    if (caller == null || caller.isEmpty) {
      throw StateError(
        'Only a session can archive the sessions it started, and this caller '
        'is not running inside one. Nothing was done.',
      );
    }
    final target =
        _sessions.getById(named) ??
        (throw StateError('No session with id $named. Nothing was done.'));
    if (!_descendsFrom(target, caller)) {
      throw StateError(
        '"${target.title}" ($named) is not one you started — neither your '
        'child nor one of its descendants — so it is not yours to '
        '${archive ? 'archive' : 'unarchive'}. Nothing was done.',
      );
    }
    final answer = _context.write(
      archive ? SessionsArchive([named]) : SessionsUnarchive([named]),
    );
    if (answer.live.any((s) => s.id == named)) {
      throw StateError(
        '"${target.title}" ($named) is still running, and only a session '
        'that has ended can be archived. End it first (session_end), or wait '
        'for it to finish. Nothing was done.',
      );
    }
    return <String, Object?>{
      'sessionId': named,
      archive ? 'archived' : 'unarchived': answer.changed,
      if (archive)
        'leftLive': [
          for (final s in answer.live) {'sessionId': s.id, 'title': s.title},
        ],
    };
  }

  /// Whether [row] is a child of [ancestor], or a child of one of its
  /// descendants.
  bool _descendsFrom(Session row, String ancestor) {
    final seen = <String>{row.id};
    var parent = row.parentSessionId;
    while (parent != null && seen.add(parent)) {
      if (parent == ancestor) return true;
      parent = _sessions.getById(parent)?.parentSessionId;
    }
    return false;
  }
}

const List<Map<String, Object?>> sessionArchiveToolSchemas = [
  {
    'name': 'session_archive',
    'description':
        'Archive a session you started — your child or one of its '
        'descendants — once it has ended: it leaves every session list, and '
        'its inbox items retire. Its ended descendants are archived with it; '
        'live ones are left and named. The transcript, files and worktree '
        'all stay, and session_unarchive restores it. Refused for a session '
        'that is not yours or is still running. Archive a child once its work '
        'is merged or handed back.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'The sub-session to archive. Never defaults to you.',
        },
      },
      'required': ['sessionId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'archived': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'leftLive': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'sessionId': {'type': 'string'},
              'title': {'type': 'string'},
            },
          },
        },
      },
      'required': ['sessionId', 'archived', 'leftLive'],
    },
  },
  {
    'name': 'session_unarchive',
    'description':
        'Restore a session you archived with session_archive — your child or '
        'one of its descendants — and its archived descendants, to the '
        'session lists. Refused for a session that is not yours.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'The sub-session to restore. Never defaults to you.',
        },
      },
      'required': ['sessionId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'unarchived': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['sessionId', 'unarchived'],
    },
  },
];
