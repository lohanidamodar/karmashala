import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' hide AgentCapabilities;
import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionPromptRefusal, kPromptChangedRefusal;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionModeOption, SessionModesChanged;
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_session_engine/store.dart' show SessionMessageDao;

import '../domain/screen_facts.dart';
import '../domain/screen_session.dart';
import '../domain/uuid.dart';
import 'acp_conversation_writer.dart';
import 'acp_path_scope.dart';
import 'acp_runtime_host.dart';
import 'acp_transport.dart';

/// What [AcpSessionRuntime.start] established.
class AcpStartOutcome {
  const AcpStartOutcome({
    required this.agentSessionId,
    required this.resumed,
    this.notices = const [],
  });

  /// The agent's own id for the session: the row's `externalSessionId`.
  final String agentSessionId;

  /// Whether `session/load` continued the conversation the row named.
  final bool resumed;

  /// What a person should know about this start, in sentences.
  final List<String> notices;
}

/// How an open permission request was answered.
class AcpPermissionAnswer {
  const AcpPermissionAnswer({
    required this.answered,
    required this.effect,
    required this.granted,
    required this.toolTitle,
  });

  /// The option chosen, in the agent's words.
  final String answered;
  final String effect;
  final bool granted;
  final String toolTitle;
}

/// **One agent spoken to over the Agent Client Protocol, for one session
/// row** (design C4): the process, the peer, the conversation written to
/// `session_messages`, the status the agent reports of itself, and the
/// permission and file requests it makes of the client. No terminal: its
/// "screen" is the recent conversation rendered as lines.
class AcpSessionRuntime implements ScreenSession {
  AcpSessionRuntime({
    required this.id,
    required this.sessionId,
    required this.agentId,
    required this.agentName,
    required this.spec,
    required this.workingDirectory,
    required Future<AcpTransport> Function() spawn,
    required SessionMessageDao messages,
    AcpPathScope? files,
    this.host = AcpRuntimeHost.none,
    this.mcpUrl,
    this.risk,
    this.resumeSessionId,
    this.clientVersion = kHostVersion,
    String Function()? newId,
    DateTime Function()? now,
    Duration coalesce = const Duration(milliseconds: 100),
    this.stopPatience = const Duration(seconds: 5),
    this.startPatience = const Duration(minutes: 3),
  }) : _spawn = spawn,
       _files = files ?? AcpPathScope(root: workingDirectory),
       _now = now ?? (() => DateTime.now().toUtc()) {
    startedAt = _now();
    _writer = AcpConversationWriter(
      sessionId: sessionId,
      messages: messages,
      newId: newId ?? newUuid,
      onChanged: () => host.messagesChanged(sessionId),
      now: _now,
      coalesce: coalesce,
    );
  }

  /// The host session id (`karmashala_<row>`), as the registry keys it.
  @override
  final String id;

  /// The session row.
  final String sessionId;
  final String agentId;

  /// What the agent is called where a person reads it.
  final String agentName;
  final AcpLaunchSpec spec;

  /// Where the agent works, as it spells paths.
  final String workingDirectory;
  final AcpRuntimeHost host;

  /// Karmashala's MCP endpoint for this session, or null for no tools.
  final String? mcpUrl;

  /// How much the session may do: picks the agent's mode, and answers
  /// `allow_once` itself from [PermissionRisk.autoRun] up.
  final PermissionRisk? risk;

  /// The agent's session to `session/load`, when it can.
  final String? resumeSessionId;
  final String clientVersion;

  /// How long a stop waits for the exit before killing, and after killing.
  final Duration stopPatience;

  /// How long `initialize` and then `session/new` or `session/load` may each
  /// take before the start is given up in words. Generous: an agent run
  /// through `npx` downloads itself the first time.
  final Duration startPatience;

  final Future<AcpTransport> Function() _spawn;

  /// Where the agent's `fs/*` paths land on this machine.
  final AcpPathScope _files;
  final DateTime Function() _now;
  late final AcpConversationWriter _writer;

  @override
  late final DateTime startedAt;

