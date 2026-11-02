import 'dart:async';
import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

import '../domain/uuid.dart';
import '../sessions/session_subagents.dart' show boundedText;

/// How often a request past its time is looked for.
const Duration kBotApprovalSweep = Duration(seconds: 30);

/// The most of a recorded call's result the bot is told.
const int kBotOutcomeMaxChars = 4000;

/// What the bot reads instead of a result. Nothing blocks: the bridge bounds a
/// call, and an approval after that bound could run what the agent saw fail.
String botApprovalHeld(BotApproval request) =>
    'Not done. This call is waiting for the person\'s approval '
    '(${request.id}): ${request.summary}. It has not run. If they say Yes the '
    'server runs it itself, so do not call it again. Tell them what you asked '
    'for, then end your turn; you will be told the outcome.';

/// The tool and its target in plain words: what a person says Yes to.
String botApprovalSummary(
  String tool,
  Map<String, dynamic> arguments, {
  String? Function(String sessionId)? sessionTitle,
}) {
  final words = tool.replaceAll('_', ' ');
  final named = arguments['sessionId'];
  if (named is String && named.isNotEmpty) {
    final title = sessionTitle?.call(named);
    return title == null ? '$words: session $named' : '$words: "$title"';
  }
  for (final key in const [
    'command',
    'path',
    'url',
    'title',
    'name',
    'projectId',
    'repositoryId',
    'id',
    'serial',
    'paneId',
  ]) {
    final value = arguments[key];
    if (value is String && value.trim().isNotEmpty) {
      return '$words: ${boundedText(value.trim(), 200).$1}';
    }
  }
  return arguments.isEmpty
      ? '$words: this bot session'
      : '$words: ${boundedText(jsonEncode(arguments), 200).$1}';
}

/// **The bot asks before it does what cannot be undone.** A tool call annotated
/// `destructive` from the bot is not run: [hold] records the exact call and
/// answers at once, in words the agent reads. A person's Yes atomically takes
/// the request ([answer]) and **the server itself** runs the recorded call, so
/// the agent never retries it and only what the person saw can run. No, or
/// expiry after [kBotApprovalLifetime], runs nothing. Either way one message
/// tells the bot how it ended ([post]), resuming it if it was stopped.
///
/// This covers Karmashala tools the bot itself calls, and only those: what
/// its agent runs in its own shell is governed by its permission mode, and a
/// session it messages by that session's. It is not a sandbox.
class BotApprovals {
  BotApprovals({
    required AppDatabase database,
    required this.run,
    required this.post,
    required this.announce,
    this.raise,
    this.retire,
    this.log,
    DateTime Function()? now,
    String Function()? newId,
  }) : _sessions = SessionDao(database),
       _store = BotApprovalDao(database),
       _now = now ?? (() => DateTime.now().toUtc()),
       _newId = newId ?? newUuid;

  /// Runs the recorded call as the bot (`McpToolRelay.runApproved`).
  final Future<Object?> Function(
    String tool,
    Map<String, dynamic> arguments,
    String sessionId,
  )
  run;

  /// Puts [String] text in row [String]'s queue, durably, naming the request.
  final void Function(String sessionId, String text, String approvalId) post;

  /// Tells every client (a [BotView] keeps it to the bot's followers).
  final void Function(List<DataChange> changes) announce;

  /// Files the inbox item a person answers from, which reaches toasts and
  /// push; [retire] takes item [String] off when the request is over.
  final void Function(InboxItem item)? raise;
  final void Function(String itemId)? retire;
  final void Function(String message)? log;

  final SessionDao _sessions;
  final BotApprovalDao _store;
  final DateTime Function() _now;
  final String Function() _newId;
  final _running = <Future<void>>{};
  Timer? _sweep;
  var _closed = false;

  /// Done when every recorded call started so far has ended. For tests.
  Future<void> get settled => Future.wait(_running.toList());

  /// The inbox item of request [id].
  static String itemId(String id) => 'botApproval:$id';

  /// Expires what is past its time, says what a stop cut off, and looks for
  /// expiries from now on.
  void start() {
    for (final request in _store.running()) {
      _end(
        request,
        BotApprovalState.interrupted,
        outcome: 'The server stopped while it was running.',
        tell:
            '[Karmashala] The server stopped while it was running a call the '
            'person approved: ${request.summary}. It may have run, in part or '
            'whole, and it was not run again. Check what happened with your '
            'tools before you say anything about it.',
      );
    }
    sweep();
    _sweep ??= Timer.periodic(kBotApprovalSweep, (_) => sweep());
  }

  void close() {
    _closed = true;
    _sweep?.cancel();
    _sweep = null;
  }

