import 'package:riverpod/riverpod.dart';

import '../notes/application/notes_providers.dart';
import '../notes/domain/note.dart';
import '../notifications/application/attention_inbox.dart';
import 'package:karmashala_notifications/attention.dart';
import '../sessions/application/session_providers.dart';
import 'todo_tools.dart';

/// What is written down, and what is waiting: notes are the app's own
/// scratchpad, the inbox is every session that needs somebody.
class AttentionControlTools {
  AttentionControlTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;
  final String? callerSessionId;

  static const Set<String> _names = <String>{
    'notes_list',
    'note_add',
    'note_delete',
    'inbox_list',
    'inbox_open',
    'inbox_dismiss',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'notes_list' => _notesList(
          args['sessionId'] as String?,
          projectId: args['projectId'] as String?,
        ),
        'note_add' => _noteAdd(
          body: (args['body'] as String?) ?? '',
          title: args['title'] as String?,
          sessionId: args['sessionId'] as String? ?? callerSessionId,
          projectId: args['projectId'] as String?,
        ),
        'note_delete' => _noteDelete(args['id'] as String?),
        'inbox_list' => _inboxList(includeSeen: args['includeSeen'] == true),
        'inbox_open' => _inboxOpen(args['id'] as String?),
        'inbox_dismiss' => _inboxDismiss(args['id'] as String?),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// The notes, optionally narrowed to one session and one project, where
  /// `projectId: 'none'` means the unfiled ones and omitting it means all.
  Object? _notesList(String? sessionId, {String? projectId}) {
    final notes = <Note>[
      for (final note
          in _container.read(noteDaoProvider).list(sessionId: sessionId))
        if (projectId == null ||
            (projectId == TodoControlTools.unfiled
                ? note.projectId == null
                : note.projectId == projectId))
          note,
    ];
    return <String, Object?>{
      // Whether the panel is switched on. A caller adding notes into a surface
      // nobody can see deserves to know that, and it is not a reason to refuse.
      'notesPanelEnabled': _container.read(notesEnabledProvider),
      'notes': <Object?>[
        for (final note in notes)
          <String, Object?>{
            'id': note.id,
            'title': note.displayTitle,
            'body': note.body,
            'projectId': note.projectId,
            'sourceSessionId': note.sourceSessionId,
            'sourceRepositoryId': note.sourceRepositoryId,
            'createdAt': note.createdAt.toIso8601String(),
            'updatedAt': note.updatedAt.toIso8601String(),
          },
      ],
    };
  }

  /// Writes a note, keeping [body] **exactly as given**: a note is evidence, and
  /// a paraphrase's errors are invisible to whoever reads it next.
  Object? _noteAdd({
    required String body,
    String? title,
    String? sessionId,
    String? projectId,
  }) {
    if (body.trim().isEmpty) {
      throw ArgumentError('body is required and cannot be blank.');
    }
    // Which project it lands under: an explicit id wins, `'none'` files it
    // nowhere, and omitting it follows the session's own repository.
    final repositoryId = sessionId == null
        ? null
        : _container.read(sessionDaoProvider).getById(sessionId)?.repositoryId;
    final unfiled = projectId == TodoControlTools.unfiled;
    final note = _container
        .read(notesProvider.notifier)
        .capture(
          body: body,
          title: title,
          sourceSessionId: sessionId,
          sourceRepositoryId: repositoryId,
          projectId: unfiled ? null : projectId,
          inheritProjectFromSource: !unfiled,
        );
    return <String, Object?>{
      'id': note.id,
      'title': note.displayTitle,
      'projectId': note.projectId,
      'sourceSessionId': note.sourceSessionId,
      'createdAt': note.createdAt.toIso8601String(),
    };
  }

  Object? _noteDelete(String? id) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required. notes_list has the ids.');
    }
    if (_container.read(noteDaoProvider).getById(id) == null) {
      throw StateError('No note with id $id.');
    }
    _container.read(notesProvider.notifier).delete(id);
    return <String, Object?>{'id': id, 'deleted': true};
  }

  /// Everything waiting on somebody, newest first. `kind` is the fact that
  /// matters: `needsApproval` and `failed` will not restart themselves.
  Object? _inboxList({required bool includeSeen}) {
    final inbox = _container.read(attentionInboxProvider);
    final items = includeSeen ? inbox.items : inbox.pending;
    return <String, Object?>{
      'unseen': inbox.unseen,
      'total': inbox.items.length,
      'items': <Object?>[
        for (final item in items)
          <String, Object?>{
            'id': item.id,
            'kind': item.kind.name,
            'stillTrue': item.kind.isCondition,
            'label': item.session.label,
            'sessionId': item.session.openId,
            'imported': item.session.imported,
            'agentId': item.session.key.agentId,
            'seen': item.seen,
            // The source's own words — the question a blocked agent is
            // waiting on. Null when it quoted none; never synthesised.
            'detail': item.detail,
            // When it entered the inbox, not when it happened at the agent —
            // which we generally cannot know, so it is not claimed.
            'noticedAt': item.at.toIso8601String(),
          },
      ],
    };
  }

  /// Brings an item's session to the front, which also marks it seen: an event
  /// then leaves the inbox and a condition stays. Both outcomes are read back.
  Object? _inboxOpen(String? id) {
    final item = _item(id);
    _container.read(attentionInboxProvider.notifier).open(item);
    final stillListed = _container
        .read(attentionInboxProvider)
        .items
        .any((listed) => listed.id == item.id);
    return <String, Object?>{
      'id': item.id,
      'opened': item.session.label,
      'sessionId': item.session.openId,
      'seen': true,
      'stillListed': stillListed,
      'note': stillListed
          ? 'Still listed: looking at a question does not answer it. Use '
                'session_answer to answer it.'
          : 'Gone from the inbox: an event you have looked at is done with.',
    };
  }

  /// Takes an item off the list without opening anything. Nothing re-files an
  /// event kind; a condition that still holds comes back on the next poll.
  Object? _inboxDismiss(String? id) {
    final item = _item(id);
    _container.read(attentionInboxProvider.notifier).dismiss(item.id);
    return <String, Object?>{
      'id': item.id,
      'dismissed': true,
      'mayReturn': item.kind.isCondition,
    };
  }

  InboxItem _item(String? id) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required. inbox_list has the ids.');
    }
    final inbox = _container.read(attentionInboxProvider);
    for (final item in inbox.items) {
      if (item.id == id) return item;
    }
    throw StateError('Nothing in the inbox with id $id.');
  }
}