  AcpTransport? _transport;
  AcpAgentClient? _client;
  StreamSubscription<SessionUpdateEvent>? _updates;
  AgentCapabilities _capabilities = const AgentCapabilities();
  SessionModeState? _modes;
  String? _agentSessionId;
  Future<StopReason>? _turn;
  Completer<StopReason?>? _turnSettled;
  _PendingPermission? _pending;
  final _stderr = <String>[];
  var _stderrLength = 0;
  int? _exitCode;
  SessionLifecycle _lifecycle = const SessionRunning();
  final _ended = Completer<SessionLifecycle>();
  var _started = false;
  var _loading = false;
  var _closeRequested = false;
  var _stoppingWithHost = false;
  var _torn = false;

  /// Most stderr kept for a failure's words.
  static const int stderrKept = 64 * 1024;

  /// The agent's id for the session, once `session/new` or `session/load`
  /// answered.
  String? get agentSessionId => _agentSessionId;

  /// The agent's modes as last announced, or null when it offers none.
  SessionModesChanged? get modes => _modesChange(_modes);

  bool get inTurn => _turn != null;

  bool get hasOpenPermission => _pending != null;

  /// The call the open permission request is about, or null.
  String? get pendingToolCallId => _pending?.call.toolCallId;

  @override
  SessionLifecycle get lifecycle => _lifecycle;

  @override
  Future<SessionLifecycle> get ended => _ended.future;

  /// A protocol session has no terminal, so nothing it told one.
  @override
  ScreenFacts? get facts => null;

  @override
  List<String> tailText(int lines) => _writer.tail(lines);

  bool get closeRequested => _closeRequested;

  bool markCloseRequested() {
    if (_lifecycle.hasEnded) return false;
    return _closeRequested = true;
  }

  /// Spawns the agent, initialises, opens or loads the session and sets its
  /// mode. Throws [StateError] in words when any step refuses; the runtime
  /// has then ended and the process is gone.
  Future<AcpStartOutcome> start() async {
    if (_started) throw StateError('$agentName was already started');
    _started = true;
    final notices = <String>[];
    try {
      final transport = await _spawn();
      _transport = transport;
      transport.errorLines.listen(_stderrLine, onError: (Object _) {});
      unawaited(
        transport.exitCode.then(_exited, onError: (Object _) => _exited(-1)),
      );
      final peer = AcpPeer(transport.output, transport.input);
      final client = AcpAgentClient(peer, handler: _Handler(this));
      _client = client;
      _updates = client.updates.listen(_onUpdate);
      final init = await _within(
        AcpMethods.initialize,
        client.initialize(
          clientInfo: ClientInfo(name: spec.clientName, version: clientVersion),
        ),
      );
      _capabilities = init.agentCapabilities;
      final url = mcpUrl;
      final servers = [
        if (url != null) McpServerEntry.http('karmashala', url: url),
      ];
      if (url == null) {
        notices.add(
          "Karmashala's tools were not handed to $agentName: this server "
          'serves no MCP endpoint the agent can dial.',
        );
      }
      final resume = resumeSessionId;
      var resumed = false;
      SessionModeState? modes;
      if (resume != null && resume.isNotEmpty && _capabilities.loadSession) {
        _loading = true;
        try {
          final loaded = await _within(
            AcpMethods.sessionLoad,
            _authenticating(
              init,
              () => client.loadSession(
                sessionId: resume,
                cwd: workingDirectory,
                mcpServers: servers,
              ),
            ),
          );
          modes = loaded.modes;
        } finally {
          _loading = false;
        }
        _agentSessionId = resume;
        resumed = true;
      } else {
        if (resume != null && resume.isNotEmpty) {
          notices.add(
            '$agentName cannot reload a conversation over ACP, so this is a '
            'fresh conversation in the same session.',
          );
        }
        final created = await _within(
          AcpMethods.sessionNew,
          _authenticating(
            init,
            () => client.newSession(cwd: workingDirectory, mcpServers: servers),
          ),
        );
        _agentSessionId = created.sessionId;
        modes = created.modes;
      }
      await _applyInitialMode(modes, notices);
      _publish(
        AgentActivityStatus.idle,
        detail: resumed ? AcpMethods.sessionLoad : AcpMethods.sessionNew,
      );
      return AcpStartOutcome(
        agentSessionId: _agentSessionId!,
        resumed: resumed,
        notices: notices,
      );
    } on Object catch (error) {
      final reason = _failureWords('could not be started', error);
      _finish(SessionEndedWithoutCode(_now(), reason));
      unawaited(_tearDown(killNow: true));
      throw StateError(reason);
    }
  }