  /// Why [tool] may not run for [callerSessionId] yet, recording the request;
  /// null when it may: `McpToolRelay.approvalGate`.
  String? hold(
    String tool,
    Map<String, dynamic> arguments,
    String callerSessionId,
  ) {
    final bot = _sessions.getById(callerSessionId);
    if (bot == null || !bot.isBot) return null;
    if (!_asks(tool, arguments, bot)) return null;
    final at = _now();
    final encoded = jsonEncode(arguments);
    for (final waiting in _store.pending(bot.id)) {
      // A retry is the same call, not a second one to approve.
      if (waiting.tool == tool && jsonEncode(waiting.arguments) == encoded) {
        return botApprovalHeld(waiting);
      }
    }
    final request = BotApproval(
      id: _newId(),
      sessionId: bot.id,
      tool: tool,
      arguments: arguments,
      summary: botApprovalSummary(
        tool,
        arguments,
        sessionTitle: (id) => _sessions.getById(id)?.title,
      ),
      state: BotApprovalState.pending,
      requestedAt: at,
      expiresAt: at.add(kBotApprovalLifetime),
    );
    _store.insert(request);
    announce([BotApprovalChanged(request)]);
    raise?.call(
      InboxItem(
        id: itemId(request.id),
        session: WatchedSession(
          key: AgentSessionKey('bot', bot.id),
          label: bot.title,
          openId: bot.id,
          imported: false,
        ),
        kind: InboxItemKind.botApproval,
        at: at,
        detail: request.summary,
      ),
    );
    log?.call('bot: ${request.id} waits for approval: ${request.summary}');
    return botApprovalHeld(request);
  }

  /// A tool the catalogue does not know asks, as it is refused elsewhere.
  /// `session_end` on a session the bot started does not: an ended session can
  /// be resumed, and agents are told to end their own children.
  bool _asks(String tool, Map<String, dynamic> arguments, Session bot) {
    if (!(kMcpToolAnnotations[tool]?.destructive ?? true)) return false;
    if (tool != 'session_end') return true;
    final target = arguments['sessionId'];
    if (target is! String || target.isEmpty) return true;
    return _sessions.getById(target)?.parentSessionId != bot.id;
  }

  /// A person's word on request [id], by [by]. Refused `notFound` for one that
  /// is not there, `conflict` for one answered or past its time. Yes answers
  /// as soon as the call starts: its end reaches the bot as a message.
  Future<BotApproval> answer(
    String id, {
    required bool approve,
    required String by,
  }) async {
    final known =
        _store.getById(id) ??
        (throw const DataRefused.notFound('no such request'));
    final taken = _store.consume(
      id,
      to: approve ? BotApprovalState.running : BotApprovalState.denied,
      at: _now(),
      by: by,
    );
    if (taken == null) {
      throw DataRefused(
        DataRefusalCode.conflict,
        known.state == BotApprovalState.pending
            ? 'this request has expired, so nothing ran'
            : 'this request was already answered',
      );
    }
    if (!approve) {
      _end(
        taken,
        BotApprovalState.denied,
        outcome: 'The person said No. Nothing ran.',
        tell:
            '[Karmashala] The person said No to: ${taken.summary}. Nothing '
            'ran. Do not try again unless they ask.',
      );
      return _store.getById(id)!;
    }
    announce([BotApprovalChanged(taken)]);
    retire?.call(itemId(id));
    late final Future<void> running;
    running = _runRecorded(taken).whenComplete(() => _running.remove(running));
    _running.add(running);
    return taken;
  }

  Future<void> _runRecorded(BotApproval request) async {
    String outcome;
    String tell;
    try {
      final result = await run(
        request.tool,
        request.arguments,
        request.sessionId,
      );
      final words = _words(result);
      outcome = words;
      tell =
          '[Karmashala] The person said Yes to: ${request.summary}. The server '
          'ran it once, so do not run it again. Result:\n\n$words\n\nSay in '
          'one short line what happened.';
    } on Object catch (error) {
      final words = boundedText('$error', kBotOutcomeMaxChars).$1;
      outcome = 'It failed: $words';
      tell =
          '[Karmashala] The person said Yes to: ${request.summary}. The server '
          'ran it once and it failed: $words\n\nSay so in one short line.';
    }
    if (_closed) return;
    _end(request, BotApprovalState.done, outcome: outcome, tell: tell);
  }

  static String _words(Object? result) {
    final text = switch (result) {
      null => 'It finished, and said nothing.',
      final String words => words,
      _ => jsonEncode(result),
    };
    return boundedText(text, kBotOutcomeMaxChars).$1;
  }

  /// Expires every request past its time, each told once.
  void sweep() {
    for (final request in _store.expireDue(_now())) {
      _end(
        request,
        BotApprovalState.expired,
        outcome: 'Nobody answered in time. Nothing ran.',
        tell:
            '[Karmashala] Nobody answered in time: ${request.summary}. Nothing '
            'ran. Do not try again unless they ask.',
      );
    }
  }

  /// A clear: everything waiting expires, and nothing is told to a bot whose
  /// conversation is going.
  void clear(String sessionId) {
    for (final request in _store.expireAll(sessionId, at: _now())) {
      _end(
        request,
        BotApprovalState.expired,
        outcome: 'The conversation was cleared. Nothing ran.',
      );
    }
  }

  /// What waits for a person, oldest first.
  List<BotApproval> pending(String sessionId) => _store.pending(sessionId);

  void _end(
    BotApproval request,
    BotApprovalState state, {
    required String outcome,
    String? tell,
  }) {
    _store.finish(request.id, state: state, outcome: outcome);
    announce([BotApprovalChanged(_store.getById(request.id)!)]);
    if (state != BotApprovalState.done &&
        state != BotApprovalState.interrupted) {
      retire?.call(itemId(request.id));
    }
    if (tell != null) post(request.sessionId, tell, request.id);
    log?.call('bot: ${request.id} ${state.name}: $outcome');
  }
}