/// The schemas for [AttentionControlTools].
const List<Map<String, dynamic>> attentionControlToolSchemas = [
  {
    'name': 'inbox_list',
    'description':
        'Everything waiting on somebody: agents asking for approval, turns '
        'that failed, turns that finished unread, and pull requests that went '
        'red, were sent back, or are ready to merge. Each item carries the '
        'source\'s own detail, so the prompt a blocked agent is waiting on is '
        'here too. This is where an agent orchestrating other agents finds '
        'out what to do next. Unseen items only unless includeSeen is set.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'includeSeen': {
          'type': 'boolean',
          'description': 'Include items already looked at. Default false.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'unseen': {'type': 'number'},
        'total': {'type': 'number'},
        'items': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'kind': {
                'type': 'string',
                'enum': [
                  'needsApproval',
                  'failed',
                  'finished',
                  'checksFailed',
                  'changesRequested',
                  'readyToMerge',
                ],
              },
              'stillTrue': {
                'type': 'boolean',
                'description':
                    'Whether this describes a condition that holds right now, '
                    'rather than an event that has already happened.',
              },
              'label': {'type': 'string'},
              'sessionId': {'type': 'string'},
              'imported': {'type': 'boolean'},
              'agentId': {'type': 'string'},
              'seen': {'type': 'boolean'},
              'detail': {
                'type': 'string',
                'description':
                    'The source\'s own words about this item — the prompt a '
                    'blocked agent is waiting on. Absent when it quoted none.',
              },
              'noticedAt': {'type': 'string'},
            },
            'required': ['id', 'kind', 'label', 'sessionId'],
          },
        },
      },
      'required': ['unseen', 'total', 'items'],
    },
  },
  {
    'name': 'inbox_open',
    'description':
        'Bring an inbox item\'s session to the front of Karmashala and mark '
        'the item seen. An item for a past event leaves the inbox when you '
        'look at it; one for a question that is still open stays, because '
        'reading a question does not answer it — the result says which '
        'happened. Use this to show a person what you are talking about; to '
        'act on the session yourself, use session_transcript and '
        'session_answer.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Item id, from inbox_list.'},
      },
      'required': ['id'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'opened': {'type': 'string'},
        'sessionId': {'type': 'string'},
        'seen': {'type': 'boolean'},
        'stillListed': {
          'type': 'boolean',
          'description':
              'Whether the item survived being looked at. An event does not; '
              'a question you have read but not answered does.',
        },
        'note': {'type': 'string'},
      },
      'required': ['id', 'sessionId', 'stillListed'],
    },
  },
  {
    'name': 'inbox_dismiss',
    'description':
        'Take an item off the inbox without opening it. DESTRUCTIVE for an '
        'event — a turn that failed, a build that went red — because the thing '
        'it recorded has already happened and nothing re-files it. An item for '
        'a condition that is still true comes back on the next poll, and the '
        'result says which of the two this was.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Item id, from inbox_list.'},
      },
      'required': ['id'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'dismissed': {'type': 'boolean'},
        'mayReturn': {'type': 'boolean'},
      },
      'required': ['id', 'dismissed', 'mayReturn'],
    },
  },
  {
    'name': 'notes_list',
    'description':
        'The notes kept in Karmashala, newest first. Pass sessionId to see '
        'only the ones captured from one session, and projectId to see only '
        'the ones filed under one project — or the literal "none" for the '
        'ones filed under no project.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Only notes captured from this session.',
        },
        'projectId': {
          'type': 'string',
          'description':
              'Only notes filed under this project (list_projects has the '
              'ids), or "none" for only the ones filed under no project. '
              'Omit for all of them.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'notesPanelEnabled': {'type': 'boolean'},
        'notes': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'title': {'type': 'string'},
              'body': {'type': 'string'},
              'projectId': {
                'type': ['string', 'null'],
              },
              'sourceSessionId': {
                'type': ['string', 'null'],
              },
              'sourceRepositoryId': {
                'type': ['string', 'null'],
              },
              'createdAt': {'type': 'string'},
              'updatedAt': {'type': 'string'},
            },
            'required': ['id', 'title', 'body'],
          },
        },
      },
      'required': ['notes', 'notesPanelEnabled'],
    },
  },
  {
    'name': 'note_add',
    'description':
        'Write a note. The body is kept EXACTLY as given — nothing here trims '
        'it to a gist — so pass the words that should survive, not a summary '
        'of them. Attributed to the calling session unless sessionId names '
        'another, and filed under that session\'s project unless projectId '
        'says otherwise.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'body': {'type': 'string', 'description': 'The note, verbatim.'},
        'title': {
          'type': 'string',
          'description':
              'Optional. Without one the note is named by its first line.',
        },
        'sessionId': {
          'type': 'string',
          'description':
              'Which session this came from. Defaults to the calling session.',
        },
        'projectId': {
          'type': 'string',
          'description':
              'Which project to file it under (list_projects has the ids), or '
              '"none" for no project. Defaults to the project of the session '
              'it came from.',
        },
      },
      'required': ['body'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'title': {'type': 'string'},
        'projectId': {
          'type': ['string', 'null'],
        },
        'sourceSessionId': {
          'type': ['string', 'null'],
        },
        'createdAt': {'type': 'string'},
      },
      'required': ['id', 'title'],
    },
  },
  {
    'name': 'note_delete',
    'description':
        'Delete a note. DESTRUCTIVE: notes are not versioned and there is no '
        'undo.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Note id, from notes_list.'},
      },
      'required': ['id'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'deleted': {'type': 'boolean'},
      },
      'required': ['id', 'deleted'],
    },
  },
];