  /// Sends [text] as the next turn. Refuses in words while a turn is open.
  Future<void> send(String text) async {
    final client = _client;
    final agent = _agentSessionId;
    if (_lifecycle.hasEnded) {
      throw StateError(
        '$agentName has ended; resume the session to send to it',
      );
    }
    if (client == null || agent == null) {
      throw StateError(
        '$agentName has not finished starting; send once it has',
      );
    }
    if (_turn != null) {
      throw StateError(
        '$agentName is still working on the last message; wait for the turn '
        'to end or interrupt it before sending another',
      );
    }
    if (text.trim().isEmpty) throw StateError('there is no message to send');
    _writer.user(text);
    host.checkpointPrompt(sessionId, text);
    _publish(AgentActivityStatus.working, detail: AcpMethods.sessionPrompt);
    final settled = _turnSettled = Completer<StopReason?>();
    final turn = _turn = client.prompt(agent, [ContentBlock.text(text)]);
    unawaited(_settle(turn, settled));
  }

  /// Completes when the open turn has ended and its status is published;
  /// at once, with null, when none is open.
  Future<StopReason?> awaitTurn() => _turnSettled?.future ?? Future.value(null);

  /// Asks the agent to stop the open turn; nothing when none is open.
  void cancel() {
    final client = _client;
    final agent = _agentSessionId;
    if (client == null || agent == null || _turn == null) return;
    _resolvePending(const PermissionOutcome.cancelled());
    client.cancel(agent);
  }

  /// `session/set_mode`. Throws [StateError] in words for a mode the agent
  /// does not offer.
  Future<void> setMode(String modeId) async {
    final modes = _modes;
    final client = _client;
    final agent = _agentSessionId;
    if (modes == null || client == null || agent == null) {
      throw StateError('$agentName offers no modes to set');
    }
    if (!modes.availableModes.any((mode) => mode.id == modeId)) {
      throw StateError(
        '$agentName offers no mode "$modeId"; it offers '
        '${modes.availableModes.map((mode) => mode.id).join(', ')}',
      );
    }
    await client.setMode(agent, modeId);
    _modes = SessionModeState(
      currentModeId: modeId,
      availableModes: modes.availableModes,
    );
    _announceModes();
  }

  /// Answers the open permission request: allow with the first `allow_once`
  /// (else `allow_always`) option, reject with `reject_once` (else
  /// `reject_always`). Throws [SessionPromptRefusal] when none is open, when
  /// [toolCallId] names another call, or when the agent offered no such
  /// option. An edit waits for the before-turn checkpoint first.
  Future<AcpPermissionAnswer> answerPermission({
    required bool approve,
    String? toolCallId,
  }) async {
    final pending = _pending;
    if (pending == null) {
      throw const SessionPromptRefusal(
        'this session has no permission request open to answer',
      );
    }
    if (toolCallId != null && toolCallId != pending.call.toolCallId) {
      throw const SessionPromptRefusal(kPromptChangedRefusal, stale: true);
    }
    final option = _optionFor(pending.options, approve: approve);
    if (option == null) {
      throw SessionPromptRefusal(
        '$agentName offered no way to ${approve ? 'allow' : 'reject'} '
        '"${pending.title}" from outside its own prompt',
      );
    }
    if (approve) await _holdForEdit(pending.call);
    if (!identical(_pending, pending)) {
      throw const SessionPromptRefusal(kPromptChangedRefusal, stale: true);
    }
    _pending = null;
    pending.completer.complete(PermissionOutcome.selected(option.optionId));
    _publish(AgentActivityStatus.working, evidence: [pending.title]);
    return AcpPermissionAnswer(
      answered: option.name,
      effect:
          '${approve ? 'Allowed' : 'Rejected'} "${pending.title}" by choosing '
          '"${option.name}" (${option.kind.raw}).',
      granted: approve,
      toolTitle: pending.title,
    );
  }

  /// Ends the agent: the open turn is cancelled, the peer closed, and the
  /// process killed when it has not exited within [stopPatience].
  Future<SessionLifecycle> stop() async {
    if (!_lifecycle.hasEnded) cancel();
    await _tearDown();
    if (!_lifecycle.hasEnded) {
      _finish(
        SessionEndedWithoutCode(
          _now(),
          'asked to stop, killed after ${stopPatience.inSeconds} s, and not '
          'reaped within another ${stopPatience.inSeconds} s',
        ),
      );
    }
    return _lifecycle;
  }

