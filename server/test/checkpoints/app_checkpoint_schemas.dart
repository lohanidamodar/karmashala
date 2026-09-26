/// A copy of `checkpointControlToolSchemas` as the app served them before
/// slice 2b (app/lib/src/features/mcp/checkpoint_tools.dart at HEAD),
/// taken verbatim: the server must serve these bytes.
const List<Map<String, dynamic>> appCheckpointToolSchemas = [
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
