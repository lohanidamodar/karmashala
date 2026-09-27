import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show InboxDismiss;
import 'package:karmashala_notifications/attention.dart';

import '../../attention/server_attention.dart';
import 'server_tool_set.dart';

/// `inbox_list`, `inbox_open`, `inbox_dismiss` — what is waiting on somebody,
/// answered from the server's own inbox (slice 5c), app or no app. Opening
/// an item marks it seen here and tells every connected window to show it;
/// with none connected the answer says so.
class InboxToolSet extends ServerToolSet {
  const InboxToolSet(this._attention);

  final ServerAttention _attention;

  @override
  List<Map<String, Object?>> get schemas => inboxToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(
    () => switch (tool) {
      'inbox_list' => _list(includeSeen: arguments['includeSeen'] == true),
      'inbox_open' => _open(arguments['id'] as String?),
      'inbox_dismiss' => _dismiss(arguments['id'] as String?),
      _ => throw ArgumentError('Unknown tool: $tool'),
    },
  );

  /// Everything waiting on somebody, newest first. `kind` is the fact that
  /// matters: `needsApproval` and `failed` will not restart themselves.
  Object? _list({required bool includeSeen}) {
    final inbox = _attention.inbox;
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
            // When it entered the inbox, not when it happened at the agent.
            'noticedAt': item.at.toIso8601String(),
          },
      ],
    };
  }

  /// Marks the item seen and asks every window to show its session: an event
  /// then leaves the inbox and a condition stays. Both are read back, and so
  /// is whether any window was there to show it.
  Object? _open(String? id) {
    final opened = _attention.open(_idOf(id));
    final item = opened.item;
    final shown = opened.windows > 0;
    return <String, Object?>{
      'id': item.id,
      'opened': item.session.label,
      'sessionId': item.session.openId,
      'seen': true,
      'stillListed': opened.stillListed,
      'note': [
        if (!shown)
          'No Karmashala window is connected, so nothing was brought to the '
              'front; the item was marked seen.',
        opened.stillListed
            ? 'Still listed: looking at a question does not answer it. Use '
                  'session_answer to answer it.'
            : 'Gone from the inbox: an event you have looked at is done with.',
      ].join(' '),
    };
  }

  /// Takes an item off the list without opening anything. Nothing re-files
  /// an event kind; a condition that still holds comes back on the next pass.
  Object? _dismiss(String? id) {
    final item = _itemOf(_idOf(id));
    _attention.handle(InboxDismiss(item.id), null);
    return <String, Object?>{
      'id': item.id,
      'dismissed': true,
      'mayReturn': item.kind.isCondition,
    };
  }

  String _idOf(String? id) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required. inbox_list has the ids.');
    }
    _itemOf(id);
    return id;
  }

  InboxItem _itemOf(String id) {
    for (final item in _attention.inbox.items) {
      if (item.id == id) return item;
    }
    throw StateError('Nothing in the inbox with id $id.');
  }
}

/// The schemas for [InboxToolSet] — the app's, unchanged.
const List<Map<String, Object?>> inboxToolSchemas = [
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
];
