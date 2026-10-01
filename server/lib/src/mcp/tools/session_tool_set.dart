import 'dart:async';
import 'dart:convert';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;
import 'package:karmashala_session_engine/store.dart' show SessionDao;

import '../../domain/session_registry.dart';
import '../../status/daemon_prompt_answers.dart';
import '../../status/hosted_session_wait.dart';
import 'server_tool_context.dart';
import 'server_tool_set.dart';
import 'session_tool_schemas.dart';
import 'package:agent_cli/stream.dart';

/// **Operating a session that already exists**, by the server — `session_send`,
/// `session_answer`, `session_wait`, `session_transcript`, `session_rename`,
/// `session_end` — for every session (slice 5b: every agent runs in the
/// server, so nothing is handed to an app). Its status, its screen and its PTY
/// are the server's; a session not running here is answered from what the
/// server knows — a transcript from the record, a wait that reads `ended` —
/// and a message to one is its resume, the message its opening prompt.
class SessionToolSet extends ServerToolSet {
  SessionToolSet(
    this._context, {
    required this.prompts,
    required this.registry,
    this.resumeWith,
    HostedSessionWait? waits,
    SessionMessageTypist? typist,
  }) : _sessions = SessionDao(_context.database),
       waits = waits ?? HostedSessionWait(status: prompts.status) {
    this.typist = typist ?? typistOver(prompts);
  }

  final ServerToolContext _context;
  final DaemonPromptAnswers prompts;
  final SessionRegistry registry;

  /// Resumes a session that is not running with [prompt] as its opening
  /// message, and shows it in the person's window; null refuses instead.
  final Future<void> Function(String sessionId, String prompt)? resumeWith;
  final HostedSessionWait waits;
  late final SessionMessageTypist typist;
  final SessionDao _sessions;

  static const _names = {
    'session_send',
    'session_answer',
    'session_wait',
    'session_transcript',
    'session_rename',
    'session_end',
  };

