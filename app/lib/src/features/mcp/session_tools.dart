import 'dart:convert';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:riverpod/riverpod.dart';

import '../../core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import '../sessions/application/session_actions.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/application/session_prompt_answers.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/application/session_status_providers.dart';
import '../sessions/application/session_wait.dart';
import 'package:karmashala_session/session.dart';
import 'package:agent_cli/stream.dart';
import '../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_session/events.dart';

/// Operating a session that already exists, in one of this app's own panes:
/// the server answers every call for a session it holds itself. Every tool
/// takes an optional `sessionId` and falls back to the caller the *transport*
/// authenticated.
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
  /// a credential: naming nothing means "me".
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
    final session = _container.read(sessionsDataProvider).getById(id);
    if (session == null) {
      throw StateError('No session with id $id.');
    }
    return session;
  }

  /// Relays [text] into [sessionId]'s input under the sender's own name; the
  /// delivery is a keystroke, so [AgentStatusReport.hasOpenPrompt] refuses it.
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
    if (_container
            .read(sessionStatusLookupProvider)(sessionId)
            ?.hasOpenQuestion ??
        false) {
      throw StateError(
        'That session is asking a multiple-choice question, so this would '
        'type into the question rather than send a message. Read it with '
        'session_transcript and answer it in the terminal or from the '
        'companion app, or wait for it to be answered and send then.',
      );
    }
    if (_container
            .read(sessionStatusLookupProvider)(sessionId)
            ?.hasOpenPrompt ??
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
    final relayed = caller != null && caller != sessionId;
    final relays = _container.read(sessionRecordsProvider);
    final now = _container.read(clockProvider).nowUtc();
    if (relayed) {
      final sent = await relays.relayCount(
        caller,
        sessionId,
        since: now.subtract(relayBudgetWindow),
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
    final attribution = relayed
        ? _container.read(sessionLauncherProvider).attributionFor(caller)
        : null;
    // Through SessionActions, which is what the message box uses: an agent must
    // not get a third answer to "typed into, or messaged through the engine".
    await _container
        .read(sessionActionsProvider)
        .continueSession(
          sessionId,
          attribution == null ? text : attribution.render(text),
        );
    if (relayed) {
      relays.recordRelay(
        SessionRelay(
          fromSessionId: caller,
          toSessionId: sessionId,
          text: text,
          at: now,
        ),
      );
    }
    final delivered = <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'delivered': true,
      // The exact line the recipient sees above the message. Null is the honest
      // answer, never a claim that it went in as the user.
      'attribution': attribution?.line,
      'live':
          _container.read(sessionLauncherProvider).livePaneFor(sessionId) !=
          null,
    };
    if (!wait) return delivered;
    // `inputSent: true` is the fact a timeout has to carry: a caller that
    // retries because its bound ran out submits the same work twice.
    final outcome = await _container
        .read(sessionWaitProvider)
        .wait(
          sessionId,
          bound: SessionWaitService.boundFor(timeoutSeconds),
          inputSent: true,
        );
    return <String, Object?>{...delivered, ...renderWaitOutcome(outcome)};
  }

  /// Blocks until [sessionId] settles, and says what it settled on. Calling it
  /// twice is not merely safe but the intended answer to a timeout.
  Future<Object?> _wait(String sessionId, {num? timeoutSeconds}) async {
    final session = _session(sessionId);
    final outcome = await _container
        .read(sessionWaitProvider)
        .wait(sessionId, bound: SessionWaitService.boundFor(timeoutSeconds));
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      ...renderWaitOutcome(outcome),
    };
  }

  /// Answers an approval prompt: a menu by the option the *agent's* adapter
  /// declares affirmative or negative, anything else with the key the agent
  /// names for it. Nothing invents a binding; an agent that names none is
  /// reported as such — see `SessionApprovalAnswerer`. A session this
  /// machine's host runs is answered by the host (which also answers this
  /// tool itself while it serves agents' tools); a pane of this app's here.
  Future<Object?> _answer(String sessionId, String decision) async {
    if (decision != 'approve' && decision != 'deny') {
      throw ArgumentError("decision must be 'approve' or 'deny'.");
    }
    _session(sessionId);
    final SessionApprovalAnswer answer;
    try {
      answer = await _container
          .read(sessionPromptAnswersProvider)
          .answer(
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

  /// What this session has said, and which source answered. A source with
  /// nothing in it reports "not recorded", never an empty list.
  Future<Object?> _transcript(String sessionId, int limit) async {
    final session = _session(sessionId);
    final capped = limit <= 0 ? 20 : (limit > 200 ? 200 : limit);

    final events = (await _container
            .read(sessionRecordsProvider)
            .listForSession(sessionId))
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

    final relayed = await _container
        .read(sessionRecordsProvider)
        .relaysTo(sessionId, capped);

    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'status': session.status.name,
      'live': paneId != null,
      // Beside `turns`, not in it: a relay is a message that crossed from
      // another session, recorded by the app, and never a turn of the user's.
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

  /// Ends the agent process behind a session — its live pane, or the session
  /// host's session when no pane shows it; the row and its transcript survive.
  /// Nothing running is reported as already stopped, never as a silent success.
  Future<Object?> _end(String sessionId) async {
    final session = _session(sessionId);
    final ended = await _container
        .read(sessionLauncherProvider)
        .endRunning(sessionId);
    if (ended == null) {
      throw StateError(
        'Nothing is running that session: no pane shows it and the session '
        'host is not running it, so there is nothing to end.',
      );
    }
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'ended': true,
      'paneId': ?ended.paneId,
      if (ended.atHost) 'endedAt': 'the session host (no pane showed it)',
    };
  }
}

