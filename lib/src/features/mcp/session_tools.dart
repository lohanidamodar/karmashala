import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agents/application/agent_providers.dart';
import '../agents/domain/agent_status.dart';
import '../sessions/application/session_actions.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/domain/session.dart';
import '../sessions/domain/session_event_types.dart';
import '../terminal/application/terminal_sessions_controller.dart';
import '../terminal/data/terminal_grid_text.dart';

/// Operating a session that already exists: talk to it, read it, rename it,
/// end it.
///
/// The tools that *start* sessions live in `LauncherControlServer` because they
/// were there first. These are the other half — an agent that can open a
/// session but cannot then say anything to it, or find out what it said back,
/// can only fire and forget.
///
/// Every one of them takes an optional `sessionId` and falls back to the
/// caller's own. The fallback is the caller the *transport* authenticated, never
/// an argument, so "act on me" cannot be spelled as "act on someone else".
class SessionControlTools {
  SessionControlTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// Which session is calling, when one is. Null for the launcher or a bridge
  /// started by hand, which are unattributed and must name a target.
  final String? callerSessionId;

  static const Set<String> _names = <String>{
    'session_send',
    'session_answer',
    'session_transcript',
    'session_rename',
    'session_end',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'session_send' => _send(
          _target(args),
          (args['text'] as String?) ?? '',
        ),
        'session_answer' => _answer(
          _target(args),
          (args['decision'] as String?) ?? '',
        ),
        'session_transcript' => _transcript(
          _target(args),
          (args['limit'] as num?)?.round() ?? 20,
        ),
        'session_rename' => _rename(
          _target(args),
          (args['title'] as String?) ?? '',
        ),
        'session_end' => _end(_target(args)),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// The session a call is aimed at.
  ///
  /// An explicit `sessionId` is a *target*, not a credential: it says what to
  /// act on and never who is asking. Naming nothing means "me", and a caller
  /// with no identity of its own has to say which session it means.
  String _target(Map<String, dynamic> args) {
    final named = args['sessionId'] as String?;
    if (named != null && named.trim().isNotEmpty) return named.trim();
    final caller = callerSessionId;
    if (caller != null && caller.isNotEmpty) return caller;
    throw ArgumentError(
      'No sessionId, and this caller is not running inside a session, so '
      'there is no "this session" to fall back to. Pass sessionId — '
      'list_sessions has the ids.',
    );
  }

  Session _session(String id) {
    final session = _container.read(sessionDaoProvider).getById(id);
    if (session == null) {
      throw StateError('No session with id $id.');
    }
    return session;
  }

  Future<Object?> _send(String sessionId, String text) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('text is required and cannot be blank.');
    }
    final session = _session(sessionId);
    // Through SessionActions, which is what the message box uses: a PTY-hosted
    // session is typed into and a headless one is messaged through the engine,
    // and an agent must not get a third answer to that question.
    await _container.read(sessionActionsProvider).continueSession(
      sessionId,
      text,
    );
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'delivered': true,
      'live': _container.read(sessionLauncherProvider).livePaneFor(sessionId) !=
          null,
    };
  }

  /// Answers an approval prompt by pressing the key the *agent* names for it.
  ///
  /// Nothing here invents a binding. The keys come from the agent's own
  /// [AgentApprovalRules], exactly as the approval card and the mobile
  /// companion do, and an agent that names no way to decline from outside its
  /// terminal is reported as such rather than guessed at with Esc.
  Future<Object?> _answer(String sessionId, String decision) async {
    if (decision != 'approve' && decision != 'deny') {
      throw ArgumentError("decision must be 'approve' or 'deny'.");
    }
    final session = _session(sessionId);
    final agentId = _container
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final rules = agentId == null
        ? const AgentApprovalRules()
        : _container.read(agentRegistryProvider).byId(agentId)?.approval ??
              const AgentApprovalRules();
    final key = decision == 'approve' ? rules.approve : rules.deny;
    if (key == null) {
      throw StateError(
        'This agent names no way to $decision from outside its terminal, so '
        'there is no key to press. Answer it in the pane.',
      );
    }
    // Named rather than left to default to "the user": an agent answering
    // another agent's prompt is a different fact, and the decision record this
    // write lands in is read by somebody who was not there.
    if (!_container.read(sessionLauncherProvider).answerPrompt(
      sessionId,
      key.keys,
      decidedBy: callerSessionId == null
          ? 'an agent through the MCP bridge'
          : 'an agent in session $callerSessionId',
      decidedBySessionId: callerSessionId,
    )) {
      throw StateError(
        'This session has no live terminal to answer in.',
      );
    }
    return <String, Object?>{
      'sessionId': sessionId,
      'answered': key.label,
      'effect': key.effect,
    };
  }

  /// What this session has said, from whichever records exist.
  ///
  /// Two sources, and which one answered is part of the answer. The event log
  /// is populated only for headless adapter sessions; a PTY-hosted session —
  /// the normal case — writes its conversation to the agent's own store and
  /// shows it on a screen we can read the tail of. A source with nothing in it
  /// reports **"not recorded"**, never an empty list dressed as "it said
  /// nothing": those are different facts and a model acting on the wrong one
  /// concludes the session is idle when it is mid-turn.
  Object? _transcript(String sessionId, int limit) {
    final session = _session(sessionId);
    final capped = limit <= 0 ? 20 : (limit > 200 ? 200 : limit);

    final events = _container
        .read(sessionEventDaoProvider)
        .listForSession(sessionId)
        .where(
          (event) =>
              event.type == SessionEventTypes.userMessage ||
              event.type == SessionEventTypes.agentMessage,
        )
        .toList();
    final recent = events.length > capped
        ? events.sublist(events.length - capped)
        : events;

    final launcher = _container.read(sessionLauncherProvider);
    final paneId = launcher.livePaneFor(sessionId);
    final instance = paneId == null
        ? null
        : _container
              .read(terminalSessionsControllerProvider.notifier)
              .instanceFor(paneId);
    final screen = instance == null
        ? null
        : terminalTailLines(instance.terminal, lines: capped);

    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'status': session.status.name,
      'live': paneId != null,
      'turns': <Object?>[
        for (final event in recent)
          <String, Object?>{
            'seq': event.seq,
            'role': event.type == SessionEventTypes.userMessage
                ? 'user'
                : 'agent',
            'at': event.createdAt.toIso8601String(),
            'text': _textOf(event.payload),
          },
      ],
      'omittedTurns': events.length - recent.length,
      // Two honest absences, said differently on purpose: the log genuinely
      // holds nothing for a PTY session, and the screen cannot be read when
      // nothing is running.
      'turnsSource': events.isEmpty
          ? 'not recorded — this session has no event log; read screen instead'
          : 'session event log',
      'screen': screen,
      'screenSource': screen == null
          ? 'not recorded — no live pane to read'
          : 'the pane as it stands now',
    };
  }

  /// The `text` of a message payload, or the payload itself when it is not one
  /// this app wrote. Never an exception: a transcript that refuses to render
  /// because one row is odd is worse than a row that renders oddly.
  static String _textOf(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['text'] is String) {
        return decoded['text'] as String;
      }
    } on FormatException {
      // Not JSON. Fall through to the raw payload.
    }
    return payload;
  }

  Object? _rename(String sessionId, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('title is required and cannot be blank.');
    }
    _session(sessionId);
    _container.read(sessionActionsProvider).renameNative(sessionId, trimmed);
    return <String, Object?>{'sessionId': sessionId, 'title': trimmed};
  }

  /// Ends the agent process behind a session.
  ///
  /// The row and its transcript survive — this is "stop working", not "delete".
  /// A session with no live pane is reported as already stopped rather than
  /// silently succeeding, because "I ended it" and "there was nothing to end"
  /// are different answers and only one of them means the agent has stopped
  /// spending tokens.
  Object? _end(String sessionId) {
    final session = _session(sessionId);
    final paneId = _container.read(sessionLauncherProvider).livePaneFor(
      sessionId,
    );
    if (paneId == null) {
      throw StateError(
        'That session has no live pane; nothing is running to end.',
      );
    }
    _container
        .read(terminalSessionsControllerProvider.notifier)
        .endSession(paneId);
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'ended': true,
      'paneId': paneId,
    };
  }
}

