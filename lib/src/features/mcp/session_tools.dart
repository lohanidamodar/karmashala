import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import '../agents/application/agent_providers.dart';
import '../agents/domain/agent_status.dart';
import '../sessions/application/session_actions.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/application/session_status_providers.dart';
import '../sessions/application/session_wait.dart';
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

  /// Relays [text] into [sessionId]'s input, saying who it is from.
  ///
  /// ## Why the prefix is not optional
  ///
  /// The delivery is a keystroke: for a PTY-hosted session this ends in
  /// `terminal.textInput(text)` and a carriage return, which is character for
  /// character what the user typing into the pane produces. So an unattributed
  /// relay does not merely *look* like the user's turn — inside the receiving
  /// CLI it **is** one, and stays one in that CLI's own transcript after
  /// everything here is gone.
  ///
  /// `terminal_tools.dart` refuses `terminal_run` on an agent pane for exactly
  /// that reason and sends the caller here; `review_thread_tools.dart` names
  /// the same failure from the other side — an agent writing its own
  /// instructions and having them read as the user's. This is the door it was
  /// arriving through.
  ///
  /// ## What is named, and what is deliberately not
  ///
  /// Only a sender the *transport* established. `McpCallerRegistry` stamps the
  /// session id on the bridge process or carries it in the URL that session's
  /// own config holds, so it describes the process tree rather than something
  /// the model chose to say — a model cannot dress its message in another
  /// session's name, and cannot strip its own.
  ///
  /// Three cases are left bare, each because there is no relay to declare:
  ///
  /// - **A caller with no session of its own** — the launcher, or a bridge
  ///   started by hand. It names nobody, and a prefix naming nobody would be
  ///   invented provenance rather than a weaker version of the real thing.
  /// - **A caller talking to itself** (`sessionId` omitted, or its own id). A
  ///   note-to-self crossed no boundary.
  /// - **The user's own message box**, the delivery strip, the phone: none of
  ///   them come through here at all. They call
  ///   [SessionActions.continueSession] directly, which is why the prefix is
  ///   applied at this boundary and not down in the send.
  ///
  /// ## And why it refuses at an open approval prompt
  ///
  /// The same keystroke is the reason. When a prompt with options is on the
  /// target's screen, the characters and the carriage return are keys pressed
  /// *in that prompt*, and what they select is the CLI's business.
  ///
  /// **Measured 2026-09-04**, one message — `hold off, the branch must not
  /// change` — typed the way this tool types it at a real approval prompt in
  /// each installed CLI:
  ///
  /// | CLI | what happened |
  /// | --- | --- |
  /// | Claude Code v2.1.260 | **approved** the pending `Bash(touch …)`; the file was created and the message was never delivered |
  /// | Codex v0.151.0 | **cancelled** the request and interrupted the turn; the message was split, `ch must not change` left dangling in the composer |
  /// | Antigravity 1.1.25 | **approved**; the file was created and the message was never delivered |
  ///
  /// Three for three, no CLI treated it as a message and two of them decided
  /// something. So this refuses, and names `session_answer` — the tool that is
  /// *for* answering prompts, which presses the agent's own declared key and
  /// records who decided.
  ///
  /// Only [AgentStatusReport.hasOpenPrompt] blocks. Not "mid-turn": that is a
  /// much weaker signal, differs per CLI, and is permanently unrecorded where
  /// hooks cannot be delivered — and a message queued behind a turn is the
  /// ordinary case this tool exists for. An unknown state sends, deliberately:
  /// the gate is on positive evidence of a modal, never on the absence of
  /// evidence of one.
  ///
  /// The user's own message box is not gated, and should not be. A person
  /// typing into their own pane can see the prompt they are typing into.
  ///
  /// ## And why `wait` checks before it sends
  ///
  /// Send-then-wait is the shape a delegating agent actually wants, and the
  /// order of the two halves is the whole design. A session that has already
  /// stopped for a person will not move whatever arrives, so sending into it
  /// and then blocking would spend the caller's bound to learn nothing — and
  /// would leave the message sitting behind the prompt. So the block is checked
  /// **first**, and a blocked target is refused with nothing sent and no wait
  /// started.
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
    // Before the send, never after it. The prompt gate above already refused a
    // modal on screen, so what this catches is the wider case: a question
    // sitting in the attention inbox, which no keystroke of ours answers.
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
    // Through SessionActions, which is what the message box uses: a PTY-hosted
    // session is typed into and a headless one is messaged through the engine,
    // and an agent must not get a third answer to that question.
    await _container.read(sessionActionsProvider).continueSession(
      sessionId,
      attribution == null ? text : attribution.render(text),
    );
    final delivered = <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'delivered': true,
      // The exact line the recipient sees above the message, so a sender knows
      // whether it arrived under its own name. Null is the honest answer for
      // every case above, never a claim that it went in as the user.
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

  /// Blocks until [sessionId] settles, and says what it settled on.
  ///
  /// Read-only and idempotent in the sense the catalogue means: it changes
  /// nothing, and calling it twice is not merely safe but the *intended* answer
  /// to a timeout. The two calls may well report different states, which is a
  /// statement about the session rather than about this tool.
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

  /// One wait's answer, as the tool reports it.
  ///
  /// Every absence here is spelled as an absence. `since` and
  /// `evidenceAgeSeconds` are null when no source could tell us anything,
  /// `transcriptChanged` is null when nothing could see the conversation, and
  /// `exitCode` is null with `exitCodeKnown: false` rather than a zero — the
  /// same rule `terminal_run` holds itself to, and for the same reason.
  static Map<String, Object?> _renderWait(SessionWaitOutcome outcome) =>
      <String, Object?>{
        'state': outcome.state.name,
        // The status word behind the state, so a turn that ended in an error is
        // not flattened into "ready for input" with the reason dropped.
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

  /// The sentence a model reads before it decides what to do next.
  ///
  /// Prose rather than a flag because the two states that cost the most are
  /// both misread by a caller acting on the word alone: `idle` looks like
  /// success and is equally the shape of a session that never started, and
  /// `timeout` looks like failure when it is only this call's bound.
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
