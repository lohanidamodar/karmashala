import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import '../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../sessions/application/session_actions.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/application/session_status_providers.dart';
import '../sessions/application/session_wait.dart';
import '../sessions/domain/session.dart';
import 'package:agent_cli/stream.dart';
import '../terminal/application/terminal_sessions_controller.dart';
import '../terminal/data/terminal_grid_text.dart';

/// Operating a session that already exists: talk to it, read it, rename it,
/// end it. The tools that *start* one live in `LauncherControlServer`.
///
/// Every one of them takes an optional `sessionId` and falls back to the caller
/// the *transport* authenticated, never an argument, so "act on me" cannot be
/// spelled as "act on someone else".
class SessionControlTools {
  SessionControlTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// Which session is calling, when one is. Null for the launcher or a bridge
  /// started by hand, which are unattributed and must name a target.
  final String? callerSessionId;

  static const Set<String> _names = <String>{
    'session_send',
    'session_answer',
    'session_wait',
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
          wait: args['wait'] == true,
          timeoutSeconds: args['timeoutSeconds'] as num?,
        ),
        'session_wait' => _wait(
          _target(args),
          timeoutSeconds: args['timeoutSeconds'] as num?,
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

  /// The session a call is aimed at. An explicit `sessionId` is a *target*, not
  /// a credential: naming nothing means "me", and a caller with no identity of
  /// its own has to say which session it means.
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

  /// Relays [text] into [sessionId]'s input, saying who it is from.
  ///
  /// The delivery is a keystroke, so an unattributed relay *is* the user's turn
  /// inside the receiving CLI and stays one in that CLI's transcript. The prefix
  /// names only a sender the transport established; a caller talking to itself,
  /// or with no session of its own, is left bare.
  ///
  /// Refused while [AgentStatusReport.hasOpenPrompt] — measured against all three
  /// installed CLIs, none delivered the text and two decided the pending request
  /// — but an unknown state sends: the gate is positive evidence of a modal,
  /// never the absence of it. `wait` checks the block **first**, so a target
  /// already stopped for a person is refused with nothing sent.
  Future<Object?> _send(
    String sessionId,
    String text, {
    bool wait = false,
    num? timeoutSeconds,
  }) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('text is required and cannot be blank.');
    }
    final session = _session(sessionId);
    if (_container.read(sessionStatusLookupProvider)(sessionId)?.hasOpenPrompt ??
        false) {
      throw StateError(
        'That session has an approval prompt open, so this would press keys in '
        'that prompt rather than send a message — measured against all three '
        'CLIs, none delivered the text and two of them decided the pending '
        'request. Read what is being asked with session_transcript and answer '
        'it with session_answer, which presses the key that agent itself names '
        'and records who decided. Or wait for the prompt to clear and send '
        'then.',
      );
    }
    // Before the send, never after it. The prompt gate above refused a modal;
    // this catches a question sitting in the attention inbox.
    if (wait) {
      if (_container.read(sessionWaitProvider).blockedOn(sessionId)
          case final block?) {
        throw StateError(
          'That session is already blocked on a person (${block.kind}), so '
          'NOTHING WAS SENT and no wait was started. A message into a session '
          'that has stopped for an approval or a question sits behind it, and '
          'this call would have blocked until its bound to learn nothing. Read '
          'what is being asked with session_transcript and answer it with '
          'session_answer, then send.'
          '${block.text == null ? '' : ' It is asking: ${block.text}'}',
        );
      }
    }
    final caller = callerSessionId;
    final attribution = caller == null || caller == sessionId
        ? null
        : _container.read(sessionLauncherProvider).attributionFor(caller);
    // Through SessionActions, which is what the message box uses: an agent must
    // not get a third answer to "typed into, or messaged through the engine".
    await _container.read(sessionActionsProvider).continueSession(
      sessionId,
      attribution == null ? text : attribution.render(text),
    );
    final delivered = <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'delivered': true,
      // The exact line the recipient sees above the message. Null is the honest
      // answer, never a claim that it went in as the user.
      'attribution': attribution?.line,
      'live': _container.read(sessionLauncherProvider).livePaneFor(sessionId) !=
          null,
    };
    if (!wait) return delivered;
    // `inputSent: true` is the fact a timeout has to carry: a caller that
    // retries because its bound ran out submits the same work twice.
    final outcome = await _container.read(sessionWaitProvider).wait(
      sessionId,
      bound: SessionWaitService.boundFor(timeoutSeconds),
      inputSent: true,
    );
    return <String, Object?>{...delivered, ..._renderWait(outcome)};
  }

  /// Blocks until [sessionId] settles, and says what it settled on. Calling it
  /// twice is not merely safe but the intended answer to a timeout; two
  /// different answers are a statement about the session, not about this tool.
  Future<Object?> _wait(String sessionId, {num? timeoutSeconds}) async {
    final session = _session(sessionId);
    final outcome = await _container.read(sessionWaitProvider).wait(
      sessionId,
      bound: SessionWaitService.boundFor(timeoutSeconds),
    );
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      ..._renderWait(outcome),
    };
  }

  /// One wait's answer, as the tool reports it. Every absence is spelled as an
  /// absence: `exitCode` is null with `exitCodeKnown: false` rather than a zero,
  /// the same rule `terminal_run` holds itself to.
  static Map<String, Object?> _renderWait(SessionWaitOutcome outcome) =>
      <String, Object?>{
        'state': outcome.state.name,
        // So a turn that ended in an error is not flattened into "ready for
        // input" with the reason dropped.
        'agentStatus': outcome.agentStatus.name,
        'evidenceSource': outcome.source.name,
        'since': outcome.since?.toIso8601String(),
        'evidenceAgeSeconds': outcome.evidenceAge?.inSeconds,
        'changed': outcome.changed,
        'transcriptChanged': outcome.transcriptChanged,
        'transcriptChangedSource': outcome.transcriptChanged == null
            ? 'not recorded — this session\'s status carries no transcript '
                  'position, so whether it said anything is unknown'
            : 'the transcript this session\'s status is read from',
        'blockedOn': outcome.blockedOn == null
            ? null
            : <String, Object?>{
                'kind': outcome.blockedOn!.kind,
                'text': outcome.blockedOn!.text,
              },
        'exitCode': outcome.exitCode,
        'exitCodeKnown': outcome.exitCodeKnown,
        'inputSent': outcome.inputSent,
        'note': _noteFor(outcome),
      };

  /// The sentence a model reads before it decides what to do next. Prose rather
  /// than a flag because the costly states are misread on the word alone: `idle`
  /// is equally the shape of a session that never started, and `timeout` is only
  /// this call's bound.
  static String _noteFor(SessionWaitOutcome outcome) =>
      switch (outcome.state) {
        SessionWaitState.idle =>
          'Ready for input, and nothing moved while this call watched. That is '
              'not proof it did anything: a session that never started reads '
              'exactly like one that finished before you asked. "done" is the '
              'state that means it moved.',
        SessionWaitState.done =>
          'Ready for input, and its evidence moved while this call watched — it '
              'finished something. What it finished is in session_transcript; '
              'this says only that it stopped.',
        SessionWaitState.blocked =>
          'BLOCKED ON A PERSON. This session has stopped for an approval or a '
              'question and will not move until somebody answers it — waiting '
              'longer will not change that. Anything you send now lands in that '
              'prompt as a keystroke rather than arriving as a message. Read '
              'what is being asked with session_transcript and answer it with '
              'session_answer, or leave it for the user.',
        SessionWaitState.ended =>
          'The pane behind this session is gone. session_transcript still reads '
              'its record, and open_session will resume it. '
              '${outcome.exitCodeKnown ? 'It exited with ${outcome.exitCode}.' : 'Its exit code is UNKNOWN — not 0; nothing told us what it exited with.'}',
        SessionWaitState.timeout =>
          'TIMEOUT — this is your bound, not a verdict about the session. It is '
              'STILL RUNNING and may finish a moment from now. '
              '${outcome.inputSent ?? false ? 'YOUR MESSAGE WAS ALREADY DELIVERED (inputSent: true): a timeout does not prove nothing was sent, so do not send it again' : 'This call sent nothing (inputSent is null)'}'
              '. Read the session with session_transcript, or call session_wait '
              'to go on waiting.',
      };

  /// Answers an approval prompt by pressing the key the *agent* names for it.
  /// Nothing here invents a binding: an agent that names no way to decline from
  /// outside its terminal is reported as such rather than guessed at with Esc.
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
    // Named rather than left to default to "the user": the decision record this
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

  /// What this session has said, from whichever records exist — and which
  /// source answered is part of the answer. A source with nothing in it reports
  /// **"not recorded"**, never an empty list dressed as "it said nothing": a
  /// model acting on the wrong one concludes the session is idle when it is
  /// mid-turn.
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
      // Two honest absences, said differently on purpose: the log holds nothing
      // for a PTY session, and the screen cannot be read with nothing running.
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
  /// this app wrote. Never throws: one odd row must not stop a transcript.
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

  /// Ends the agent process behind a session; the row and its transcript
  /// survive. A session with no live pane is reported as already stopped rather
  /// than silently succeeding — only one of those means it stopped spending
  /// tokens.
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
        'and resumed first, so this works whether or not it is live. A message '
        'to another session arrives with a line naming yours, so the recipient '
        'reads it as a request from a peer rather than as an instruction from '
        'the user; the line is built from the session the transport '
        'authenticated, so you can neither borrow another name nor drop your '
        'own. Refused while the target has an approval prompt open: the '
        'keystrokes would land in that prompt instead — answer it with '
        'session_answer, or wait. Pass wait: true to block until the session '
        'settles afterwards — the common send-then-wait shape. The block is '
        'checked BEFORE the send, so a target already waiting on a person is '
        'refused with nothing sent.',
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
        'wait': {
          'type': 'boolean',
          'description':
              'Block until the session settles after delivering, adding every '
              'session_wait field to the result. Refused before sending if the '
              'target is already blocked on a person.',
        },
        'timeoutSeconds': {
          'type': 'number',
          'description':
              'How long to wait, when wait is true. Default 30, capped at 45.',
        },
      },
      'required': ['text'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'delivered': {'type': 'boolean'},
        'attribution': {
          'type': ['string', 'null'],
          'description':
              'The line prepended to the message naming you as its sender, or '
              'null when nothing was prepended — a message to yourself, or a '
              'caller running in no session of ours.',
        },
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
    'name': 'session_wait',
    'description':
        'Block until a session settles, so you can hand work to another agent '
        'and know when it is done instead of re-reading its transcript on a '
        'loop. Five answers. "idle" and "done" both mean ready for input, and '
        'they are two states on purpose: "done" is idle-and-seen-changed, so a '
        'session that finished something does not read like one that never '
        'started. "blocked" means it has stopped for a person — an approval or '
        'a question — and names what it is waiting on. "ended" means the pane '
        'is gone, with the exit code when one was learned and never a zero '
        'when none was. "timeout" is YOUR bound and not a verdict: the session '
        'is still running, and inputSent says whether anything was delivered, '
        'so call again rather than sending the same work twice. Nothing here '
        'polls — the wait completes on the events the app already sees.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description':
              'Which session. Defaults to the calling session — which would '
              'wait for YOU, and never settle. Name the session you delegated '
              'to.',
        },
        'timeoutSeconds': {
          'type': 'number',
          'description':
              'How long to block. Default 30, capped at 45 — the transports '
              'between you and this app give up at 60.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'state': {
          'type': 'string',
          'enum': ['idle', 'done', 'blocked', 'ended', 'timeout'],
        },
        'agentStatus': {
          'type': 'string',
          'description':
              'The status word behind the state, so a turn that ended in an '
              'error is not flattened into "ready for input".',
        },
        'evidenceSource': {
          'type': 'string',
          'description':
              'What told us: hook, stateFile, terminalGrid, or none.',
        },
        'since': {
          'type': ['string', 'null'],
          'description':
              'When the evidence was produced — never when we looked. Null '
              'when no source could tell us anything.',
        },
        'evidenceAgeSeconds': {
          'type': ['number', 'null'],
          'description': 'How old that evidence was when this answered.',
        },
        'changed': {
          'type': 'boolean',
          'description':
              'Whether the session moved while this call watched. The one '
              'thing that separates done from idle.',
        },
        'transcriptChanged': {
          'type': ['boolean', 'null'],
          'description':
              'Whether the conversation moved, or null when no source could '
              'see it — which is never the same as "it said nothing".',
        },
        'transcriptChangedSource': {'type': 'string'},
        'blockedOn': {
          'type': ['object', 'null'],
          'description':
              'What it is waiting on, in the source\'s own words. Null unless '
              'the state is blocked.',
          'properties': {
            'kind': {'type': 'string'},
            'text': {'type': ['string', 'null']},
          },
        },
        'exitCode': {'type': ['number', 'null']},
        'exitCodeKnown': {
          'type': 'boolean',
          'description':
              'Read this before believing exitCode. A missing code is UNKNOWN '
              '— it is never a zero.',
        },
        'inputSent': {
          'type': ['boolean', 'null'],
          'description':
              'Whether this call delivered anything before waiting. Null means '
              'it sent nothing, which is a third answer and not a false.',
        },
        'note': {'type': 'string'},
      },
      'required': ['sessionId', 'state', 'changed', 'note'],
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