/// The schemas for [SessionControlTools].
const List<Map<String, dynamic>> sessionControlToolSchemas = [
  {
    'name': 'session_send',
    'description':
        'Send a message to a session, exactly as typing it into that '
        'session\'s message box would. Omit sessionId to send to the session '
        'you are running in. A session whose agent has stopped is relaunched '
        'and resumed first, so this works whether or not it is live.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description':
              'Which session. Defaults to the calling session. This selects a '
              'target; it does not change who you are.',
        },
        'text': {'type': 'string', 'description': 'The message to send.'},
      },
      'required': ['text'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'delivered': {'type': 'boolean'},
        'live': {
          'type': 'boolean',
          'description': 'Whether the session has a live pane.',
        },
      },
      'required': ['sessionId', 'delivered'],
    },
  },
  {
    'name': 'session_answer',
    'description':
        'Answer a session\'s on-screen approval prompt by pressing the key '
        'that agent itself names for approve or deny. Fails, rather than '
        'guessing, when the agent names no key for the decision you asked for '
        '— many agents say how to approve and never say how to decline. Use '
        'session_transcript first to see what is being asked.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Which session. Defaults to the calling session.',
        },
        'decision': {
          'type': 'string',
          'enum': ['approve', 'deny'],
          'description': 'What to answer.',
        },
      },
      'required': ['decision'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'answered': {
          'type': 'string',
          'description': "The agent's own label for the key that was pressed.",
        },
        'effect': {'type': 'string'},
      },
      'required': ['sessionId', 'answered'],
    },
  },
  {
    'name': 'session_transcript',
    'description':
        'Read what a session has said. Returns its recorded turns and, when it '
        'has a live pane, the current screen. Either source may be absent: a '
        'PTY-hosted session keeps no event log, and a stopped session has no '
        'screen. An absent source says "not recorded" — it is never reported '
        'as the session having said nothing.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Which session. Defaults to the calling session.',
        },
        'limit': {
          'type': 'number',
          'description': 'Most recent turns and screen lines (default 20).',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'status': {'type': 'string'},
        'live': {'type': 'boolean'},
        'turns': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'seq': {'type': 'number'},
              'role': {'type': 'string', 'enum': ['user', 'agent']},
              'at': {'type': 'string'},
              'text': {'type': 'string'},
            },
            'required': ['seq', 'role', 'text'],
          },
        },
        'omittedTurns': {'type': 'number'},
        'turnsSource': {'type': 'string'},
        'screen': {
          'type': ['array', 'null'],
          'items': {'type': 'string'},
        },
        'screenSource': {'type': 'string'},
      },
      'required': ['sessionId', 'turns', 'turnsSource', 'screenSource'],
    },
  },
  {
    'name': 'session_rename',
    'description':
        'Rename a session. The title is what every list and tab shows, so this '
        'is how a session stops being called "Agent session".',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Which session. Defaults to the calling session.',
        },
        'title': {'type': 'string', 'description': 'The new title.'},
      },
      'required': ['title'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
      },
      'required': ['sessionId', 'title'],
    },
  },
  {
    'name': 'session_end',
    'description':
        'Stop the agent process behind a session. DESTRUCTIVE: the turn in '
        'flight is lost and nothing brings it back. The session row and its '
        'transcript survive, and open_session will resume it. Fails if the '
        'session has no live pane, rather than reporting success for something '
        'that was already stopped.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description':
              'Which session. Defaults to the calling session — which ends '
              'YOUR OWN agent, mid-turn. Name a session id unless that is '
              'genuinely what you mean.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'ended': {'type': 'boolean'},
        'paneId': {'type': 'string'},
      },
      'required': ['sessionId', 'ended'],
    },
  },
];