  /// The host is shutting down: recorded as the host's doing, as a PTY's is.
  Future<SessionLifecycle> stopWithHost() {
    if (!_lifecycle.hasEnded) _stoppingWithHost = true;
    return stop();
  }

  // The turn.

  Future<void> _settle(
    Future<StopReason> turn,
    Completer<StopReason?> settled,
  ) async {
    StopReason? reason;
    Object? failure;
    try {
      reason = await turn;
    } on Object catch (error) {
      failure = error;
    }
    _writer.turnEnded();
    if (identical(_turn, turn)) _turn = null;
    _resolvePending(const PermissionOutcome.cancelled());
    if (failure != null) {
      _publish(
        AgentActivityStatus.failed,
        failureReason: failure is AcpRpcError
            ? 'error ${failure.code}'
            : 'exit',
        evidence: [_failureWords('did not finish the turn', failure)],
      );
    } else if (reason == StopReason.refusal || reason == StopReason.maxTokens) {
      _publish(
        AgentActivityStatus.failed,
        failureReason: reason!.raw,
        detail: reason.raw,
        evidence: ['$agentName stopped the turn: ${reason.raw}'],
      );
    } else {
      _publish(AgentActivityStatus.idle, detail: reason?.raw);
    }
    if (identical(_turnSettled, settled)) _turnSettled = null;
    if (!settled.isCompleted) settled.complete(reason);
  }

  void _onUpdate(SessionUpdateEvent event) {
    final agent = _agentSessionId;
    if (agent != null &&
        event.sessionId.isNotEmpty &&
        event.sessionId != agent) {
      return;
    }
    // A load replays the conversation the rows already hold.
    if (_loading) return;
    final update = event.update;
    if (update is CurrentModeUpdate) {
      final modes = _modes;
      if (modes != null && modes.currentModeId != update.currentModeId) {
        _modes = SessionModeState(
          currentModeId: update.currentModeId,
          availableModes: modes.availableModes,
        );
        _announceModes();
      }
      return;
    }
    if (update is ToolCallUpdate) {
      final before = _writer.toolCall(update.toolCallId);
      _writer.update(update);
      _noteEditPaths(before, _writer.toolCall(update.toolCallId) ?? update);
      return;
    }
    _writer.update(update);
  }

  /// An edit's paths reach the checkpoint once they are known — Claude's
  /// adapter opens a `tool_call` bare and names the kind and the file on a
  /// later `tool_call_update`.
  void _noteEditPaths(ToolCallUpdate? before, ToolCallUpdate after) {
    if (after.kind != ToolKind.edit) return;
    final seen = before?.kind == ToolKind.edit
        ? _pathsOf(before!).toSet()
        : const <String>{};
    final fresh = [
      for (final path in _pathsOf(after))
        if (!seen.contains(path)) path,
    ];
    if (fresh.isNotEmpty) host.checkpointTouched(sessionId, fresh);
  }

  // Starting.

  /// [call], or a [TimeoutException] in words once [startPatience] has
  /// passed: a start that hangs — an `npx` waiting on a terminal, a download
  /// that never ends — fails like any other instead of holding the launch.
  Future<T> _within<T>(String method, Future<T> call) => call.timeout(
    startPatience,
    onTimeout: () => throw TimeoutException(
      '$agentName did not answer $method within '
      '${startPatience.inSeconds}s',
    ),
  );

  Future<T> _authenticating<T>(
    InitializeResult init,
    Future<T> Function() call,
  ) async {
    try {
      return await call();
    } on AcpAuthenticationRequired catch (error) {
      final methods = init.authMethods;
      final method =
          spec.authMethodId ?? (methods.length == 1 ? methods.single.id : null);
      if (method == null) {
        throw StateError(
          methods.isEmpty
              ? '$agentName asks to be authenticated (${error.message}) and '
                    'advertises no way to do it'
              : '$agentName asks to be authenticated and offers '
                    '${methods.length} methods '
                    '(${methods.map((m) => m.id).join(', ')}); none is chosen '
                    'for it',
        );
      }
      await _client!.authenticate(method);
      return call();
    }
  }

