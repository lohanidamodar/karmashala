import 'dart:async';
import 'dart:convert';

import 'package:karmashala_acp/karmashala_acp.dart'
    show
        AcpIncomingRequest,
        AcpMethods,
        AcpNotification,
        AcpPeer,
        AcpRpcError,
        AcpVocabulary,
        JsonMap,
        JsonRpcErrorCodes;

import 'package:agent_cli/descriptors.dart' show claudeAcpDescriptor;
import 'package:agent_cli/read.dart' show kRedactedThinking;

import '../../domain/uuid.dart';
import '../acp_extensions.dart';
import '../acp_transport.dart';
import 'claude_process.dart';
import 'claude_tools.dart';

/// The Claude Code release this translation was checked against, live.
const String kClaudeStreamJsonVerifiedWith = '2.1.287';

/// The bridge for `AcpNativeBridge.claudeStreamJson`, over a `claude` started
/// with the arguments the claude-acp descriptor declares.
AcpTransport claudeStreamJsonBridge(AcpTransport raw) =>
    ClaudeStreamJsonBridge(raw);

/// **Claude Code spoken to in its own stream-json protocol — the one its
/// Agent SDK speaks to the binary — and ACP v1 to Karmashala.**
///
/// A conversation is chosen on argv (`--session-id`, `--resume`), so
/// `session/new` and `session/load` each start a fresh `claude` through the
/// raw transport's relaunch; the launcher's own process answers `initialize`
/// and is then retired. Everything after that is one process per
/// conversation, ended when its stdin closes.
///
/// What ACP has no field for travels in `_meta.claudeCode`: a tool's Claude
/// name and the subagent call it ran under, a subagent's task id, type and
/// progress, and a turn's duration, turn count and per-model usage.
final class ClaudeStreamJsonBridge implements AcpTransport {
  ClaudeStreamJsonBridge(
    AcpTransport raw, {
    Duration interruptPatience = const Duration(seconds: 5),
  }) : _relaunch = raw.relaunch,
       _interruptPatience = interruptPatience {
    _acp = AcpPeer(_fromClient.stream, _toClient.sink);
    _acp.requests.listen((request) => unawaited(_onRequest(request)));
    _acp.notifications.listen(_onNotification);
    unawaited(_acp.done.then((_) => _clientGone()));
    _adopt(raw);
  }

  final AcpRelaunch? _relaunch;

  /// How long Claude has to end a turn after the interrupt before its
  /// process is ended, as Orca does.
  final Duration _interruptPatience;
  final _toClient = StreamController<List<int>>();
  final _fromClient = StreamController<List<int>>();
  final _errors = StreamController<String>();
  final _exit = Completer<int>();
  late final AcpPeer _acp;

  ClaudeProcess? _claude;

  /// The process a `session/new` or `session/load` is opening: its death is
  /// that call's failure, not the session's.
  ClaudeProcess? _opening;

  // What `initialize` answered.
  var _loggedIn = false;
  List<JsonMap> _models = const [];
  List<JsonMap> _commands = const [];
  JsonMap? _lastInit;

  // The conversation.
  String _sessionId = '';
  String _mode = 'default';
  String _model = 'default';

  /// The effort `get_settings` last applied, or null where it named none or
  /// could not be read.
  String? _effort;

  /// Whether fast mode serves, by Claude's `fast_mode_state`.
  var _fast = false;

  // The turn.
  Completer<String>? _turn;
  var _cancelling = false;
  String? _streamId;
  final _streamed = <String>{};
  JsonMap? _lastUsage;
  JsonMap? _rateLimit;
  final _tools = <String, _Tool>{};
  final _planCalls = <String, (String, JsonMap)>{};
  final _tasks = <String, JsonMap>{};

  @override
  Stream<List<int>> get output => _toClient.stream;

  @override
  StreamSink<List<int>> get input => _fromClient.sink;

  @override
  Stream<String> get errorLines => _errors.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  AcpRelaunch? get relaunch => null;

  @override
  Future<void> kill() async {
    final claude = _claude ?? _opening;
    if (claude == null) {
      _finish(137);
      return;
    }
    await claude.kill();
  }

  // Processes.

  ClaudeProcess _adopt(AcpTransport transport) {
    late final ClaudeProcess claude;
    claude = ClaudeProcess(
      transport,
      onMessage: (message) {
        if (identical(_claude, claude)) _onClaude(message);
      },
      onControlRequest: (request) => identical(_claude, claude)
          ? _onClaudeRequest(request)
          : Future.error(const ClaudeControlError('not the live process')),
      onErrorLine: (line) {
        if (!_errors.isClosed) _errors.add(line);
      },
    );
    _claude = claude;
    unawaited(claude.ended.then((code) => _ended(claude, code)));
    return claude;
  }

