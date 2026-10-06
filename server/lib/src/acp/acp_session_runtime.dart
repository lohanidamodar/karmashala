import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' hide AgentCapabilities;
import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionPromptRefusal, kPromptChangedRefusal;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        SessionCommand,
        SessionCommandsChanged,
        SessionPromptKindsChanged,
        SessionConfigChoice,
        SessionConfigOption,
        SessionConfigOptionsChanged,
        SessionModeOption,
        SessionModesChanged,
        SessionUsageChanged;
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_session_engine/store.dart'
    show SessionMessageDao, SessionUsageDao, SessionUsageTurn;
import 'package:path/path.dart' as p;

import '../domain/screen_facts.dart';
import '../domain/screen_session.dart';
import '../domain/uuid.dart';
import 'acp_conversation_writer.dart';
import 'acp_extensions.dart';
import 'acp_login_required.dart';
import 'acp_path_scope.dart';
import 'acp_prompt_images.dart';
import 'acp_runtime_host.dart';
import 'acp_terminals.dart';
import 'acp_transport.dart';
import 'acp_usage_limit.dart';

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
    this.usage,
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
    AcpTerminals? terminals,
    this.terminalRefresh = const Duration(milliseconds: 250),
  }) : _spawn = spawn,
       _files = files ?? AcpPathScope(root: workingDirectory),
       _terminals = terminals,
       _now = now ?? (() => DateTime.now().toUtc()) {
    startedAt = _now();
    terminals?.onOutput = _terminalMoved;
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

  /// Where the agent's `usage_update`s are kept; null keeps none.
  final SessionUsageDao? usage;

  /// Where the agent's `fs/*` paths land on this machine.
  final AcpPathScope _files;

  /// The agent's `terminal/*`; null advertises none.
  final AcpTerminals? _terminals;

  /// How often a running command's output is folded into its tool row.
  final Duration terminalRefresh;

  /// The tool calls that embed each terminal, and a refresh waiting per one.
  final _terminalCalls = <String, Set<String>>{};
  final _terminalTimers = <String, Timer>{};
  final DateTime Function() _now;
  late final AcpConversationWriter _writer;

  @override
  late final DateTime startedAt;

  AcpTransport? _transport;
  AcpAgentClient? _client;
  StreamSubscription<SessionUpdateEvent>? _updates;
  AgentCapabilities _capabilities = const AgentCapabilities();
  SessionModeState? _modes;

  /// The rung of the last working mode the person put the session in — at
  /// launch, or with the mode picker since — which an approval that switches
  /// mode stays within. The agent's own mode changes never move it.
  PermissionRisk? _workingRung;

  /// Notes [modeId] as chosen for the session. Plan mode is not where it
  /// works: approving a plan returns to the mode it was in before.
  void _modeChosen(String modeId) {
    final rung = spec.rungOfMode(modeId);
    if (rung != null && !rung.isAtMost(PermissionRisk.readOnly)) {
      _workingRung = rung;
    }
  }

  List<ConfigOption>? _configOptions;
  List<AvailableCommand>? _commands;
  UsageUpdate? _latestUsage;
  UsageUpdate? _turnUsage;
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
  var _stopping = false;
  var _torn = false;
  var _agentWorking = false;

  /// Most stderr kept for a failure's words.
  static const int stderrKept = 64 * 1024;

  /// The agent's id for the session, once `session/new` or `session/load`
  /// answered.
  String? get agentSessionId => _agentSessionId;

  /// The agent's modes as last announced, or null before it has started.
  SessionModesChanged? get modes => _modesChange(_modes);

  /// The agent's config options (a model, a flag) as last announced, or null
  /// before it has started.
  SessionConfigOptionsChanged? get configOptions =>
      _configOptionsChange(_configOptions);

  /// The slash commands the agent accepts, as last announced; null until it
  /// has announced any.
  /// What the agent takes in a prompt beyond text, once it has started and
  /// until it is gone; null otherwise.
  SessionPromptKindsChanged? get promptKinds => _agentSessionId == null || _torn
      ? null
      : SessionPromptKindsChanged(
          sessionId: sessionId,
          images: _capabilities.promptCapabilities.image,
        );

  SessionCommandsChanged? get commands => switch (_commands) {
    final commands? => _commandsChange(commands),
    null => null,
  };

  bool get inTurn => _turn != null;

  bool get hasOpenPermission => _pending != null;

  /// The call the open permission request is about, or null.
  String? get pendingToolCallId => _pending?.call.toolCallId;

  /// The questions the open request asks, when it is a question.
  AgentQuestionSet? get openQuestion => _pending?.question;

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
      if (_torn) {
        // Stopped while spawning: the teardown had no process to end.
        await transport.kill();
        throw StateError('$agentName was stopped while it was starting');
      }
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
          clientCapabilities: ClientCapabilities(terminal: _terminals != null),
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
      List<ConfigOption>? options;
      var forgotten = false;
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
          options = loaded.configOptions;
          _agentSessionId = resume;
          resumed = true;
        } on AcpRpcError catch (error) {
          // The agent no longer holds that conversation (its own store was
          // cleared, or it never kept one for a start it refused). A load
          // that cannot find it is not a session that cannot run: it goes
          // on as a fresh conversation in the same row, and says so.
          if (error.code != JsonRpcErrorCodes.resourceNotFound) rethrow;
          forgotten = true;
        } finally {
          _loading = false;
        }
      }
      if (!resumed) {
        if (forgotten) {
          notices.add(
            '$agentName no longer holds this conversation, so this is a '
            'fresh conversation in the same session.',
          );
        } else if (resume != null && resume.isNotEmpty) {
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
        options = created.configOptions;
      }
      await _applyInitialMode(modes, notices);
      _configOptions = options;
      _announceConfigOptions();
      host.promptKindsChanged(promptKinds!);
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
      throw error is AcpLoginRequired
          ? AcpLoginRequired(reason)
          : StateError(reason);
    }
  }

  /// Sends [text] as the next turn. Refuses in words while a turn is open.
  /// Answers what the sender should be told, or null: why an attached image
  /// went to the agent as its path rather than as an image.
  Future<String?> send(String text) async {
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
    final (prompt, notice) = _promptOf(text);
    _writer.user(text);
    host.checkpointPrompt(sessionId, text);
    _publish(AgentActivityStatus.working, detail: AcpMethods.sessionPrompt);
    final settled = _turnSettled = Completer<StopReason?>();
    final turn = _turn = client.prompt(agent, prompt);
    unawaited(_settle(turn, settled));
    if (notice != null) {
      host.log('session $sessionId: $notice');
      host.notice(sessionId, notice);
    }
    return notice;
  }

  /// [text] as prompt blocks: its attached images as image blocks when the
  /// agent takes them, each one that cannot be left as its path; and what
  /// the sender should be told of any left.
  (List<ContentBlock>, String?) _promptOf(String text) {
    final attached = splitAttachedImages(text);
    final count = attached.paths.length;
    if (count == 0) return ([ContentBlock.text(text)], null);
    if (!_capabilities.promptCapabilities.image) {
      return (
        [ContentBlock.text(text)],
        '$agentName does not take images in a prompt, so '
            '${count == 1 ? 'the image was sent as its path' : 'the images were sent as their paths'}.',
      );
    }
    final images = <ContentBlock>[];
    final sent = <String>{};
    final refused = <String>[];
    for (final path in attached.paths) {
      final (:image, :refusal) = promptImage(path);
      if (image != null) {
        images.add(image);
        sent.add(path);
      } else {
        refused.add(
          '${p.basename(path)} was sent as its path, not as an image: '
          '$refusal.',
        );
      }
    }
    final rest = attached.textWithout(sent);
    return (
      [if (rest.trim().isNotEmpty) ContentBlock.text(rest), ...images],
      refused.isEmpty ? null : refused.join(' '),
    );
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
    _modeChosen(modeId);
    _modes = SessionModeState(
      currentModeId: modeId,
      availableModes: modes.availableModes,
    );
    _announceModes();
  }

  /// `session/set_config_option`: [value] is a choice's value for a `select`
  /// option, a bool for a `boolean` one. Throws [StateError] in words for an
  /// option the agent does not expose or a value it does not offer. The
  /// options as the agent then holds them are announced.
  Future<void> setConfigOption(String configId, Object value) async {
    final options = _configOptions;
    final client = _client;
    final agent = _agentSessionId;
    if (options == null || options.isEmpty || client == null || agent == null) {
      throw StateError('$agentName exposes no config options to set');
    }
    final option = options.where((o) => o.id == configId).firstOrNull;
    if (option == null) {
      throw StateError(
        '$agentName exposes no config option "$configId"; it exposes '
        '${options.map((o) => o.id).join(', ')}',
      );
    }
    final List<ConfigOption> answered;
    if (option.isBoolean) {
      if (value is! bool) {
        throw StateError('"${option.name}" takes true or false, not "$value"');
      }
      answered = await client.setConfigOption(agent, configId, flag: value);
    } else {
      if (value is! String) {
        throw StateError('"${option.name}" takes one of its choices');
      }
      if (option.options.isNotEmpty &&
          !option.options.any((choice) => choice.value == value)) {
        throw StateError(
          '$agentName offers no "$value" for "${option.name}"; it offers '
          '${option.options.map((choice) => choice.value).join(', ')}',
        );
      }
      answered = await client.setConfigOption(agent, configId, valueId: value);
    }
    // An agent that answers with no list has still taken the value.
    _configOptions = answered.isNotEmpty
        ? answered
        : [
            for (final o in options)
              if (o.id == configId) _moved(o, value) else o,
          ];
    _announceConfigOptions();
  }

  static ConfigOption _moved(ConfigOption option, Object value) => ConfigOption(
    id: option.id,
    name: option.name,
    type: option.type,
    description: option.description,
    category: option.category,
    currentValue: value,
    options: option.options,
  );

  /// Answers the open permission request: [optionId] chooses that option
  /// exactly, its own kind deciding whether it allows; without one, allow
  /// takes the first `allow_once` (else `allow_always`) option and reject
  /// `reject_once` (else `reject_always`). Throws [SessionPromptRefusal] when
  /// none is open, when [toolCallId] names another call, or when the agent
  /// offered no such option. An edit waits for the before-turn checkpoint.
  Future<AcpPermissionAnswer> answerPermission({
    required bool approve,
    String? toolCallId,
    String? optionId,
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
    final PermissionOption? option;
    if (optionId != null) {
      option = pending.options.where((o) => o.optionId == optionId).firstOrNull;
      if (option == null) {
        throw SessionPromptRefusal(
          '$agentName offered no option "$optionId" for "${pending.title}"; '
          'it offered ${pending.options.map((o) => o.name).join(', ')}',
        );
      }
      approve = option.kind.allows;
    } else {
      option = _optionFor(pending.options, approve: approve);
      if (option == null &&
          approve &&
          _modeSwitchingAllow(pending.options) != null) {
        throw SessionPromptRefusal(
          'every way $agentName offers to approve "${pending.title}" would '
          "raise this session's permissions",
        );
      }
    }
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

  /// Answers the open question [toolUseId] with [answers], one per question:
  /// chosen labels (comma-joined where several may be picked) or the
  /// person's own words go back to the agent. Throws [SessionPromptRefusal],
  /// with nothing sent, when no such question is open or an answer does not
  /// fit it.
  Future<AcpPermissionAnswer> answerQuestion({
    required String toolUseId,
    required List<AgentQuestionAnswer> answers,
  }) async {
    final pending = _pending;
    final question = pending?.question;
    if (pending == null || question == null) {
      throw const SessionPromptRefusal(
        'this session has no question open to answer',
      );
    }
    if (question.toolUseId != toolUseId) {
      throw const SessionPromptRefusal(kPromptChangedRefusal, stale: true);
    }
    final asked = question.questions;
    if (answers.length != asked.length) {
      throw SessionPromptRefusal(
        'there are ${asked.length} questions to answer, and '
        '${answers.length} answers were given',
      );
    }
    final said = <String, String>{};
    for (final (i, answer) in answers.indexed) {
      final q = asked[i];
      final text = answer.text?.trim();
      if (text != null) {
        if (text.isEmpty) {
          throw SessionPromptRefusal(
            '"${q.question}" was answered with nothing',
          );
        }
        said[q.question] = text;
        continue;
      }
      final chosen = answer.chosen;
      if (chosen.isEmpty ||
          (!q.multiSelect && chosen.length > 1) ||
          chosen.any((c) => c < 0 || c >= q.options.length)) {
        throw SessionPromptRefusal(
          'the answer to "${q.question}" does not fit its '
          '${q.options.length} options',
        );
      }
      said[q.question] = [
        for (final c in chosen) q.options[c].label,
      ].join(', ');
    }
    final send = pending.options.where((o) => o.kind.allows).firstOrNull;
    if (send == null) {
      throw SessionPromptRefusal(
        '$agentName offered no way to answer "${pending.title}"',
      );
    }
    _pending = null;
    pending.completer.complete(
      PermissionOutcome.selected(
        send.optionId,
        meta: {
          'karmashala': {'answers': said},
        },
      ),
    );
    _publish(AgentActivityStatus.working, evidence: [pending.title]);
    return AcpPermissionAnswer(
      answered: said.values.join('; '),
      effect: 'Answered "${pending.title}".',
      granted: true,
      toolTitle: pending.title,
    );
  }

  /// Ends the agent: the open turn is cancelled, the peer closed, and the
  /// process killed when it has not exited within [stopPatience].
  Future<SessionLifecycle> stop() async {
    _stopping = true;
    if (!_lifecycle.hasEnded) cancel();
    await _tearDown();
    if (!_lifecycle.hasEnded) {
      _finish(
        SessionEndedWithoutCode(
          _now(),
          _transport == null
              ? 'asked to stop before its process had started'
              : 'asked to stop, killed after ${stopPatience.inSeconds} s, '
                    'and not reaped within another ${stopPatience.inSeconds} s',
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
    _usageTurnEnded();
    if (identical(_turn, turn)) _turn = null;
    _resolvePending(const PermissionOutcome.cancelled());
    if (failure != null && _stopping) {
      // The peer closed under the turn because this server stopped it.
      reason = StopReason.cancelled;
      _publish(AgentActivityStatus.idle, detail: reason.raw);
    } else if (failure is AcpRpcError && isUsageLimitError(failure)) {
      // Only the agent's words, so the reset read from them cannot come from
      // a timestamp in its stderr.
      _publish(
        AgentActivityStatus.failed,
        failureReason: kProtocolUsageLimitReason,
        detail: 'usage limit',
        evidence: usageLimitWords(failure),
      );
    } else if (failure != null) {
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
      _publish(
        _agentWorking ? AgentActivityStatus.working : AgentActivityStatus.idle,
        detail: _agentWorking ? _agentTurnDetail : reason?.raw,
        inFlight: _agentInFlight,
      );
    }
    if (identical(_turnSettled, settled)) _turnSettled = null;
    if (!settled.isCompleted) settled.complete(reason);
  }

  static const _agentTurnDetail = 'agent turn';

  /// The agent working on a turn no prompt asked for: working while it runs,
  /// idle after. A prompt's own turn keeps its status meanwhile.
  void _agentTurn({required bool started, List<String> inFlight = const []}) {
    final work = started ? inFlight : const <String>[];
    if (started == _agentWorking && _sameWork(work, _agentInFlight)) return;
    final was = _agentWorking;
    _agentWorking = started;
    _agentInFlight = work;
    if (_turn != null) return;
    if (!started && was) _writer.turnEnded();
    _publish(
      started ? AgentActivityStatus.working : AgentActivityStatus.idle,
      detail: _agentTurnDetail,
      inFlight: work,
    );
  }

  /// Background work the agent said it is still running, while it works on
  /// its own turn.
  List<String> _agentInFlight = const [];

  static bool _sameWork(List<String> a, List<String> b) =>
      a.join('\u0000') == b.join('\u0000');

  void _onUpdate(SessionUpdateEvent event) {
    final agent = _agentSessionId;
    if (agent != null &&
        event.sessionId.isNotEmpty &&
        event.sessionId != agent) {
      return;
    }
    final update = event.update;
    // Not conversation: an agent may announce these while it loads.
    if (update is AvailableCommandsUpdate) {
      _commands = update.commands;
      host.commandsChanged(_commandsChange(update.commands));
      return;
    }
    if (update is SessionInfoUpdate) {
      final title = update.title?.trim() ?? '';
      if (title.isNotEmpty) host.titleChanged(sessionId, title);
      return;
    }
    // A load replays the conversation the rows already hold.
    if (_loading) return;
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
    if (update is ConfigOptionUpdate) {
      _configOptions = update.configOptions;
      _announceConfigOptions();
      return;
    }
    if (update is UsageUpdate) {
      _usageReported(update);
      return;
    }
    if (update is UnknownUpdate && update.kind == AcpExtensions.agentTurn) {
      final inFlight = update.raw['inFlight'];
      _agentTurn(
        started: update.raw['state'] == 'started',
        inFlight: inFlight is List ? inFlight.whereType<String>().toList() : [],
      );
      return;
    }
    if (update is UnknownUpdate && update.kind == AcpExtensions.notice) {
      if (update.raw['text'] case final String text) _writer.notice(text);
      return;
    }
    if (update is UnknownUpdate && update.kind == AcpExtensions.compaction) {
      final trigger = update.raw['trigger'];
      final summary = update.raw['summary'];
      _writer.compaction(
        trigger: trigger is String ? trigger : null,
        summary: summary is String ? summary : '',
      );
      return;
    }
    if (update is ToolCallUpdate) {
      final before = _writer.toolCall(update.toolCallId);
      _writer.update(_withTerminalOutput(update));
      _noteEditPaths(before, _writer.toolCall(update.toolCallId) ?? update);
      return;
    }
    _writer.update(update);
  }

  // Terminals.

  /// [update] with each terminal it embeds carrying that terminal's output
  /// as it stands, and the embedding remembered for later refreshes.
  ToolCallUpdate _withTerminalOutput(ToolCallUpdate update) {
    final terminals = _terminals;
    final content = update.content;
    if (terminals == null || content == null) return update;
    var embeds = false;
    final folded = [
      for (final item in content)
        if (item is ToolCallTerminal)
          () {
            embeds = true;
            _terminalCalls
                .putIfAbsent(item.terminalId, () => {})
                .add(update.toolCallId);
            final shown = terminals.snapshot(item.terminalId);
            return shown == null
                ? item
                : ToolCallTerminal(
                    item.terminalId,
                    output: shown.output,
                    truncated: shown.truncated,
                    exitCode: shown.exitCode,
                  );
          }()
        else
          item,
    ];
    if (!embeds) return update;
    return ToolCallUpdate(
      toolCallId: update.toolCallId,
      isNew: update.isNew,
      title: update.title,
      name: update.name,
      kind: update.kind,
      status: update.status,
      content: folded,
      locations: update.locations,
      rawInput: update.rawInput,
      rawOutput: update.rawOutput,
    );
  }

  /// A terminal printed or ended: its output reaches the tool rows that
  /// embed it, at most once per [terminalRefresh].
  void _terminalMoved(String terminalId) {
    if (_torn) return;
    // An ended command's last word lands at once, before the agent reads it.
    if (_terminals?.snapshot(terminalId)?.exitCode != null) {
      _terminalTimers.remove(terminalId)?.cancel();
      _foldTerminal(terminalId);
      return;
    }
    if (_terminalTimers.containsKey(terminalId)) return;
    _terminalTimers[terminalId] = Timer(terminalRefresh, () {
      _terminalTimers.remove(terminalId);
      if (!_torn) _foldTerminal(terminalId);
    });
  }

  void _foldTerminal(String terminalId) {
    for (final callId in _terminalCalls[terminalId] ?? const <String>{}) {
      final call = _writer.toolCall(callId);
      if (call == null) continue;
      _writer.update(
        _withTerminalOutput(
          ToolCallUpdate(toolCallId: callId, content: call.content),
        ),
      );
    }
  }

  Future<Object?> _terminal(String method, Object? params) {
    final terminals = _terminals;
    if (terminals == null) throw AcpMethodNotSupported(method);
    return terminals.handle(method, asJsonMap(params) ?? const {});
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
      // A terminal method is never passed to `authenticate` (ACP v1).
      final byAgent = [
        for (final m in methods)
          if (!m.isTerminal) m.id,
      ];
      final chosen = spec.authMethodId;
      final method = chosen != null && byAgent.contains(chosen)
          ? chosen
          : (methods.length == 1 && byAgent.length == 1
                ? byAgent.single
                : null);
      if (method == null) {
        throw AcpLoginRequired(
          methods.isEmpty
              ? '$agentName asks to be authenticated (${error.message}) and '
                    'advertises no way to do it'
              : '$agentName asks to be logged in first. Choose Log in on its '
                    'row in Settings, then start the session again (it offers '
                    '${methods.map((m) => m.name.isEmpty ? m.id : m.name).join(', ')}).',
        );
      }
      try {
        await _client!.authenticate(method);
      } on AcpRpcError catch (refused) {
        throw AcpLoginRequired(
          '$agentName refused the login with "$method": ${refused.message}',
        );
      }
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

  void _announceConfigOptions() =>
      host.configOptionsChanged(_configOptionsChange(_configOptions)!);

  SessionConfigOptionsChanged? _configOptionsChange(
    List<ConfigOption>? options,
  ) {
    if (options == null && !_started) return null;
    return SessionConfigOptionsChanged(
      sessionId: sessionId,
      options: [
        for (final option in options ?? const <ConfigOption>[])
          SessionConfigOption(
            id: option.id,
            name: option.name,
            type: option.type,
            description: option.description,
            category: option.category,
            currentValue: switch (option.currentValue) {
              final String value => value,
              final bool value => value,
              _ => null,
            },
            choices: [
              for (final choice in option.options)
                SessionConfigChoice(
                  value: choice.value,
                  name: choice.name,
                  description: choice.description,
                  group: choice.group,
                ),
            ],
          ),
      ],
    );
  }

  // Usage.

  /// The agent's latest `usage_update`, as a client is told it; null until
  /// it has reported one.
  SessionUsageChanged? get reportedUsage => switch (_latestUsage) {
    final latest? => _usageChange(latest),
    null => null,
  };

  /// Kept as the latest report at once, so a restart answers it, and held
  /// as the turn's until the turn ends.
  void _usageReported(UsageUpdate update) {
    _latestUsage = update;
    if (_turn != null) _turnUsage = update;
    try {
      usage?.recordLatest(
        sessionId,
        contextUsed: update.used,
        contextSize: update.size,
        costAmount: update.cost?.amount,
        costCurrency: update.cost?.currency,
        at: _now(),
      );
    } on Object catch (error) {
      host.log('recording usage of session $sessionId failed: $error');
    }
    host.usageChanged(_usageChange(update));
  }

  /// The last report of the turn becomes the turn's entry.
  void _usageTurnEnded() {
    final last = _turnUsage;
    _turnUsage = null;
    if (last == null) return;
    try {
      usage?.recordTurn(
        sessionId,
        SessionUsageTurn(
          contextUsed: last.used,
          contextSize: last.size,
          costAmount: last.cost?.amount,
          costCurrency: last.cost?.currency,
        ),
        at: _now(),
      );
    } on Object catch (error) {
      host.log('recording a turn\'s usage of $sessionId failed: $error');
    }
  }

  SessionUsageChanged _usageChange(UsageUpdate update) => SessionUsageChanged(
    sessionId: sessionId,
    contextUsed: update.used,
    contextSize: update.size,
    costAmount: update.cost?.amount,
    costCurrency: update.cost?.currency,
  );

  /// The agent is gone, so it offers nothing to set: a client's picker for
  /// this session clears until a start announces again.
  void _announceGone() {
    if (!_started) return;
    _modes = null;
    _configOptions = null;
    _commands = null;
    _announceModes();
    _announceConfigOptions();
    host.commandsChanged(_commandsChange(const []));
    host.promptKindsChanged(
      SessionPromptKindsChanged(sessionId: sessionId, images: false),
    );
  }

  SessionCommandsChanged _commandsChange(List<AvailableCommand> commands) =>
      SessionCommandsChanged(
        sessionId: sessionId,
        commands: [
          for (final command in commands)
            if (command.name.isNotEmpty)
              SessionCommand(
                name: command.name,
                description: command.description,
                hint: command.inputHint,
              ),
        ],
      );

  // Permissions.

  Future<PermissionOutcome> _requestPermission(
    ToolCallUpdate call,
    List<PermissionOption> options,
  ) async {
    final title = _titleOf(call);
    final question = _questionIn(call);
    final rung = risk;
    // A question is the person's to answer at any rung.
    if (question == null &&
        rung != null &&
        !rung.isAtMost(PermissionRisk.acceptEdits)) {
      final switching = _modeSwitchingAllow(options);
      final once = switching != null
          ? switching.option
          : options
                .where((o) => o.kind == PermissionOptionKind.allowOnce)
                .firstOrNull;
      if (once != null) {
        await _holdForEdit(call);
        return PermissionOutcome.selected(once.optionId);
      }
    }
    final pending = _PendingPermission(call, options, title, question);
    _pending = pending;
    final now = _now();
    final input = call.rawInput;
    _publish(
      AgentActivityStatus.awaitingApproval,
      waiting: question == null
          ? AgentWaitKind.approval
          : AgentWaitKind.question,
      question: question,
      evidence: [title],
      toolAsk: AgentToolAsk(
        toolName: _toolNameOf(call) ?? title,
        input: input is Map ? pruneToolInput(input) : const {},
        at: now,
        toolUseId: call.toolCallId,
        cwd: workingDirectory,
        options: [
          for (final option in options)
            AgentToolAskOption(
              id: option.optionId,
              name: option.name,
              kind: option.kind.raw,
            ),
        ],
        kind: call.kind?.raw,
      ),
      waitingSince: now,
    );
    try {
      return await pending.completer.future;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  /// The tool [call] is, by the agent's own name for it: a `toolName` an
  /// agent puts in its `_meta`, else the call's `name`.
  static String? _toolNameOf(ToolCallUpdate call) {
    for (final value in call.meta?.values ?? const <Object?>[]) {
      if (asJsonMap(value)?['toolName'] case final String name
          when name.isNotEmpty) {
        return name;
      }
    }
    final name = call.name;
    return name == null || name.isEmpty ? null : name;
  }

  /// The questions a bridge carried whole under `_meta.karmashala.questions`
  /// — Claude's AskUserQuestion — or null for an ordinary permission.
  static AgentQuestionSet? _questionIn(ToolCallUpdate call) {
    final carried = asJsonMap(call.meta?['karmashala'])?['questions'];
    if (carried == null) return null;
    return AgentQuestionSet.fromToolInput(call.toolCallId, {
      'questions': carried,
    });
  }

  void _resolvePending(PermissionOutcome outcome) {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    if (!pending.completer.isCompleted) pending.completer.complete(outcome);
  }

  PermissionOption? _optionFor(
    List<PermissionOption> options, {
    required bool approve,
  }) {
    if (approve) {
      final switching = _modeSwitchingAllow(options);
      if (switching != null) return switching.option;
    }
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

  /// **An allow that switches the agent's mode never raises the session.**
  /// When any allow option names a mode the spec knows (a plan prompt's
  /// "accept edits", "ask before edits"), the one chosen is the highest at
  /// or below the session's rung; an option whose mode is unknown is never
  /// chosen. Null when no option names a mode: an ordinary call's request.
  ({PermissionOption? option})? _modeSwitchingAllow(
    List<PermissionOption> options,
  ) {
    final allows = [
      for (final option in options)
        if (option.kind == PermissionOptionKind.allowOnce ||
            option.kind == PermissionOptionKind.allowAlways)
          (option: option, rung: spec.rungOfOption(option.optionId)),
    ];
    if (!allows.any((allow) => allow.rung != null)) return null;
    // Approving a plan leaves read-only, so asking before every edit is the
    // floor: it grants nothing without asking.
    var ceiling = _workingRung ?? risk ?? PermissionRisk.ask;
    if (ceiling.isAtMost(PermissionRisk.readOnly)) ceiling = PermissionRisk.ask;
    PermissionOption? chosen;
    PermissionRisk? at;
    for (final allow in allows) {
      final rung = allow.rung;
      if (rung == null || !rung.isAtMost(ceiling)) continue;
      if (at == null || !rung.isAtMost(at)) {
        chosen = allow.option;
        at = rung;
      }
    }
    return (option: chosen);
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
    List<String> inFlight = const [],
    AgentQuestionSet? question,
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
        inFlight: inFlight,
      ),
      question: question,
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
    // Died on its own between turns: said as the agent's failure, with what
    // it left behind. A turn's own failure is published by `_settle`.
    if (code != 0 &&
        !_lifecycle.hasEnded &&
        !_closeRequested &&
        !_stoppingWithHost &&
        _turn == null) {
      _publish(
        AgentActivityStatus.failed,
        failureReason: 'exit',
        evidence: [_failureWords('exited', 'the process ended')],
      );
    }
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
    // Every command the agent left running ends with the session; the rows
    // keep what each printed.
    for (final timer in _terminalTimers.values) {
      timer.cancel();
    }
    _terminalTimers.clear();
    await _terminals?.releaseAll();
    for (final terminalId in _terminalCalls.keys) {
      _foldTerminal(terminalId);
    }
    _writer.close();
    _resolvePending(const PermissionOutcome.cancelled());
    _announceGone();
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
  _PendingPermission(this.call, this.options, this.title, this.question);

  final ToolCallUpdate call;
  final List<PermissionOption> options;
  final String title;

  /// The questions this request asks, when it is a question.
  final AgentQuestionSet? question;
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

  @override
  Future<Object?> terminal(String method, Object? params) =>
      _runtime._terminal(method, params);
}