  Future<void> _applyInitialMode(
    SessionModeState? modes,
    List<String> notices,
  ) async {
    _modes = modes;
    final rung = risk;
    if (modes != null && rung != null) {
      final wanted = spec.modeFor(
        rung,
        modes.availableModes.map((mode) => mode.id),
      );
      if (wanted == null) {
        notices.add(
          '$agentName offers no mode for "${rung.label}"; it stays in its '
          'own default, "${_modeName(modes, modes.currentModeId)}".',
        );
      } else if (wanted != modes.currentModeId) {
        await _client!.setMode(_agentSessionId!, wanted);
        _modes = SessionModeState(
          currentModeId: wanted,
          availableModes: modes.availableModes,
        );
      }
    }
    _announceModes();
  }

  static String _modeName(SessionModeState modes, String id) {
    for (final mode in modes.availableModes) {
      if (mode.id == id) return mode.name;
    }
    return id;
  }

  void _announceModes() => host.modesChanged(_modesChange(_modes)!);

  SessionModesChanged? _modesChange(SessionModeState? modes) {
    if (modes == null && !_started) return null;
    return SessionModesChanged(
      sessionId: sessionId,
      currentModeId: modes?.currentModeId,
      availableModes: [
        for (final mode in modes?.availableModes ?? const <SessionMode>[])
          SessionModeOption(
            id: mode.id,
            name: mode.name,
            description: mode.description,
          ),
      ],
    );
  }

  // Permissions.