  /// A `claude` for a conversation: [arguments] after the launcher's own,
  /// initialised, with [params]' MCP servers.
  Future<ClaudeProcess> _open(List<String> arguments, JsonMap params) async {
    final relaunch = _relaunch;
    if (relaunch == null) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.internalError,
        'Claude Code picks its conversation when it starts, and this '
        'process cannot be started again',
      );
    }
    final old = _claude;
    _claude = null;
    if (old != null) unawaited(_retire(old));
    final claude = _adopt(
      await relaunch([...arguments, ..._addDirArguments(params)]),
    );
    _opening = claude;
    try {
      _absorb(await claude.control('initialize'));
      final servers = _mcpServers(params['mcpServers']);
      if (servers.isNotEmpty) {
        try {
          await claude.control('mcp_set_servers', {'servers': servers});
        } on ClaudeControlError catch (error) {
          if (!_errors.isClosed) _errors.add('MCP servers refused: $error');
        }
      }
      await _readSettings(claude);
    } on ClaudeControlError {
      await claude.ended.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          return -1;
        },
      );
      if (identical(_claude, claude)) _claude = null;
      final stderr = claude.stderrTail;
      if (stderr.contains('No conversation found')) {
        throw AcpRpcError(JsonRpcErrorCodes.resourceNotFound, stderr);
      }
      throw AcpRpcError(
        JsonRpcErrorCodes.internalError,
        stderr.isEmpty ? 'Claude Code ended while starting' : stderr,
      );
    } finally {
      _opening = null;
    }
    _resetConversation();
    if (claude.hasEnded) _ended(claude, await claude.ended);
    return claude;
  }

  /// `additionalDirectories` as Claude's `--add-dir`, one token each: the
  /// option is variadic, and a separate value would swallow what follows.
  static List<String> _addDirArguments(JsonMap params) => [
    for (final directory in [
      ...?(params['additionalDirectories'] as List?)?.whereType<String>(),
    ])
      if (directory.isNotEmpty) '--add-dir=$directory',
  ];

  Future<void> _retire(ClaudeProcess claude) async {
    await claude.close();
    if (!await claude.endedWithin(const Duration(seconds: 5))) {
      await claude.kill();
    }
  }

  void _ended(ClaudeProcess claude, int code) {
    if (identical(_opening, claude) || !identical(_claude, claude)) return;
    _claude = null;
    final turn = _turn;
    _turn = null;
    if (turn != null && !turn.isCompleted) {
      final tail = claude.stderrTail;
      turn.completeError(
        AcpRpcError(
          JsonRpcErrorCodes.internalError,
          'Claude Code exited with code $code during the turn'
          '${tail.isEmpty ? '' : ': $tail'}',
        ),
      );
    }
    // The turn's error goes out before the exit, so it is read as the turn's.
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 20),
      ).then((_) => _finish(code)),
    );
  }

  void _finish(int code) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
    unawaited(_acp.close());
    unawaited(_errors.close());
  }

  void _clientGone() {
    final claude = _claude;
    if (claude == null) {
      if (_opening == null) _finish(0);
      return;
    }
    unawaited(_retire(claude));
  }

  // ACP from the client.

  Future<void> _onRequest(AcpIncomingRequest request) async {
    try {
      final params = request.paramsMap;
      final result = switch (request.method) {
        AcpMethods.initialize => await _initialize(),
        AcpMethods.authenticate => throw const AcpRpcError(
          JsonRpcErrorCodes.invalidRequest,
          'Claude Code logs in in a terminal: run `claude auth login`',
        ),
        AcpMethods.sessionNew => await _newSession(params),
        AcpMethods.sessionLoad => await _loadSession(params),
        AcpMethods.sessionPrompt => await _prompt(params),
        AcpMethods.sessionSetMode => await _setMode(params),
        AcpMethods.sessionSetConfigOption => await _setConfigOption(params),
        _ => throw AcpRpcError(
          JsonRpcErrorCodes.methodNotFound,
          'Method not found: ${request.method}',
        ),
      };
      request.respond(result);
    } on AcpRpcError catch (error) {
      request.fail(error.code, error.message, data: error.data);
    } on ClaudeControlError catch (error) {
      request.fail(JsonRpcErrorCodes.internalError, error.message);
    } on Object catch (error) {
      request.fail(JsonRpcErrorCodes.internalError, '$error');
    }
  }

  void _onNotification(AcpNotification notification) {
    if (notification.method == AcpMethods.sessionCancel) _cancel();
  }

  Future<JsonMap> _initialize() async {
    final claude = _claude;
    if (claude == null) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.internalError,
        'Claude Code is not running',
      );
    }
    final version = _readVersion();
    _absorb(await claude.control('initialize'));
    final account = jsonObject(_lastInit?['account']) ?? const {};
    return {
      'protocolVersion': AcpVocabulary.protocolVersion,
      'agentCapabilities': {
        'loadSession': true,
        'promptCapabilities': {
          'image': true,
          'audio': false,
          'embeddedContext': true,
        },
        'mcpCapabilities': {'http': true, 'sse': true},
        'sessionCapabilities': {'additionalDirectories': <String, Object?>{}},
      },
      'authMethods': [
        {
          'id': 'claude-login',
          'name': 'Log in to Claude Code',
          'description': 'Runs `claude auth login` in a terminal.',
          'type': 'terminal',
          'args': ['auth', 'login'],
          '_meta': {
            'terminal-auth': {
              'command': 'claude',
              'args': ['auth', 'login'],
              'label': 'Claude Code login',
            },
          },
        },
      ],
      'agentInfo': {
        'name': 'claude-code',
        'title': 'Claude Code',
        'version': await version ?? '',
      },
      '_meta': {
        'claudeCode': {
          'loggedIn': _loggedIn,
          'subscriptionType': ?account['subscriptionType'],
          'apiProvider': ?account['apiProvider'],
          'verifiedWith': kClaudeStreamJsonVerifiedWith,
        },
      },
    };
  }

  void _absorb(JsonMap? init) {
    final answer = init ?? const <String, Object?>{};
    _lastInit = answer;
    _models = jsonObjects(answer['models']);
    _commands = jsonObjects(answer['commands']);
    final mode = answer['current_permission_mode'];
    if (mode is String && mode.isNotEmpty) _mode = mode;
    _fast = _fastIn(answer['fast_mode_state']) ?? _fast;
    final account = jsonObject(answer['account']) ?? const {};
    final token = account['tokenSource'];
    _loggedIn =
        account['email'] is String ||
        (token is String && token != 'none') ||
        (account['apiProvider'] is String &&
            account['apiProvider'] != 'firstParty');
  }

  /// `claude --version`, read from a process of its own beside the launcher's.
  Future<String?> _readVersion() async {
    final relaunch = _relaunch;
    if (relaunch == null) return null;
    AcpTransport? process;
    try {
      process = await relaunch(const ['--version']);
      final errors = process.errorLines.listen((_) {}, onError: (Object _) {});
      final text = await process.output
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 15));
      await errors.cancel();
      return RegExp(r'\d+\.\d+\.\d+[\w.+-]*').firstMatch(text)?.group(0);
    } on Object {
      return null;
    } finally {
      unawaited(process?.kill().catchError((Object _) {}));
    }
  }

  Future<JsonMap> _newSession(JsonMap params) async {
    if (!_loggedIn) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.authRequired,
        'Claude Code is not logged in: run `claude auth login`',
      );
    }
    final id = newUuid();
    await _open(['--session-id', id], params);
    _openParams = params;
    _sessionId = id;
    _resumeAt = null;
    _announceCommands();
    _announceModel();
    return {
      'sessionId': id,
      'modes': _toldModesOf(_modes()),
      'configOptions': _configOptions(),
    };
  }

  Future<JsonMap> _loadSession(JsonMap params) async {
    final id = params['sessionId'];
    if (id is! String || id.isEmpty) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.invalidParams,
        'session/load needs a sessionId',
      );
    }
    final at = jsonObject(params['_meta'])?[AcpExtensions.resumeAt];
    final resumeAt = at is String && at.isNotEmpty ? at : null;
    // A load of the conversation already open (checkouts attached since)
    // keeps the mode and model the person had it in.
    final reopening = id == _sessionId;
    final held = _held;
    final claude = await _open(_resumeArguments(id, resumeAt), params);
    if (reopening) await _restore(claude, held);
    _openParams = params;
    _sessionId = id;
    _resumeAt = resumeAt;
    _announceCommands();
    _announceModel();
    return {'modes': _toldModesOf(_modes()), 'configOptions': _configOptions()};
  }

  /// A rewind's cut, kept until a prompt lands on it: a cut with nothing
  /// sent after it does not hold, so a resume before then cuts again.
  String? _resumeAt;

  static List<String> _resumeArguments(String id, String? resumeAt) => [
    '--resume',
    id,
    if (resumeAt != null) ...['--resume-session-at', resumeAt],
  ];

  /// What `default` resolves to, before Claude has replied with it. After the
  /// answer that names the session, so it is the session's.
  void _announceModel() =>
      scheduleMicrotask(() => _reportModel(_resolvedOf(_model)));

  void _resetConversation() {
    _turn = null;
    _cancelling = false;
    _streamId = null;
    _streamed.clear();
    _lastUsage = null;
    _reported = null;
    _agentTurnOpen = false;
    _tools.clear();
    _planCalls.clear();
    _tasks.clear();
    _model = 'default';
    _reportedModel = null;
  }

  Future<JsonMap> _prompt(JsonMap params) async {
    if (_claude == null && _abandoned && _turn == null) await _resume();
    final claude = _claude;
    if (claude == null || _sessionId.isEmpty) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.invalidRequest,
        'no Claude Code conversation is open',
      );
    }
    if (_turn != null) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.invalidRequest,
        'Claude Code is still working on the last prompt',
      );
    }
    final content = [
      for (final block in jsonObjects(params['prompt'])) ?_claudeContent(block),
    ];
    if (content.isEmpty) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.invalidParams,
        'the prompt has nothing Claude Code can read',
      );
    }
    final turn = _turn = Completer<String>();
    _cancelling = false;
    claude.send({
      'type': 'user',
      'message': {'role': 'user', 'content': content},
      'parent_tool_use_id': null,
      'session_id': _sessionId,
    });
    _resumeAt = null;
    return {'stopReason': await turn.future};
  }

  static JsonMap? _claudeContent(JsonMap block) {
    switch (block['type']) {
      case 'text':
        return {'type': 'text', 'text': '${block['text'] ?? ''}'};
      case 'image':
        return {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': block['mimeType'],
            'data': block['data'],
          },
        };
      case 'resource_link':
        return {'type': 'text', 'text': '${block['uri'] ?? ''}'};
      case 'resource':
        final resource = jsonObject(block['resource']) ?? const {};
        final text = resource['text'];
        if (text is! String) return null;
        return {
          'type': 'text',
          'text': '<context ref="${resource['uri'] ?? ''}">\n$text\n</context>',
        };
    }
    return null;
  }

  void _cancel() {
    final claude = _claude;
    final turn = _turn;
    if (turn == null || claude == null) return;
    _cancelling = true;
    unawaited(claude.control('interrupt').then((_) {}, onError: (Object _) {}));
    Timer(_interruptPatience, () {
      if (identical(_turn, turn) && identical(_claude, claude)) {
        _abandon(claude, turn);
      }
    });
  }

  /// Claude did not end the turn after the interrupt: the process is ended
  /// (its end is not the session's), the turn answers cancelled, and the
  /// next prompt resumes the conversation in a new process.
  void _abandon(ClaudeProcess claude, Completer<String> turn) {
    _claude = null;
    _turn = null;
    _cancelling = false;
    _abandoned = true;
    if (_agentTurnOpen) {
      _agentTurnOpen = false;
      _update({'sessionUpdate': AcpExtensions.agentTurn, 'state': 'ended'});
    }
    if (!turn.isCompleted) turn.complete('cancelled');
    unawaited(claude.kill().catchError((Object _) {}));
  }

  var _abandoned = false;

  /// The `session/new` or `session/load` params the conversation was opened
  /// with, for a resume after an abandoned turn.
  JsonMap _openParams = const {};

  Future<void> _resume() async {
    final held = _held;
    final claude = await _open(
      _resumeArguments(_sessionId, _resumeAt),
      _openParams,
    );
    _abandoned = false;
    await _restore(claude, held);
    // The new process lists its models afresh; the client is told.
    _update({'sessionUpdate': 'current_mode_update', 'currentModeId': _mode});
    _update({
      'sessionUpdate': 'config_option_update',
      'configOptions': _configOptions(),
    });
    _retellModes();
  }

  /// What a reopened conversation is put back in: its mode, model, effort
  /// and fast mode.
  ({String mode, String model, String? effort, bool fast}) get _held =>
      (mode: _mode, model: _model, effort: _effort, fast: _fast);

  /// Puts a reopened conversation back as [held] says. What the new process
  /// refuses stays as it started, which is then what is told.
  Future<void> _restore(
    ClaudeProcess claude,
    ({String mode, String model, String? effort, bool fast}) held,
  ) async {
    if (_mode != held.mode) {
      try {
        await claude.control('set_permission_mode', {'mode': held.mode});
        _mode = held.mode;
      } on ClaudeControlError {
        // Kept as Claude answered it.
      }
    }
    var flags = <String, Object?>{
      if (held.effort != null && held.effort != _effort)
        'effortLevel': held.effort,
      if (held.fast && !_fast) 'fastMode': true,
    };
    if (_model != held.model) {
      try {
        await claude.control('set_model', {'model': held.model});
        _model = held.model;
      } on ClaudeControlError {
        // Kept as Claude answered it.
      }
      flags = {...flags, if (held.effort != null) 'effortLevel': held.effort};
    }
    if (flags.isEmpty) return;
    try {
      await claude.control('apply_flag_settings', {'settings': flags});
      if (flags['fastMode'] == true) _fast = true;
    } on ClaudeControlError {
      // Kept as Claude answered it.
    }
    await _readSettings(claude);
  }

  /// Reads back the effort Claude applies and whether the fast-mode flag is
  /// on, with `get_settings` (2.1.296: `applied.effort`, null on a model
  /// without effort; the `flagSettings` source's `fastMode`, the only layer
  /// that opts a stream-json session in). A Claude that refuses it has no
  /// effort to offer.
  Future<void> _readSettings(ClaudeProcess claude) async {
    try {
      final answer = await claude.control('get_settings');
      final effort = jsonObject(answer?['applied'])?['effort'];
      _effort = effort is String && effort.isNotEmpty ? effort : null;
      for (final source in jsonObjects(answer?['sources'])) {
        if (source['source'] != 'flagSettings') continue;
        final fast = jsonObject(source['settings'])?['fastMode'];
        if (fast is bool) _fast = fast;
      }
    } on ClaudeControlError {
      _effort = null;
    }
  }

  /// Reads the effort again after a turn, and tells it where it moved.
  Future<void> _refreshEffort(ClaudeProcess claude) async {
    final before = _effort;
    await _readSettings(claude);
    if (_effort == before || !identical(_claude, claude)) return;
    _update({
      'sessionUpdate': 'config_option_update',
      'configOptions': _configOptions(),
    });
  }

  /// `fast_mode_state` (on, cooldown, off) as whether fast mode is chosen; a
  /// cooldown is fast mode resting after a rate limit.
  static bool? _fastIn(Object? state) => switch (state) {
    'on' || 'cooldown' => true,
    'off' => false,
    _ => null,
  };

  /// Follows a `fast_mode_state` Claude reported on init or a result.
  void _followFast(Object? state) {
    final fast = _fastIn(state);
    if (fast == null || fast == _fast) return;
    _fast = fast;
    if (_fastOption() == null) return;
    _update({
      'sessionUpdate': 'config_option_update',
      'configOptions': _configOptions(),
    });
  }

  Future<JsonMap> _setMode(JsonMap params) async {
    final mode = params['modeId'];
    final claude = _claude;
    if (mode is! String || claude == null) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.invalidParams,
        'session/set_mode needs a modeId and an open conversation',
      );
    }
    try {
      await claude.control('set_permission_mode', {'mode': mode});
    } on ClaudeControlError catch (error) {
      throw AcpRpcError(JsonRpcErrorCodes.invalidParams, error.message);
    }
    _mode = mode;
    return const {};
  }

  Future<JsonMap> _setConfigOption(JsonMap params) async {
    final claude = _claude;
    final id = params['configId'];
    final value = params['value'];
    final option = [
      for (final o in _configOptions())
        if (o['id'] == id) o,
    ].firstOrNull;
    final offered = [
      for (final choice in jsonObjects(option?['options'])) choice['value'],
    ];
    if (option == null ||
        value is! String ||
        claude == null ||
        (id != 'model' && !offered.contains(value))) {
      throw AcpRpcError(
        JsonRpcErrorCodes.invalidParams,
        'Claude Code has no config option "$id" to set to "$value"; it has '
        '${[for (final o in _configOptions()) o['id']].join(', ')}',
      );
    }
    try {
      switch (id) {
        case 'model':
          await claude.control('set_model', {'model': value});
          _model = value;
          _reportModel(
            _resolvedOf(value) ?? (value == 'default' ? null : value),
          );
          _retellModes();
        case 'effort':
          await claude.control('apply_flag_settings', {
            'settings': {'effortLevel': value},
          });
        case 'fast_mode':
          await claude.control('apply_flag_settings', {
            'settings': {'fastMode': value == 'on'},
          });
      }
    } on ClaudeControlError catch (error) {
      throw AcpRpcError(JsonRpcErrorCodes.invalidParams, error.message);
    }
    // What Claude applies, never what was asked: it takes a level a model
    // lacks without a word, and a model change moves the effort.
    await _readSettings(claude);
    return {'configOptions': _configOptions()};
  }

  // What ACP is told of the conversation.

  /// What set_permission_mode accepts (2.1.296: plan, dontAsk, default,
  /// acceptEdits, auto, bypassPermissions), named as the chat descriptor
  /// names them so the picker reads the same before a start and after.
  static final _modeNames = {
    for (final value
        in claudeAcpDescriptor.launch.permission.axes.single.values)
      value.id: (value.label, value.description),
  };

  JsonMap _modes() => {
    'currentModeId': _mode,
    'availableModes': [
      for (final MapEntry(key: id, value: (name, description))
          in _modeNames.entries)
        if (id != 'auto' || _mode == 'auto' || _offersAuto())
          {'id': id, 'name': name, 'description': description},
      if (!_modeNames.containsKey(_mode)) {'id': _mode, 'name': _mode},
    ],
  };

  /// The `models` row of the conversation's model, by its value.
  JsonMap? _modelRow() {
    for (final model in _models) {
      if (model['value'] == _model) return model;
    }
    return null;
  }

  /// Whether the model offers auto mode, by its row's `supportsAutoMode`
  /// (2.1.296; absent on a model without it, such as Haiku 4.5). A Claude
  /// whose rows never carry the field, or a model with no row, is not
  /// judged: auto stays offered, and a refusal is still met.
  bool _offersAuto() {
    if (!_models.any((m) => m.containsKey('supportsAutoMode'))) return true;
    final row = _modelRow();
    return row == null || row['supportsAutoMode'] == true;
  }

  /// The mode ids last told, so a model change retells them only when
  /// they moved.
  List<String> _toldModes = const [];

  JsonMap _toldModesOf(JsonMap modes) {
    _toldModes = [
      for (final mode in jsonObjects(modes['availableModes'])) '${mode['id']}',
    ];
    return modes;
  }

  /// After a model change: the modes again, where the model offers others.
  void _retellModes() {
    final modes = _modes();
    final ids = [
      for (final mode in jsonObjects(modes['availableModes'])) '${mode['id']}',
    ];
    if (ids.join(',') == _toldModes.join(',')) return;
    _toldModesOf(modes);
    _update({'sessionUpdate': AcpExtensions.availableModes, ...modes});
  }

  List<JsonMap> _configOptions() => [
    {
      'id': 'model',
      'name': 'Model',
      'type': 'select',
      'category': 'model',
      'currentValue': _model,
      'options': [
        for (final model in _models)
          {
            'value': model['value'],
            'name': model['displayName'] ?? model['value'],
            'description': ?model['description'],
          },
      ],
    },
    ?_effortOption(),
    ?_fastOption(),
  ];

  /// Claude's own words for its effort levels: the model picker's names
  /// ("xHigh") and `/effort`'s descriptions (2.1.296's binary).
  static const _effortWords = {
    'low': (
      'Low',
      'Quick, straightforward implementation with minimal '
          'overhead',
    ),
    'medium': (
      'Medium',
      'Balanced approach with standard implementation '
          'and testing',
    ),
    'high': (
      'High',
      'Comprehensive implementation with extensive testing '
          'and documentation',
    ),
    'xhigh': ('xHigh', 'Deeper reasoning than high, just below maximum'),
    'max': ('Max', 'Maximum capability with deepest reasoning'),
  };

  /// The effort picker, from the model row's `supportedEffortLevels`: none
  /// for a model without them, or where Claude did not say which it applies.
  JsonMap? _effortOption() {
    final effort = _effort;
    final levels = [
      ...?(_modelRow()?['supportedEffortLevels'] as List?)?.whereType<String>(),
    ];
    if (effort == null || levels.isEmpty) return null;
    return {
      'id': 'effort',
      'name': 'Effort',
      'type': 'select',
      'category': 'thought_level',
      'currentValue': effort,
      'options': [
        for (final level in levels)
          {
            'value': level,
            'name': _effortWords[level]?.$1 ?? level,
            'description': ?_effortWords[level]?.$2,
          },
      ],
    };
  }

  /// Fast mode, on a model whose row has `supportsFastMode`; set with
  /// `apply_flag_settings` `fastMode`, which Claude reports back as
  /// `fast_mode_state` (2.1.296, read live 2026-10-14).
  JsonMap? _fastOption() {
    if (_modelRow()?['supportsFastMode'] != true) return null;
    return {
      'id': 'fast_mode',
      'name': 'Speed',
      'type': 'select',
      'currentValue': _fast ? 'on' : 'off',
      'options': [
        {'value': 'off', 'name': 'Standard'},
        {
          'value': 'on',
          'name': 'Fast',
          // Claude's own words for it.
          'description': 'Same model, faster output. Draws from usage credits.',
        },
      ],
    };
  }

  void _announceCommands() {
    if (_commands.isEmpty) return;
    final commands = [
      for (final command in _commands)
        {
          'name': command['name'],
          'description': command['description'] ?? '',
          if (command['argumentHint'] case final String hint
              when hint.isNotEmpty)
            'input': {'hint': hint},
        },
    ];
    // After the answer that names the session, so it is the session's.
    scheduleMicrotask(
      () => _update({
        'sessionUpdate': 'available_commands_update',
        'availableCommands': commands,
      }),
    );
  }

  void _update(JsonMap update) => _acp.notify(AcpMethods.sessionUpdate, {
    'sessionId': _sessionId,
    'update': update,
  });

  void _followMode(String mode) {
    if (mode == _mode) return;
    _mode = mode;
    _update({'sessionUpdate': 'current_mode_update', 'currentModeId': mode});
  }

  String? _resolvedOf(String value) {
    for (final model in _models) {
      if (model['value'] == value) return model['resolvedModel'] as String?;
    }
    return null;
  }

  /// The model last told as running, so a reply naming it again says nothing.
  String? _reportedModel;

  /// Tells the client which model Claude is actually running: the option's
  /// value may be an alias such as `default`.
  void _reportModel(String? model) {
    if (model == null || model.isEmpty || model == '<synthetic>') return;
    if (model == _reportedModel || _sessionId.isEmpty) return;
    _reportedModel = model;
    _update({'sessionUpdate': AcpExtensions.activeModel, 'modelId': model});
  }

  void _followModel(String resolved) {
    _reportModel(resolved);
    if (_resolvedOf(_model) == resolved) return;
    for (final model in _models) {
      if (model['resolvedModel'] == resolved || model['value'] == resolved) {
        _model = '${model['value']}';
        _update({
          'sessionUpdate': 'config_option_update',
          'configOptions': _configOptions(),
        });
        _retellModes();
        return;
      }
    }
  }

  // Claude's stream.

  /// A compact_boundary's metadata, until the summary that follows it.
  JsonMap? _compaction;

  /// Says a compaction once the message after its boundary is in: Claude's
  /// summary (a user message of plain text, consumed here) or, when that
  /// is not it, none.
  bool _compacted(JsonMap message) {
    final metadata = _compaction;
    if (metadata == null) return false;
    _compaction = null;
    final content = jsonObject(message['message'])?['content'];
    final summary = message['type'] == 'user' && content is String
        ? content
        : null;
    _update({
      'sessionUpdate': AcpExtensions.compaction,
      'trigger': ?metadata['trigger'],
      'summary': ?summary,
      '_meta': {
        'claudeCode': {
          'preTokens': ?metadata['pre_tokens'],
          'postTokens': ?metadata['post_tokens'],
        },
      },
    });
    return summary != null;
  }

  /// Whether Claude is working on a turn no prompt asked for.
  var _agentTurnOpen = false;

  /// Background tasks Claude launched and has not reported on: task id to
  /// what it is doing. The session is not finished while any runs.
  final _background = <String, String>{};

  void _openAgentTurn() {
    _agentTurnOpen = true;
    _update({
      'sessionUpdate': AcpExtensions.agentTurn,
      'state': 'started',
      if (_background.isNotEmpty) 'inFlight': [..._background.values],
    });
  }

  void _onClaude(JsonMap message) {
    if (_compacted(message)) return;
    final parent = message['parent_tool_use_id'];
    final type = message['type'];
    if (_turn == null &&
        !_agentTurnOpen &&
        _sessionId.isNotEmpty &&
        (type == 'assistant' || type == 'stream_event' || type == 'user')) {
      _openAgentTurn();
    }
    switch (type) {
      case 'stream_event':
        if (parent == null) _onStreamEvent(jsonObject(message['event']));
      case 'assistant':
        _onAssistant(
          jsonObject(message['message']) ?? const {},
          parent is String ? parent : null,
        );
      case 'user':
        _onToolResults(message, parent is String ? parent : null);
      case 'system':
        _onSystem(message);
      case 'result':
        _onResult(message);
      case 'rate_limit_event':
        _onRateLimit(jsonObject(message['rate_limit_info']));
    }
  }

  void _onStreamEvent(JsonMap? event) {
    if (event == null) return;
    switch (event['type']) {
      case 'message_start':
        _streamId = jsonObject(event['message'])?['id'] as String?;
      case 'content_block_delta':
        final delta = jsonObject(event['delta']) ?? const {};
        final id = _streamId;
        switch (delta['type']) {
          case 'text_delta':
            if (id != null) _streamed.add(id);
            _chunk('agent_message_chunk', delta['text'], id);
          case 'thinking_delta':
            if (id != null) _streamed.add(id);
            _chunk('agent_thought_chunk', delta['thinking'], id);
        }
    }
  }

  void _chunk(String kind, Object? text, String? messageId) {
    if (text is! String || text.isEmpty) return;
    _update({
      'sessionUpdate': kind,
      'content': {'type': 'text', 'text': text},
      'messageId': ?messageId,
    });
  }

  void _onAssistant(JsonMap message, String? parent) {
    final id = message['id'] as String?;
    if (parent == null) {
      final usage = jsonObject(message['usage']);
      if (usage != null) _lastUsage = usage;
    }
    if (parent == null) _reportModel(message['model'] as String?);
    final streamed = id != null && _streamed.contains(id);
    for (final block in jsonObjects(message['content'])) {
      switch (block['type']) {
        case 'text':
          if (parent != null) {
            _subagentSaid(parent, block['text']);
          } else if (!streamed) {
            _chunk('agent_message_chunk', block['text'], id);
          }
        case 'thinking':
          if (parent == null && !streamed) {
            _chunk('agent_thought_chunk', block['thinking'], id);
          }
        // Never streamed: it has no delta, only encrypted data.
        case 'redacted_thinking':
          if (parent == null) {
            _chunk('agent_thought_chunk', kRedactedThinking, id);
          }
        case 'tool_use':
          _onToolUse(block, parent);
      }
    }
  }

  void _onToolUse(JsonMap block, String? parent) {
    final id = block['id'];
    final name = block['name'];
    if (id is! String || name is! String) return;
    final input = jsonObject(block['input']) ?? const {};
    if (ClaudeTools.planTools.contains(name)) {
      _planCalls[id] = (name, input);
      if (name == 'TodoWrite' && parent == null) _todos(input);
      return;
    }
    final tool = _tools[id] = _Tool(name, input, parent);
    // A subagent's call is a step on its Agent call, where the chat draws it.
    if (parent != null) {
      final title = ClaudeTools.title(name, input);
      _subagentSaid(parent, title == name ? name : '$name · $title');
    }
    _update({
      'sessionUpdate': 'tool_call',
      ..._toolFields(id, tool),
      'status': 'pending',
    });
  }

  JsonMap _toolFields(String id, _Tool tool) => {
    'toolCallId': id,
    'title': ClaudeTools.title(tool.name, tool.input),
    'kind': ClaudeTools.kind(tool.name),
    'rawInput': tool.input,
    if (tool.diffs.isNotEmpty) 'content': tool.diffs,
    'locations': ?ClaudeTools.locations(tool.name, tool.input),
    '_meta': {
      'claudeCode': {'toolName': tool.name, 'parentToolUseId': ?tool.parent},
    },
  };

  void _onToolResults(JsonMap message, String? parent) {
    final content = jsonObject(message['message'])?['content'];
    for (final block in jsonObjects(content)) {
      if (block['type'] != 'tool_result') continue;
      final id = block['tool_use_id'];
      if (id is! String) continue;
      final isError = block['is_error'] == true;
      final planCall = _planCalls.remove(id);
      if (planCall != null) {
        if (!isError) _taskResult(planCall, message['tool_use_result']);
        continue;
      }
      final tool = _tools[id];
      if (tool == null) continue;
      final text = ClaudeTools.resultTextOf(
        block['content'],
        message['tool_use_result'],
      );
      if (tool.background && !isError) {
        tool.notes.add(text);
        continue;
      }
      final diffs =
          (isError
              ? null
              : ClaudeTools.resultDiffs(
                  tool.name,
                  message['tool_use_result'],
                )) ??
          tool.diffs;
      _update({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': id,
        'status': isError ? 'failed' : 'completed',
        'content': [
          ...diffs,
          if (text.isNotEmpty && (diffs.isEmpty || isError))
            ClaudeTools.text(text),
          ...ClaudeTools.images(block['content']),
        ],
        'rawOutput': text,
      });
    }
  }

  void _todos(JsonMap input) => _plan([
    for (final todo in jsonObjects(input['todos']))
      (todo['content'] ?? '', todo['status']),
  ]);

  void _taskResult((String, JsonMap) call, Object? result) {
    final (name, input) = call;
    switch (name) {
      case 'TaskCreate':
        final task = jsonObject(jsonObject(result)?['task']);
        final id = task?['id'];
        if (id == null) return;
        _tasks['$id'] = {
          'subject': task?['subject'] ?? input['subject'] ?? '',
          'status': 'pending',
        };
      case 'TaskUpdate':
        final id = '${input['taskId']}';
        final task = _tasks[id];
        if (task == null) return;
        if (input['status'] == 'deleted') {
          _tasks.remove(id);
        } else {
          _tasks[id] = {
            'subject': input['subject'] ?? task['subject'],
            'status': input['status'] ?? task['status'],
          };
        }
      default:
        return;
    }
    final ids = _tasks.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    _plan([
      for (final id in ids) (_tasks[id]!['subject'], _tasks[id]!['status']),
    ]);
  }

  void _plan(List<(Object?, Object?)> entries) => _update({
    'sessionUpdate': 'plan',
    'entries': [
      for (final (content, status) in entries)
        {
          'content': '$content',
          'priority': 'medium',
          'status': ClaudeTools.planStatus(status),
        },
    ],
  });

  void _subagentSaid(String parent, Object? text) {
    final tool = _tools[parent];
    if (tool == null || text is! String || text.trim().isEmpty) return;
    tool.transcript.add(text);
    _update({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': parent,
      'content': [for (final said in tool.transcript) ClaudeTools.text(said)],
    });
  }

  void _onSystem(JsonMap message) {
    switch (message['subtype']) {
      case 'init':
        if (message['model'] case final String model) _followModel(model);
        _followFast(message['fast_mode_state']);
        if (message['permissionMode'] case final String mode) {
          _followMode(mode);
        }
      case 'status':
        if (message['permissionMode'] case final String mode) {
          _followMode(mode);
        }
      case 'compact_boundary':
        _compaction = jsonObject(message['compact_metadata']) ?? const {};
      case 'hook_response':
        if (ClaudeTools.hookNote(message) case final note?) {
          _update({'sessionUpdate': AcpExtensions.notice, 'text': note});
        }
      case 'task_started' || 'task_progress' || 'task_notification':
        _trackBackground(message);
        _onTask(message);
    }
  }

  void _trackBackground(JsonMap message) {
    final id = message['task_id'];
    if (id is! String) return;
    final before = _background.length;
    switch (message['subtype']) {
      // Only a task Claude says it backgrounded: one without the field may
      // never report back, and would hold a finished turn open.
      case 'task_started' when message['is_backgrounded'] == true:
        final description = message['description'];
        _background[id] = description is String && description.isNotEmpty
            ? description
            : 'background task';
      case 'task_notification':
        _background.remove(id);
      default:
        return;
    }
    // While Claude rests on them, the session says what is left.
    if (_agentTurnOpen && _turn == null && _background.length != before) {
      if (_background.isNotEmpty) _openAgentTurn();
    }
  }

  void _onTask(JsonMap message) {
    final id = message['tool_use_id'];
    final tool = id is String ? _tools[id] : null;
    if (tool == null) return;
    final task = {
      'taskId': ?message['task_id'],
      'description': ?message['description'],
      'subagentType': ?message['subagent_type'],
      'lastToolName': ?message['last_tool_name'],
    };
    switch (message['subtype']) {
      case 'task_started':
        tool.background = message['is_backgrounded'] != false;
        _update({
          'sessionUpdate': 'tool_call_update',
          'toolCallId': id,
          'status': 'in_progress',
          '_meta': {
            'claudeCode': {
              'task': {...task, 'background': tool.background},
            },
          },
        });
      case 'task_progress':
        _update({
          'sessionUpdate': 'tool_call_update',
          'toolCallId': id,
          '_meta': {
            'claudeCode': {'task': task},
          },
        });
      case 'task_notification':
        tool.background = false;
        final summary = message['summary'];
        if (summary is String &&
            summary.trim().isNotEmpty &&
            (tool.transcript.isEmpty || tool.transcript.last != summary)) {
          tool.transcript.add(summary);
        }
        _update({
          'sessionUpdate': 'tool_call_update',
          'toolCallId': id,
          'status': message['status'] == 'completed' ? 'completed' : 'failed',
          'content': [
            for (final said in [...tool.notes, ...tool.transcript])
              ClaudeTools.text(said),
          ],
        });
    }
  }

  void _onResult(JsonMap message) {
    _reportUsage(message);
    _followFast(message['fast_mode_state']);
    // `/effort` sent as a prompt moves it with no other word.
    final claude = _claude;
    if (claude != null) unawaited(_refreshEffort(claude));
    final turn = _turn;
    // A turn Claude began itself (a background task finishing) carries its
    // origin and answers no prompt, even one queued behind it.
    if (turn == null || message['origin'] != null) {
      // Claude's own turn ended, but work it launched still runs.
      if (_agentTurnOpen && _background.isEmpty) {
        _agentTurnOpen = false;
        _update({'sessionUpdate': AcpExtensions.agentTurn, 'state': 'ended'});
      }
      return;
    }
    _turn = null;
    // The prompt's turn ended and handed off to background work: said before
    // the answer, so the session never reads finished in between.
    if (_background.isNotEmpty && !_agentTurnOpen) _openAgentTurn();
    final subtype = message['subtype'];
    final isError = message['is_error'] == true;
    if (_cancelling) {
      _cancelling = false;
      turn.complete('cancelled');
    } else if (subtype == 'success' && !isError) {
      turn.complete(switch (message['stop_reason']) {
        'max_tokens' => 'max_tokens',
        'refusal' => 'refusal',
        _ => 'end_turn',
      });
    } else if (subtype == 'error_max_turns') {
      turn.complete('max_turn_requests');
    } else {
      final result = message['result'];
      final errors = message['errors'];
      // Only a limit that refused, so a passing or warned one never reads as
      // a usage limit.
      final limit = _rateLimit?['status'] == 'rejected' ? _rateLimit : null;
      turn.completeError(
        AcpRpcError(
          JsonRpcErrorCodes.internalError,
          limit != null
              ? _limitWords(limit)
              : result is String && result.isNotEmpty
              ? result
              : errors is List && errors.isNotEmpty
              ? errors.join('; ')
              : 'Claude Code ended the turn: $subtype',
          data: {
            'subtype': subtype,
            'result': ?result,
            'apiErrorStatus': ?message['api_error_status'],
            'rateLimit': ?limit,
          },
        ),
      );
    }
  }

  /// A refused limit in the words the runtime reads a usage limit and its
  /// reset from.
  static String _limitWords(JsonMap limit) {
    final kind = limit['rateLimitType'] ?? 'usage';
    final resets = limit['resetsAt'];
    final at = resets is int
        ? DateTime.fromMillisecondsSinceEpoch(resets * 1000, isUtc: true)
        : null;
    return "Claude Code's $kind usage limit is reached"
        '${at == null ? '' : '; it resets at ${at.toIso8601String()}'}.';
  }

  /// The context and cost last reported, which a rate-limit update repeats.
  ({int used, int size, num? cost})? _reported;
  var _limitUnsent = false;

  void _onRateLimit(JsonMap? info) {
    if (info == null) return;
    _rateLimit = info;
    final reported = _reported;
    if (reported == null) {
      // A usage update needs the context; this one rides on the next.
      _limitUnsent = true;
      return;
    }
    _sendUsage(reported, {'rateLimit': info});
  }

  void _reportUsage(JsonMap result) {
    var size = 0;
    for (final usage in jsonObject(result['modelUsage'])?.values ?? const []) {
      final window = jsonObject(usage)?['contextWindow'];
      if (window is int && window > size) size = window;
    }
    if (size == 0) return;
    final last = _lastUsage ?? const {};
    int tokens(String key) => switch (last[key]) {
      final int n => n,
      _ => 0,
    };
    final cost = result['total_cost_usd'];
    final reported = _reported = (
      used:
          tokens('input_tokens') +
          tokens('cache_creation_input_tokens') +
          tokens('cache_read_input_tokens') +
          tokens('output_tokens'),
      size: size,
      cost: cost is num ? cost : null,
    );
    _sendUsage(reported, {
      'durationMs': ?result['duration_ms'],
      'durationApiMs': ?result['duration_api_ms'],
      'numTurns': ?result['num_turns'],
      'modelUsage': ?result['modelUsage'],
      'origin': ?result['origin'],
      if (_limitUnsent) 'rateLimit': ?_rateLimit,
    });
    _limitUnsent = false;
  }

  void _sendUsage(({int used, int size, num? cost}) usage, JsonMap meta) =>
      _update({
        'sessionUpdate': 'usage_update',
        'used': usage.used,
        'size': usage.size,
        if (usage.cost case final cost?)
          'cost': {'amount': cost, 'currency': 'USD'},
        '_meta': {'claudeCode': meta},
      });

  // Claude's requests of the client.

  Future<JsonMap?> _onClaudeRequest(JsonMap request) async {
    switch (request['subtype']) {
      case 'can_use_tool':
        return _canUseTool(request);
      case 'hook_callback':
        return const {};
    }
    throw ClaudeControlError(
      'Karmashala does not answer ${request['subtype']} requests',
    );
  }

  Future<JsonMap> _canUseTool(JsonMap request) async {
    final name = '${request['tool_name'] ?? ''}';
    final input = jsonObject(request['input']) ?? const {};
    final id = '${request['tool_use_id'] ?? ''}';
    final suggestions = jsonObjects(request['permission_suggestions']);
    if (name == 'AskUserQuestion') return _ask(id, input);
    final tool = _tools[id] ?? _Tool(name, input, null);
    final exitPlan = name == 'ExitPlanMode';
    final options = exitPlan
        ? [
            // An approval picks it only for a session whose rung is auto.
            _option('auto', 'Yes, and use auto mode', 'allow_always'),
            _option('acceptEdits', 'Yes, and accept edits', 'allow_always'),
            _option('default', 'Yes, and ask before edits', 'allow_once'),
            _option('plan', 'No, keep planning', 'reject_once'),
          ]
        : [
            _option('allow', 'Allow', 'allow_once'),
            if (suggestions.isNotEmpty)
              _option('allow_always', 'Always allow', 'allow_always'),
            _option('reject', 'Reject', 'reject_once'),
          ];
    Object? answer;
    try {
      answer = await _acp.call(AcpMethods.sessionRequestPermission, {
        'sessionId': _sessionId,
        'toolCall': {..._toolFields(id, tool), 'status': 'pending'},
        'options': options,
      });
    } on Object {
      answer = null;
    }
    final outcome = jsonObject(jsonObject(answer)?['outcome']) ?? const {};
    final chosen = outcome['outcome'] == 'selected'
        ? outcome['optionId']
        : null;
    if (chosen == null) {
      return const {
        'behavior': 'deny',
        'message': 'The person cancelled the turn.',
        'interrupt': true,
      };
    }
    if (exitPlan) {
      if (chosen == 'plan') {
        return const {
          'behavior': 'deny',
          'message': 'The person wants to keep planning.',
        };
      }
      _followMode('$chosen');
      return {
        'behavior': 'allow',
        'updatedInput': input,
        'updatedPermissions': [
          {'type': 'setMode', 'mode': chosen, 'destination': 'session'},
        ],
      };
    }
    if (chosen == 'reject') {
      return const {
        'behavior': 'deny',
        'message': 'The person rejected this tool call.',
      };
    }
    if (_tools.containsKey(id)) {
      _update({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': id,
        'status': 'in_progress',
      });
    }
    return {
      'behavior': 'allow',
      'updatedInput': input,
      if (chosen == 'allow_always') 'updatedPermissions': suggestions,
    };
  }

  /// Claude's questions, asked together as one permission that carries them
  /// whole under `_meta.karmashala.questions`; a client that can show them
  /// answers "Send answer" with `_meta.karmashala.answers` (question text to
  /// the chosen labels, comma-joined, or the person's own words), which go
  /// back as `answers` as Claude reads them. Questions without choices, ones
  /// asked where nobody answers prompts (bypass, which the runtime answers
  /// itself), or ones left to the person's reply are shown in the chat and
  /// declined.
  Future<JsonMap> _ask(String id, JsonMap input) async {
    final questions = jsonObjects(input['questions']);
    final askable =
        questions.isNotEmpty &&
        _mode != 'bypassPermissions' &&
        questions.every(
          (q) => jsonObjects(q['options']).any((o) => o['label'] is String),
        );
    if (askable) {
      Object? answer;
      try {
        answer = await _acp.call(AcpMethods.sessionRequestPermission, {
          'sessionId': _sessionId,
          'toolCall': {
            'toolCallId': id,
            'title': questions.length == 1
                ? '${questions.single['question'] ?? ''}'
                : '${questions.length} questions',
            'kind': 'other',
            'status': 'pending',
            'rawInput': input,
            'content': [
              ClaudeTools.text(
                [for (final q in questions) _questionWords(q)].join('\n\n'),
              ),
            ],
            '_meta': {
              'claudeCode': {'toolName': 'AskUserQuestion'},
              'karmashala': {
                'questions': [
                  for (final q in questions) {...q, 'ownWords': _drawsOther(q)},
                ],
              },
            },
          },
          'options': [
            _option('answer', 'Send answer', 'allow_once'),
            _option('reply', 'Answer in my reply', 'reject_once'),
          ],
        });
      } on Object {
        answer = null;
      }
      final outcome = jsonObject(jsonObject(answer)?['outcome']) ?? const {};
      if (outcome['outcome'] != 'selected') {
        return const {
          'behavior': 'deny',
          'message': 'The person cancelled the turn.',
          'interrupt': true,
        };
      }
      final answers = jsonObject(
        jsonObject(jsonObject(outcome['_meta'])?['karmashala'])?['answers'],
      );
      if (outcome['optionId'] == 'answer' &&
          answers != null &&
          answers.isNotEmpty &&
          answers.values.every((a) => a is String)) {
        // The call keeps what was picked, for the chat to show.
        if (_tools.containsKey(id)) {
          _update({
            'sessionUpdate': 'tool_call_update',
            'toolCallId': id,
            'rawInput': {...input, 'answers': answers},
          });
        }
        return {
          'behavior': 'allow',
          'updatedInput': {...input, 'answers': answers},
        };
      }
    }
    final shown = [for (final q in questions) _questionWords(q)].join('\n\n');
    _chunk(
      'agent_message_chunk',
      '\n\nClaude asked:\n\n$shown\n\nAnswer in your next message.\n',
      null,
    );
    return {
      'behavior': 'deny',
      'message':
          'The person will answer in their next message instead. '
          'Unanswered: ${[for (final q in questions) q['question']].join('; ')}',
    };
  }

  /// Whether Claude draws its Other row under [question]: 2.1.296 draws it
  /// under every question but a single-choice one whose options carry a
  /// `preview` key, which it lays out side by side instead.
  static bool _drawsOther(JsonMap question) =>
      question['multiSelect'] == true ||
      !jsonObjects(question['options']).any((o) => o.containsKey('preview'));

  static String _questionWords(JsonMap question) => [
    '${question['question'] ?? ''}',
    for (final option in jsonObjects(question['options']))
      '- ${option['label']}'
          '${option['description'] is String ? ': ${option['description']}' : ''}',
    if (question['multiSelect'] == true) '(Several may apply.)',
  ].join('\n');

  static JsonMap _option(String id, String name, String kind) => {
    'optionId': id,
    'name': name,
    'kind': kind,
  };

  /// ACP's MCP servers as Claude's `mcp_set_servers` takes them, by name.
  static JsonMap _mcpServers(Object? servers) => {
    for (final server in jsonObjects(servers))
      if (server['name'] case final String name)
        name: switch (server['type']) {
          'http' || 'sse' => {
            'type': server['type'],
            'url': server['url'],
            'headers': _pairs(server['headers']),
          },
          _ => {
            'type': 'stdio',
            'command': server['command'],
            'args': server['args'] ?? const <String>[],
            'env': _pairs(server['env']),
          },
        },
  };

  static JsonMap _pairs(Object? pairs) => {
    for (final pair in jsonObjects(pairs))
      if (pair['name'] case final String name) name: pair['value'],
  };
}

/// A tool call Claude made, as this conversation knows it.
final class _Tool {
  _Tool(this.name, this.input, this.parent)
    : diffs = ClaudeTools.diffs(name, input);

  final String name;
  final JsonMap input;

  /// The subagent call this one ran under.
  final String? parent;
  final List<JsonMap> diffs;

  /// A subagent's words, for its Task call.
  final transcript = <String>[];

  /// What a backgrounded subagent's call answered at once.
  final notes = <String>[];
  var background = false;
}