  @override
  List<Map<String, Object?>> get schemas => sessionControlToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    if (!_names.contains(tool)) return null;
    final String sessionId;
    try {
      sessionId = targetSessionOf(arguments, callerSessionId);
    } on ArgumentError catch (error) {
      return Future.error(error);
    }
    // Held: one of the server's own PTYs, or its copy of an SSH box session.
    // A held session is never resumed — its agent is still live.
    final held = prompts.status.holds(sessionId);
    final runsHere = _runsHere(sessionId);
    switch (tool) {
      case 'session_answer':
        // A prompt is answered off the screen of the server that runs it.
        return runTool(() {
          if (held && !runsHere) {
            _session(sessionId);
            throw StateError(_onBoxRefusal('answer its prompt'));
          }
          if (!held) {
            _session(sessionId);
            throw StateError(
              'Nothing is running that session, so there is no prompt to '
              'answer. open_session resumes it.',
            );
          }
          return _answer(sessionId, arguments['decision'], callerSessionId);
        });
      case 'session_send':
        return runTool(
          () => _send(
            sessionId,
            (arguments['text'] as String?) ?? '',
            callerSessionId: callerSessionId,
            wait: arguments['wait'] == true,
            timeoutSeconds: arguments['timeoutSeconds'] as num?,
            held: held,
          ),
        );
      case 'session_wait':
        return runTool(
          () => _wait(
            sessionId,
            timeoutSeconds: arguments['timeoutSeconds'] as num?,
          ),
        );
      case 'session_transcript':
        return runTool(
          () => _transcript(
            sessionId,
            (arguments['limit'] as num?)?.round() ?? 20,
            held: held,
          ),
        );
      case 'session_rename':
        return runTool(
          () => _rename(sessionId, (arguments['title'] as String?) ?? ''),
        );
      case 'session_end':
        return runTool(() {
          if (held && !runsHere) {
            _session(sessionId);
            throw StateError(_onBoxRefusal('end it'));
          }
          return _end(sessionId, held: runsHere);
        });
    }
    return null;
  }

  /// Whether this server runs the session [sessionId] in its own PTY.
  bool _runsHere(String sessionId) =>
      prompts.status.runningSessionOf(sessionId) != null;

  static String _onBoxRefusal(String act) =>
      'That session is still running on an SSH box, and this tool cannot '
      '$act there. Nothing was done. Do it from its pane.';

  Session _session(String id) {
    final session = _sessions.getById(id);
    if (session == null) throw StateError('No session with id $id.');
    return session;
  }

  Future<Object?> _answer(
    String sessionId,
    Object? decision,
    String? callerSessionId,
  ) async {
    if (decision != 'approve' && decision != 'deny') {
      throw ArgumentError("decision must be 'approve' or 'deny'.");
    }
    _session(sessionId);
    final SessionApprovalAnswer answer;
    try {
      answer = await prompts.answers.answer(
        ApprovalAnswerRequest(
          sessionId: sessionId,
          approve: decision == 'approve',
          // The caller read the screen; the menu reader and the question
          // guard still stand between it and a blind Enter.
          requireOpenPrompt: false,
          // Named rather than left to default to "the user": the decision
          // record this lands in is read by somebody who was not there.
          decidedBy: callerSessionId == null
              ? 'an agent through the MCP bridge'
              : 'an agent in session $callerSessionId',
          decidedBySessionId: callerSessionId,
        ),
      );
    } on SessionPromptRefusal catch (refusal) {
      final message = refusal.message;
      throw StateError(
        '${message[0].toUpperCase()}${message.substring(1)}'
        '${message.endsWith('.') ? '' : '.'} Answer it in the pane.',
      );
    }
    return <String, Object?>{
      'sessionId': sessionId,
      'answered': answer.answered,
      'effect': answer.effect,
    };
  }

  /// Relays [text] into [sessionId]'s composer under the sender's own name;
  /// the delivery is a keystroke, so an open prompt or question refuses it.
  Future<Object?> _send(
    String sessionId,
    String text, {
    required String? callerSessionId,
    bool wait = false,
    num? timeoutSeconds,
    bool held = true,
  }) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('text is required and cannot be blank.');
    }
    final session = _session(sessionId);
    if (!held && resumeWith == null) {
      throw StateError(
        'That session is not running, so there is nothing to type into. '
        'open_session resumes it.',
      );
    }
    final report = prompts.status.statusOf(sessionId)?.report;
    if (report?.hasOpenQuestion ?? false) {
      throw StateError(
        'That session is asking a multiple-choice question, so this would '
        'type into the question rather than send a message. Read it with '
        'session_transcript and answer it in the terminal or from the '
        'companion app, or wait for it to be answered and send then.',
      );
    }
    if (report?.hasOpenPrompt ?? false) {
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
    if (wait) {
      if (waits.blockedOn(sessionId) case final block?) {
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
    final relayed = caller != null && caller != sessionId;
    final now = _context.now();
    if (relayed) {
      final sent = _context.write(
        RelayCount(
          fromSessionId: caller,
          toSessionId: sessionId,
          since: now.subtract(relayBudgetWindow),
        ),
      );
      if (sent >= relayBudget) {
        throw StateError(
          'NOTHING WAS SENT: this session has already sent $sent messages to '
          'that one in the last ${relayBudgetWindow.inMinutes} minutes, which '
          'is the most one session may send another. Retrying will not help '
          'until the window moves on. Two sessions trading turns this fast is '
          'usually a loop; raise a review thread or ask the user instead.',
        );
      }
    }
    final sender = relayed ? _sessions.getById(caller) : null;
    final attribution = sender == null
        ? null
        : SessionAttribution(sessionId: sender.id, title: sender.title);
    final message = attribution == null ? text : attribution.render(text);
    // Not running: the message is its resume's opening prompt, as the app's
    // composer resumed a stopped session with what was typed.
    final delivered = held
        ? await typist.send(sessionId, message)
        : await resumeWith!(sessionId, message).then((_) => true);
    if (!delivered) {
      throw StateError(
        'That session\'s process ended before the message could be typed '
        'into it. open_session resumes it.',
      );
    }
    if (relayed) {
      _context.write(
        RelayRecord(
          SessionRelay(
            fromSessionId: caller,
            toSessionId: sessionId,
            text: text,
            at: now,
          ),
        ),
      );
    }
    final answer = <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'delivered': true,
      // The exact line the recipient sees above the message. Null is the
      // honest answer, never a claim that it went in as the user.
      'attribution': attribution?.line,
      'live': true,
      if (!held) 'resumed': true,
    };
    if (!wait) return answer;
    // `inputSent: true` is the fact a timeout has to carry: a caller that
    // retries because its bound ran out submits the same work twice.
    final outcome = await waits.wait(
      sessionId,
      bound: sessionWaitBoundFor(timeoutSeconds),
      inputSent: true,
    );
    return <String, Object?>{...answer, ...renderWaitOutcome(outcome)};
  }

  /// Blocks until [sessionId] settles, and says what it settled on.
  Future<Object?> _wait(String sessionId, {num? timeoutSeconds}) async {
    final session = _session(sessionId);
    final outcome = await waits.wait(
      sessionId,
      bound: sessionWaitBoundFor(timeoutSeconds),
    );
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      ...renderWaitOutcome(outcome),
    };
  }

  /// What this session has said, and which source answered. A source with
  /// nothing in it reports "not recorded", never an empty list.
  Future<Object?> _transcript(
    String sessionId,
    int limit, {
    required bool held,
  }) async {
    final session = _session(sessionId);
    final capped = limit <= 0 ? 20 : (limit > 200 ? 200 : limit);
    final events = _context
        .write(SessionEvents(sessionId))
        .where(
          (event) =>
              event.type == SessionEventTypes.userMessage ||
              event.type == SessionEventTypes.agentMessage,
        )
        .toList();
    final recent = events.length > capped
        ? events.sublist(events.length - capped)
        : events;
    final screen = held
        ? prompts.status.liveScreenOf(sessionId)?.tailText(capped)
        : null;
    final relayed = _context.write(RelaysTo(sessionId, capped));
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'status': session.status.name,
      'live': held,
      // Beside `turns`, not in it: a relay is a message that crossed from
      // another session, recorded by Karmashala, and never a turn of the
      // user's.
      'relays': <Object?>[
        for (final relay in relayed.relays)
          <String, Object?>{
            'fromSessionId': relay.fromSessionId,
            'at': relay.at.toIso8601String(),
            'text': relay.text,
          },
      ],
      'omittedRelays': relayed.total - relayed.relays.length,
      'relaysSource':
          'messages other sessions sent this one with session_send, as '
          'Karmashala recorded them',
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
      // Two honest absences, said differently on purpose: the log holds
      // nothing for a PTY session, and the screen cannot be read with nothing
      // running.
      'turnsSource': events.isEmpty
          ? 'not recorded — this session has no event log; read screen instead'
          : 'session event log',
      'screen': screen,
      'screenSource': screen == null
          ? 'not recorded — no live pane to read'
          : 'the pane as it stands now',
    };
  }

  /// The `text` of a message payload, or the payload itself when it is not
  /// one Karmashala wrote. Never throws: one odd row must not stop a
  /// transcript.
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
    // `byUser` is what stops the title sync taking it back, for the life of
    // the row.
    _context.write(
      SessionEdit(sessionId, SessionPatch.rename(trimmed, byUser: true)),
    );
    return <String, Object?>{'sessionId': sessionId, 'title': trimmed};
  }

  /// Ends the agent process behind a session this server runs; the row and
  /// its transcript survive, and the ending is recorded as the server's.
  /// Nothing running is reported as already stopped, never as a success.
  Future<Object?> _end(String sessionId, {required bool held}) async {
    final session = _session(sessionId);
    if (!held) {
      throw StateError(
        'Nothing is running that session: no pane shows it and the session '
        'host is not running it, so there is nothing to end.',
      );
    }
    try {
      await registry.close(hostSessionIdOf(sessionId));
    } on UnknownSession {
      throw StateError(
        'Nothing is running that session: no pane shows it and the session '
        'host is not running it, so there is nothing to end.',
      );
    }
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'ended': true,
      'endedAt': 'the session host',
    };
  }

  /// Types into the session's PTY as the host — its own, or a box session's
  /// over the server's link — not subject to the write token: the desktop
  /// pane that holds it is usually who asked. The Return is read back off the
  /// server's own copy of the screen.
  static SessionMessageTypist typistOver(
    DaemonPromptAnswers prompts, {
    Duration poll = const Duration(milliseconds: 50),
    Duration typedPatience = const Duration(milliseconds: 1500),
    Duration sendPatience = const Duration(seconds: 2),
  }) {
    final status = prompts.status;
    return SessionMessageTypist(
      poll: poll,
      typedPatience: typedPatience,
      sendPatience: sendPatience,
      readScreen: (sessionId) =>
          status.liveScreenOf(sessionId)?.tailText(kMenuScreenRows),
      markersFor: (sessionId) => prompts.agentOf(sessionId)?.menus?.markers,
      type: (sessionId, text) {
        if (!status.typeAsServer(sessionId, utf8.encode(text))) return false;
        // Ends the paste burst an agent like Codex takes fast typing for,
        // which would fold the Return into a newline — as the app's own
        // typist does.
        if (prompts.agentOf(sessionId)?.terminal.pasteBurstFoldsReturn ??
            false) {
          status.typeAsServer(sessionId, const [_endOfLineKey]);
        }
        return true;
      },
      press: (sessionId, keys) =>
          status.typeAsServer(sessionId, utf8.encode(keys)),
    );
  }

  /// `Ctrl+E`, `kEndOfLineKey` in `karmashala_terminal_core` (a Flutter
  /// package).
  static const int _endOfLineKey = 0x05;
}