  Future<PermissionOutcome> _requestPermission(
    ToolCallUpdate call,
    List<PermissionOption> options,
  ) async {
    final title = _titleOf(call);
    final rung = risk;
    if (rung != null && !rung.isAtMost(PermissionRisk.acceptEdits)) {
      final once = options.where(
        (o) => o.kind == PermissionOptionKind.allowOnce,
      );
      if (once.isNotEmpty) {
        await _holdForEdit(call);
        return PermissionOutcome.selected(once.first.optionId);
      }
    }
    final pending = _PendingPermission(call, options, title);
    _pending = pending;
    final now = _now();
    final input = call.rawInput;
    _publish(
      AgentActivityStatus.awaitingApproval,
      waiting: AgentWaitKind.approval,
      evidence: [title],
      toolAsk: AgentToolAsk(
        toolName: title,
        input: input is Map ? pruneToolInput(input) : const {},
        at: now,
        toolUseId: call.toolCallId,
        cwd: workingDirectory,
      ),
      waitingSince: now,
    );
    try {
      return await pending.completer.future;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  void _resolvePending(PermissionOutcome outcome) {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    if (!pending.completer.isCompleted) pending.completer.complete(outcome);
  }

  static PermissionOption? _optionFor(
    List<PermissionOption> options, {
    required bool approve,
  }) {
    final wanted = approve
        ? const [
            PermissionOptionKind.allowOnce,
            PermissionOptionKind.allowAlways,
          ]
        : const [
            PermissionOptionKind.rejectOnce,
            PermissionOptionKind.rejectAlways,
          ];
    for (final kind in wanted) {
      for (final option in options) {
        if (option.kind == kind) return option;
      }
    }
    return null;
  }

  /// An edit lands after the turn's before-turn checkpoint, which is told
  /// what it is about to touch.
  Future<void> _holdForEdit(ToolCallUpdate call) async {
    if (call.kind != ToolKind.edit) return;
    await host.checkpointSettled(sessionId);
    host.checkpointTouched(sessionId, _pathsOf(call));
  }

  static List<String> _pathsOf(ToolCallUpdate call) => [
    for (final location in call.locations ?? const <ToolCallLocation>[])
      if (location.path.isNotEmpty) location.path,
    for (final content in call.content ?? const <ToolCallContent>[])
      if (content is ToolCallDiff && content.path.isNotEmpty) content.path,
  ];

  static String _titleOf(ToolCallUpdate call) =>
      call.title ?? call.name ?? call.toolCallId;

  // Files.

  Future<String> _read(String path, {int? line, int? limit}) async {
    final file = _files.resolve(path, verb: 'read');
    String text;
    try {
      text = await File(file.host).readAsString();
    } on FileSystemException catch (error) {
      throw AcpRpcError(
        JsonRpcErrorCodes.resourceNotFound,
        'could not read $path: ${error.osError?.message ?? error.message}',
      );
    }
    if (line == null && limit == null) return text;
    final lines = const LineSplitter().convert(text);
    final start = ((line ?? 1) - 1).clamp(0, lines.length);
    final end = limit == null
        ? lines.length
        : (start + limit).clamp(start, lines.length);
    return lines.sublist(start, end).join('\n');
  }

  Future<void> _write(String path, String content) async {
    final file = _files.resolve(path, verb: 'written');
    await host.checkpointSettled(sessionId);
    host.checkpointTouched(sessionId, [file.agent]);
    try {
      final target = File(file.host);
      await target.parent.create(recursive: true);
      await target.writeAsString(content, flush: true);
    } on FileSystemException catch (error) {
      throw AcpRpcError(
        JsonRpcErrorCodes.internalError,
        'could not write $path: ${error.osError?.message ?? error.message}',
      );
    }
  }

  // Status and the end.

  void _publish(
    AgentActivityStatus status, {
    AgentWaitKind waiting = AgentWaitKind.unrecorded,
    List<String> evidence = const [],
    String? detail,
    String? failureReason,
    AgentToolAsk? toolAsk,
    DateTime? waitingSince,
  }) {
    host.status(
      sessionId,
      AgentStatusReport(
        agentId: agentId,
        sessionId: _agentSessionId ?? sessionId,
        status: status,
        source: AgentStatusSource.protocol,
        observedAt: _now(),
        waiting: waiting,
        evidence: evidence,
        detail: detail,
        failureReason: failureReason,
        toolAsk: toolAsk,
        waitingSince: waitingSince,
      ),
    );
  }

  void _stderrLine(String line) {
    _stderr.add(line);
    _stderrLength += line.length + 1;
    while (_stderrLength > stderrKept && _stderr.length > 1) {
      _stderrLength -= _stderr.removeAt(0).length + 1;
    }
  }

  /// [what] happened because of [error], with what the process left behind.
  String _failureWords(String what, Object error) {
    final buffer = StringBuffer('$agentName $what: $error');
    final code = _exitCode;
    if (code != null) buffer.write(' (exit code $code)');
    final tail = _stderr.join('\n').trim();
    if (tail.isNotEmpty) {
      final shown = tail.length > 400
          ? tail.substring(tail.length - 400)
          : tail;
      buffer.write('; its stderr ended: $shown');
    }
    return buffer.toString();
  }

  void _exited(int code) {
    _exitCode = code;
    _finish(SessionExited(code, _now()));
    unawaited(_tearDown());
  }

  void _finish(SessionLifecycle end) {
    if (_lifecycle.hasEnded) return;
    if (_stoppingWithHost && !_closeRequested) {
      end = SessionEndedWithoutCode(
        end.endedAt ?? _now(),
        SessionEndedWithoutCode.hostStopped,
      );
    }
    _lifecycle = end;
    if (!_ended.isCompleted) _ended.complete(end);
  }

  /// Closes the peer (and so the agent's stdin), then waits for the exit —
  /// killing after [stopPatience], or at once with [killNow].
  Future<void> _tearDown({bool killNow = false}) async {
    if (_torn) return;
    _torn = true;
    await _updates?.cancel();
    _writer.close();
    _resolvePending(const PermissionOutcome.cancelled());
    await _client?.close();
    final transport = _transport;
    if (transport == null) return;
    if (!killNow && await _exitWithin(stopPatience)) return;
    try {
      await transport.kill();
    } on Object catch (error) {
      host.log('killing $agentName of session $sessionId failed: $error');
    }
    await _exitWithin(stopPatience);
  }

  Future<bool> _exitWithin(Duration bound) {
    final exit = _transport?.exitCode;
    if (exit == null) return Future.value(true);
    return exit
        .then((_) => true, onError: (Object _) => true)
        .timeout(bound, onTimeout: () => false);
  }
}

final class _PendingPermission {
  _PendingPermission(this.call, this.options, this.title);

  final ToolCallUpdate call;
  final List<PermissionOption> options;
  final String title;
  final completer = Completer<PermissionOutcome>();
}

/// The agent's requests, routed to the runtime. Terminals stay unsupported.
final class _Handler extends AcpClientHandler {
  const _Handler(this._runtime);

  final AcpSessionRuntime _runtime;

  @override
  Future<PermissionOutcome> requestPermission(
    String sessionId,
    ToolCallUpdate toolCall,
    List<PermissionOption> options,
  ) => _runtime._requestPermission(toolCall, options);

  @override
  Future<String> readTextFile(
    String sessionId,
    String path, {
    int? line,
    int? limit,
  }) => _runtime._read(path, line: line, limit: limit);

  @override
  Future<void> writeTextFile(String sessionId, String path, String content) =>
      _runtime._write(path, content);
}
