import 'dart:async';

import 'package:karmashala_acp/karmashala_acp.dart';

import '../acp_transport.dart';
import 'codex_acp_mapping.dart';

/// Codex driven over its own `codex app-server` JSON-RPC (v2, as
/// [kCodexAppServerProtocolSource] has it) and spoken to Karmashala as ACP v1.
AcpTransport codexAppServerBridge(AcpTransport raw) =>
    CodexAppServerBridge(raw);

/// One `codex app-server` process as an ACP agent: requests from the client
/// become thread and turn calls, Codex's notifications become
/// `session/update`s, and its approval requests become
/// `session/request_permission`. What ACP has no field for rides in
/// `_meta.codex`.
final class CodexAppServerBridge implements AcpTransport {
  CodexAppServerBridge(
    this._raw, {
    this.loginPatience = const Duration(minutes: 10),
    this.outputEvery = const Duration(milliseconds: 100),
  }) {
    _codex = AcpPeer(_raw.output, _raw.input);
    _client = AcpPeer(_fromClient.stream, _toClient.sink);
    _codex.requests.listen(_onCodexRequest);
    _codex.notifications.listen(_onCodexNotification);
    _client.requests.listen(_onClientRequest);
    _client.notifications.listen(_onClientNotification);
    _raw.errorLines.listen(_say, onError: (Object _) {});
    unawaited(_codex.done.then((_) => _codexGone()));
    unawaited(_client.done.then((_) => _codex.close()));
  }

  final AcpTransport _raw;

  /// How long `authenticate` waits on a browser login a person completes.
  final Duration loginPatience;

  /// How often a running command's output is sent on.
  final Duration outputEvery;

  late final AcpPeer _codex;
  late final AcpPeer _client;
  final _toClient = StreamController<List<int>>();
  final _fromClient = StreamController<List<int>>();
  final _errors = StreamController<String>();

  JsonMap? _account;
  var _requiresLogin = false;
  Completer<JsonMap>? _login;
  String? _loginId;

  String? _threadId;
  String _cwd = '';
  CodexMode _mode = kCodexModes[1];
  JsonMap? _sandbox;
  var _modeChosen = false;
  String? _model;
  String? _effort;
  var _modelChosen = false;
  List<JsonMap> _models = const [];

  Completer<JsonMap>? _turn;
  String? _turnId;
  var _interruptWanted = false;
  String? _turnDiff;
  JsonMap? _rateLimits;
  JsonMap? _usage;
  final _tools = <String, JsonMap>{};
  final _output = <String, StringBuffer>{};
  final _outputDue = <String>{};
  Timer? _outputTimer;
  final _streamed = <String>{};

  @override
  Stream<List<int>> get output => _toClient.stream;

  @override
  StreamSink<List<int>> get input => _fromClient.sink;

  @override
  Stream<String> get errorLines => _errors.stream;

  @override
  Future<int> get exitCode => _raw.exitCode;

  @override
  Future<void> kill() => _raw.kill();

  // The client's side.

  Future<void> _onClientRequest(AcpIncomingRequest request) async {
    try {
      final params = request.paramsMap;
      final result = await switch (request.method) {
        AcpMethods.initialize => _initialize(params),
        AcpMethods.authenticate => _authenticate(params),
        AcpMethods.logout => _logout(),
        AcpMethods.sessionNew => _newSession(params),
        AcpMethods.sessionLoad => _loadSession(params),
        AcpMethods.sessionPrompt => _prompt(params),
        AcpMethods.sessionSetMode => _setMode(params),
        AcpMethods.sessionSetConfigOption => _setConfigOption(params),
        _ => throw AcpRpcError(
          JsonRpcErrorCodes.methodNotFound,
          'Method not found: ${request.method}',
        ),
      };
      request.respond(result);
    } on AcpRpcError catch (error) {
      request.fail(error.code, error.message, data: error.data);
    } on AcpPeerClosed {
      request.fail(JsonRpcErrorCodes.internalError, 'Codex has exited');
    } on Object catch (error) {
      request.fail(JsonRpcErrorCodes.internalError, '$error');
    }
  }

  void _onClientNotification(AcpNotification notification) {
    if (notification.method == AcpMethods.sessionCancel) _interrupt();
  }

  Future<JsonMap> _initialize(JsonMap params) async {
    final info = _map(params['clientInfo']);
    final init = _map(
      await _call('initialize', {
        'clientInfo': {
          'name': info['name'] ?? 'Karmashala',
          'title': info['title'],
          'version': info['version'] ?? '0',
        },
        'capabilities': {'experimentalApi': false, 'requestAttestation': false},
      }),
    );
    _codex.notify('initialized', null);
    await _readAccount();
    final account = _account;
    return {
      'protocolVersion': AcpVocabulary.protocolVersion,
      'agentCapabilities': {
        'loadSession': true,
        'promptCapabilities': {
          'image': true,
          'audio': false,
          'embeddedContext': true,
        },
        'mcpCapabilities': {'http': true, 'sse': false},
        'auth': {'logout': <String, Object?>{}},
      },
      'authMethods': [
        {
          'id': 'chatgpt',
          'name': 'Log in with ChatGPT',
          'description': switch (account?['type']) {
            'chatgpt' =>
              'Codex is logged in with ChatGPT'
                  '${account?['planType'] is String ? ' (${account!['planType']} plan)' : ''}.',
            'apiKey' => 'Codex is using an API key.',
            final String other => 'Codex is logged in ($other).',
            _ => 'Opens a browser to sign in to ChatGPT for Codex.',
          },
        },
      ],
      'agentInfo': {
        'name': 'codex',
        'title': 'Codex',
        'version': codexVersionOf(init['userAgent']) ?? '',
      },
      '_meta': {
        'codex': {
          'protocol': kCodexAppServerProtocolSource,
          'platformOs': init['platformOs'],
          'accountType': account?['type'],
          'planType': account?['planType'],
        },
      },
    };
  }

  Future<void> _readAccount() async {
    final read = _map(await _call('account/read', {'refreshToken': false}));
    _account = read['account'] is Map ? _map(read['account']) : null;
    _requiresLogin = read['requiresOpenaiAuth'] == true;
  }

  Future<JsonMap> _authenticate(JsonMap params) async {
    final method = params['methodId'];
    if (method != 'chatgpt') {
      throw AcpRpcError(
        JsonRpcErrorCodes.invalidParams,
        'Codex offers no login "$method"; it offers chatgpt',
      );
    }
    if (_account != null) return const {};
    final done = _login = Completer<JsonMap>();
    _loginId = null;
    final started = _map(
      await _call('account/login/start', {'type': 'chatgpt'}),
    );
    final link = started['authUrl'];
    _loginId = started['loginId'] as String?;
    _say('Open this link to log in to Codex: $link');
    final JsonMap outcome;
    try {
      outcome = await done.future.timeout(loginPatience);
    } on TimeoutException {
      unawaited(
        _codex
            .call('account/login/cancel', {'loginId': _loginId})
            .then((_) {}, onError: (Object _) {}),
      );
      throw AcpRpcError(
        JsonRpcErrorCodes.internalError,
        'The Codex login was not completed within '
        '${loginPatience.inMinutes} minutes',
      );
    } finally {
      _login = null;
    }
    if (outcome['success'] != true) {
      throw AcpRpcError(
        JsonRpcErrorCodes.internalError,
        'Codex did not log in: ${outcome['error'] ?? 'no reason given'}',
      );
    }
    await _readAccount();
    return const {};
  }

  Future<JsonMap> _logout() async {
    await _call('account/logout', null);
    _account = null;
    return const {};
  }

  /// An account a person logged in to elsewhere since `initialize` counts.
  Future<void> _requireLogin() async {
    if (_account != null || !_requiresLogin) return;
    await _readAccount();
    if (_account != null || !_requiresLogin) return;
    throw const AcpAuthenticationRequired(
      'Codex is not logged in. Log in with ChatGPT first.',
    );
  }

  Future<JsonMap> _newSession(JsonMap params) async {
    await _requireLogin();
    final started = _map(
      await _call(
        'thread/start',
        _dropNulls({
          'cwd': params['cwd'],
          'config': _mcpConfig(params['mcpServers']),
        }),
      ),
    );
    await _adopt(started);
    return {
      'sessionId': _threadId,
      'modes': codexModeState(_mode),
      'configOptions': _configOptions(),
      '_meta': _threadMeta(started),
    };
  }

  Future<JsonMap> _loadSession(JsonMap params) async {
    await _requireLogin();
    final JsonMap resumed;
    try {
      resumed = _map(
        await _codex.call(
          'thread/resume',
          _dropNulls({
            'threadId': params['sessionId'],
            'cwd': params['cwd'],
            'config': _mcpConfig(params['mcpServers']),
          }),
        ),
      );
    } on AcpRpcError catch (error) {
      if (RegExp(
        'no rollout|not found|does not exist',
        caseSensitive: false,
      ).hasMatch(error.message)) {
        throw AcpRpcError(
          JsonRpcErrorCodes.resourceNotFound,
          'Codex holds no thread ${params['sessionId']}: ${error.message}',
        );
      }
      throw _refused('thread/resume', error);
    }
    await _adopt(resumed);
    for (final turn in _list(_map(resumed['thread'])['turns'])) {
      for (final item in _list(turn['items'])) {
        _replay(item);
      }
    }
    return {
      'modes': codexModeState(_mode),
      'configOptions': _configOptions(),
      '_meta': _threadMeta(resumed),
    };
  }

  Future<void> _adopt(JsonMap opened) async {
    final thread = _map(opened['thread']);
    _threadId = thread['id'] as String?;
    _cwd = '${opened['cwd'] ?? thread['cwd'] ?? ''}';
    _sandbox = opened['sandbox'] is Map ? _map(opened['sandbox']) : null;
    _mode = codexModeOf(opened['approvalPolicy'], _sandbox);
    _model = opened['model'] as String? ?? thread['model'] as String?;
    _effort =
        opened['reasoningEffort'] as String? ??
        thread['reasoningEffort'] as String?;
    _models = await _listModels();
    if (thread['name'] case final String name when name.isNotEmpty) {
      _update({'sessionUpdate': 'session_info_update', 'title': name});
    }
  }

  JsonMap _threadMeta(JsonMap opened) {
    final thread = _map(opened['thread']);
    return {
      'codex': _dropNulls({
        'threadPath': thread['path'],
        'modelProvider': opened['modelProvider'],
        'approvalPolicy': opened['approvalPolicy'],
        'sandbox': opened['sandbox'],
        'cliVersion': thread['cliVersion'],
      }),
    };
  }

  Future<List<JsonMap>> _listModels() async {
    final models = <JsonMap>[];
    String? cursor;
    try {
      for (var page = 0; page < 10; page++) {
        final listed = _map(
          await _codex.call('model/list', _dropNulls({'cursor': cursor})),
        );
        models.addAll(_list(listed['data']));
        cursor = listed['nextCursor'] as String?;
        if (cursor == null) break;
      }
    } on AcpRpcError {
      // A model list is a nicety: the thread's own model is still offered.
    }
    return models;
  }

  List<JsonMap> _configOptions() =>
      codexConfigOptions(_models, _model, _effort);

  /// ACP's MCP servers as Codex config overrides, keyed by dotted path.
  static JsonMap? _mcpConfig(Object? servers) {
    final config = <String, Object?>{};
    for (final server in _list(servers)) {
      final name = server['name'];
      if (name is! String || name.isEmpty) continue;
      final key = 'mcp_servers.$name';
      if (server['url'] case final String url) {
        config['$key.url'] = url;
        final headers = {
          for (final h in _list(server['headers']))
            if (h['name'] case final String n) n: '${h['value'] ?? ''}',
        };
        if (headers.isNotEmpty) config['$key.http_headers'] = headers;
      } else if (server['command'] case final String command) {
        config['$key.command'] = command;
        config['$key.args'] = server['args'] ?? const <String>[];
        final env = {
          for (final e in _list(server['env']))
            if (e['name'] case final String n) n: '${e['value'] ?? ''}',
        };
        if (env.isNotEmpty) config['$key.env'] = env;
      }
    }
    return config.isEmpty ? null : config;
  }

  Future<JsonMap> _setMode(JsonMap params) async {
    final mode = codexModeById('${params['modeId']}');
    if (mode == null) {
      throw AcpRpcError(
        JsonRpcErrorCodes.invalidParams,
        'Codex has no mode "${params['modeId']}"',
      );
    }
    _mode = mode;
    _modeChosen = true;
    return const {};
  }

  Future<JsonMap> _setConfigOption(JsonMap params) async {
    final value = params['value'];
    switch (params['configId']) {
      case kCodexModelOption when value is String:
        _model = value;
        _effort = codexEffortFor(_models, value, _effort);
        _modelChosen = true;
      case kCodexEffortOption when value is String:
        _effort = value;
        _modelChosen = true;
      default:
        throw AcpRpcError(
          JsonRpcErrorCodes.invalidParams,
          'Codex has no option "${params['configId']}" taking "$value"',
        );
    }
    return {'configOptions': _configOptions()};
  }

  // The turn.

  Future<JsonMap> _prompt(JsonMap params) async {
    final thread = _threadId;
    if (thread == null) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.invalidRequest,
        'Codex has no session open',
      );
    }
    if (_turn != null) {
      throw const AcpRpcError(
        JsonRpcErrorCodes.invalidRequest,
        'Codex is still working on the last turn',
      );
    }
    final done = _turn = Completer<JsonMap>();
    _turnId = null;
    _interruptWanted = false;
    _turnDiff = null;
    try {
      final started = _map(
        await _call(
          'turn/start',
          _dropNulls({
            'threadId': thread,
            'input': codexInput(_list(params['prompt'])),
            if (_modeChosen) ...{
              'approvalPolicy': _mode.approvalPolicy,
              'sandboxPolicy': codexSandboxPolicy(_mode, _sandbox),
            },
            if (_modelChosen) ...{'model': _model, 'effort': _effort},
          }),
        ),
      );
      _turnId ??= _map(started['turn'])['id'] as String?;
      if (_interruptWanted) _interrupt();
      return await done.future;
    } finally {
      if (identical(_turn, done)) _turn = null;
      _flushOutput();
    }
  }

  void _interrupt() {
    if (_turn == null) return;
    final turn = _turnId;
    if (turn == null) {
      _interruptWanted = true;
      return;
    }
    unawaited(
      _codex
          .call('turn/interrupt', {'threadId': _threadId, 'turnId': turn})
          .then((_) {}, onError: (Object _) {}),
    );
  }

  void _turnCompleted(JsonMap params) {
    final done = _turn;
    final turn = _map(params['turn']);
    if (done == null || done.isCompleted) return;
    if (_turnId != null && turn['id'] != _turnId) return;
    _flushOutput();
    // Codex completes no item it interrupted: a call still open ended with
    // the turn.
    for (final id in List.of(_tools.keys)) {
      _toolUpdate({
        'toolCallId': id,
        'status': 'failed',
        '_meta': {
          'codex': {'endedWithTurn': turn['status']},
        },
      });
    }
    _tools.clear();
    final meta = {
      'codex': _dropNulls({
        'turnId': turn['id'],
        'durationMs': turn['durationMs'],
        'diff': _turnDiff,
      }),
    };
    final error = _map(turn['error']);
    switch (turn['status']) {
      case 'interrupted':
        done.complete({'stopReason': 'cancelled', '_meta': meta});
      case 'failed':
        final info = error['codexErrorInfo'];
        final words = '${error['message'] ?? 'the turn failed'}';
        if (info == 'contextWindowExceeded') {
          done.complete({'stopReason': 'max_tokens', '_meta': meta});
        } else if (info == 'cyberPolicy' ||
            info == 'misalignmentPolicyViolation') {
          done.complete({'stopReason': 'refusal', '_meta': meta});
        } else if (info == 'usageLimitExceeded' ||
            info == 'rateLimitExceeded') {
          done.completeError(
            AcpRpcError(
              JsonRpcErrorCodes.internalError,
              'Codex usage limit reached: $words',
              data: _dropNulls({
                'codexErrorInfo': info,
                'resetsAt': _limitResetsAt(),
              }),
            ),
          );
        } else {
          done.completeError(
            AcpRpcError(
              JsonRpcErrorCodes.internalError,
              'Codex failed the turn: $words',
              data: _dropNulls({
                'codexErrorInfo': info,
                'additionalDetails': error['additionalDetails'],
              }),
            ),
          );
        }
      default:
        done.complete({'stopReason': 'end_turn', '_meta': meta});
    }
  }

  /// When the spent window resets, in epoch seconds: the one at or over 100%.
  int? _limitResetsAt() {
    final limits = _rateLimits;
    if (limits == null) return null;
    int? soonest;
    for (final key in const ['primary', 'secondary']) {
      final window = _map(limits[key]);
      final used = window['usedPercent'];
      final at = window['resetsAt'];
      if (used is num && used >= 100 && at is int) {
        if (soonest == null || at < soonest) soonest = at;
      }
    }
    return soonest;
  }

  // Codex's side.

  void _onCodexNotification(AcpNotification notification) {
    final params = notification.paramsMap;
    final thread = params['threadId'];
    if (thread is String && _threadId != null && thread != _threadId) return;
    switch (notification.method) {
      case 'item/agentMessage/delta' || 'item/plan/delta':
        _streamed.add('${params['itemId']}');
        _message(params['delta'], '${params['itemId']}');
      case 'item/reasoning/summaryTextDelta' || 'item/reasoning/textDelta':
        _streamed.add('${params['itemId']}');
        _thought(params['delta']);
      case 'item/reasoning/summaryPartAdded':
        if (params['summaryIndex'] case final int index when index > 0) {
          _thought('\n\n');
        }
      case 'item/started':
        _itemStarted(_map(params['item']));
      case 'item/completed':
        _itemCompleted(_map(params['item']));
      case 'item/commandExecution/outputDelta':
        final id = '${params['itemId']}';
        (_output[id] ??= StringBuffer()).write(params['delta'] ?? '');
        _outputDue.add(id);
        _outputTimer ??= Timer(outputEvery, _flushOutput);
      case 'item/fileChange/patchUpdated':
        final id = '${params['itemId']}';
        final known = _tools[id];
        if (known != null) {
          _toolUpdate(
            codexToolCall({
                  ...known,
                  'type': 'fileChange',
                  'id': id,
                  'changes': params['changes'],
                }, cwd: _cwd) ??
                const {},
          );
        }
      case 'turn/plan/updated':
        _update({
          'sessionUpdate': 'plan',
          'entries': codexPlanEntries(params['plan']),
          '_meta': {
            'codex': {'explanation': params['explanation']},
          },
        });
      case 'turn/diff/updated':
        _turnDiff = params['diff'] as String?;
      case 'thread/tokenUsage/updated':
        _usage = _map(params['tokenUsage']);
        _sendUsage();
      case 'account/rateLimits/updated':
        _rateLimits = _map(params['rateLimits']);
        if (_usage != null) _sendUsage();
      case 'thread/name/updated':
        if (params['threadName'] case final String name) {
          _update({'sessionUpdate': 'session_info_update', 'title': name});
        }
      case 'model/rerouted':
        _model = params['toModel'] as String? ?? _model;
        _update({
          'sessionUpdate': 'config_option_update',
          'configOptions': _configOptions(),
          '_meta': {
            'codex': {
              'reroutedFrom': params['fromModel'],
              'reason': params['reason'],
            },
          },
        });
      case 'turn/completed':
        _turnCompleted(params);
      case 'account/login/completed':
        final login = _login;
        if (login != null &&
            !login.isCompleted &&
            (params['loginId'] == null || params['loginId'] == _loginId)) {
          login.complete(params);
        }
      case 'account/updated':
        if (params['authMode'] == null) _account = null;
      case 'error' when params['willRetry'] != true:
        _say('Codex: ${_map(params['error'])['message']}');
      case 'warning' || 'configWarning' || 'deprecationNotice':
        final words = params['message'] ?? params['summary'];
        if (words != null) _say('Codex: $words');
    }
  }

  void _itemStarted(JsonMap item) {
    final call = codexToolCall(item, cwd: _cwd);
    if (call == null) return;
    _tools['${item['id']}'] = item;
    _update({'sessionUpdate': 'tool_call', ...call});
  }

  void _itemCompleted(JsonMap item) {
    final id = '${item['id']}';
    switch (item['type']) {
      case 'agentMessage' || 'plan':
        if (!_streamed.remove(id)) _message(item['text'], id);
        return;
      case 'reasoning':
        if (!_streamed.remove(id)) {
          _thought(_strings(item['summary']).join('\n\n'));
        }
        return;
    }
    final call = codexToolCall(item, cwd: _cwd);
    if (call == null) return;
    _outputDue.remove(id);
    _output.remove(id);
    final known = _tools.remove(id) != null;
    _update({
      'sessionUpdate': known ? 'tool_call_update' : 'tool_call',
      ...call,
    });
  }

  /// A finished conversation's item, as `session/load` replays it.
  void _replay(JsonMap item) {
    switch (item['type']) {
      case 'userMessage':
        final text = [
          for (final input in _list(item['content']))
            if (input['text'] case final String text) text,
        ].join('\n');
        if (text.isNotEmpty) {
          _update({
            'sessionUpdate': 'user_message_chunk',
            'content': {'type': 'text', 'text': text},
          });
        }
      case 'agentMessage' || 'plan' || 'reasoning':
        _itemCompleted(item);
      default:
        final call = codexToolCall(item, cwd: _cwd);
        if (call != null) _update({'sessionUpdate': 'tool_call', ...call});
    }
  }

  void _message(Object? text, String itemId) {
    if (text is! String || text.isEmpty) return;
    _update({
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': text},
      'messageId': itemId,
    });
  }

  /// Without a message id, so the reply that follows joins the same row.
  void _thought(Object? text) {
    if (text is! String || text.isEmpty) return;
    _update({
      'sessionUpdate': 'agent_thought_chunk',
      'content': {'type': 'text', 'text': text},
    });
  }

  void _toolUpdate(JsonMap call) {
    if (call.isEmpty) return;
    _update({'sessionUpdate': 'tool_call_update', ...call});
  }

  void _flushOutput() {
    _outputTimer?.cancel();
    _outputTimer = null;
    for (final id in List.of(_outputDue)) {
      final text = _output[id]?.toString() ?? '';
      _update({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': id,
        'content': [codexTextContent(_tail(text))],
      });
    }
    _outputDue.clear();
  }

  static String _tail(String text, [int most = 64 * 1024]) =>
      text.length <= most ? text : text.substring(text.length - most);

  void _sendUsage() {
    final usage = _usage;
    if (usage == null) return;
    final last = _map(usage['last']);
    _update({
      'sessionUpdate': 'usage_update',
      'used': last['totalTokens'] is int ? last['totalTokens'] : 0,
      'size': usage['modelContextWindow'] is int
          ? usage['modelContextWindow']
          : 0,
      '_meta': {
        'codex': _dropNulls({'tokenUsage': usage, 'rateLimits': _rateLimits}),
      },
    });
  }

  void _update(JsonMap update) {
    final session = _threadId;
    _client.notify(AcpMethods.sessionUpdate, {
      'sessionId': session ?? '',
      'update': update,
    });
  }

  Future<void> _onCodexRequest(AcpIncomingRequest request) async {
    final params = request.paramsMap;
    try {
      switch (request.method) {
        case 'item/commandExecution/requestApproval':
          final chosen = await _ask(_commandAsk(params), _decisions);
          request.respond({'decision': chosen ?? 'cancel'});
        case 'item/fileChange/requestApproval':
          final chosen = await _ask(_fileAsk(params), _decisions);
          request.respond({'decision': chosen ?? 'cancel'});
        case 'item/permissions/requestApproval':
          final chosen = await _ask(_permissionsAsk(params), _grants);
          final granted = chosen == 'turn' || chosen == 'session';
          request.respond({
            'permissions': granted
                ? _dropNulls({
                    'network': _map(params['permissions'])['network'],
                    'fileSystem': _map(params['permissions'])['fileSystem'],
                  })
                : const <String, Object?>{},
            'scope': chosen == 'session' ? 'session' : 'turn',
          });
        case 'mcpServer/elicitation/request':
          _notice(
            'The MCP server "${params['serverName']}" asked: '
            '${params['message'] ?? '(no message)'} - declined, since '
            "Karmashala's chat cannot fill in its form.",
          );
          request.respond({
            'action': 'decline',
            'content': null,
            '_meta': null,
          });
        case 'item/tool/requestUserInput':
          request.respond({'answers': await _questions(params)});
        case 'execCommandApproval' || 'applyPatchApproval':
          request.respond({'decision': 'denied'});
        default:
          request.fail(
            JsonRpcErrorCodes.methodNotFound,
            'Karmashala does not answer ${request.method}',
          );
      }
    } on Object catch (error) {
      request.fail(JsonRpcErrorCodes.internalError, '$error');
    }
  }

  static const _decisions = [
    ('accept', 'Allow', 'allow_once'),
    ('acceptForSession', 'Allow for this session', 'allow_always'),
    ('decline', 'Reject', 'reject_once'),
  ];

  static const _grants = [
    ('turn', 'Allow for this turn', 'allow_once'),
    ('session', 'Allow for this session', 'allow_always'),
    ('decline', 'Reject', 'reject_once'),
  ];

  /// Codex's questions, each with choices asked as a permission request
  /// whose options are the choices; a free-text or secret one is declined,
  /// and said in the chat. Choices are `allow_always` because a client that
  /// answers for the person (autoRun) picks an `allow_once` unseen.
  Future<JsonMap> _questions(JsonMap params) async {
    final answers = <String, Object?>{};
    for (final q in _list(params['questions'])) {
      final id = '${q['id']}';
      final text = '${q['question'] ?? q['header'] ?? ''}';
      final choices = [
        for (final o in _list(q['options']))
          if (o['label'] case final String label) label,
      ];
      if (choices.isEmpty || q['isSecret'] == true) {
        _notice(
          'Codex asked: $text - declined, since Karmashala\'s chat cannot '
          'answer a question without choices yet.',
        );
        continue;
      }
      final chosen = await _ask(
        {
          'toolCallId': '${params['itemId']}:$id',
          'title': text,
          'kind': 'other',
          'status': 'pending',
          'rawInput': {
            'header': q['header'],
            'question': text,
            'options': q['options'],
          },
          '_meta': {
            'codex': {'question': id},
          },
        },
        [
          for (final (i, label) in choices.indexed)
            ('choice-$i', label, 'allow_always'),
          ('skip', 'Skip the question', 'reject_once'),
        ],
      );
      final index = chosen != null && chosen.startsWith('choice-')
          ? int.tryParse(chosen.substring('choice-'.length))
          : null;
      if (index == null || index >= choices.length) {
        _notice('Codex asked: $text - no choice was made, so none was sent.');
        continue;
      }
      answers[id] = {
        'answers': [choices[index]],
      };
    }
    return answers;
  }

  var _notices = 0;

  /// Said in the chat as a message of its own, not mixed into Codex's.
  void _notice(String text) {
    _say(text);
    _update({
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': text},
      'messageId': 'karmashala-notice-${++_notices}',
    });
  }

  /// The option the person chose, by id, or null when the turn was cancelled
  /// or the client could not be asked.
  Future<String?> _ask(
    JsonMap toolCall,
    List<(String, String, String)> options,
  ) async {
    try {
      final answer = _map(
        await _client.call(AcpMethods.sessionRequestPermission, {
          'sessionId': _threadId ?? '',
          'toolCall': toolCall,
          'options': [
            for (final (id, name, kind) in options)
              {'optionId': id, 'name': name, 'kind': kind},
          ],
        }),
      );
      final outcome = _map(answer['outcome']);
      return outcome['outcome'] == 'selected'
          ? outcome['optionId'] as String?
          : null;
    } on Object {
      return null;
    }
  }

  JsonMap _commandAsk(JsonMap params) {
    final id = '${params['itemId']}';
    final known = _tools[id];
    final call = codexToolCall({
      'type': 'commandExecution',
      'id': id,
      'command': params['command'] ?? known?['command'] ?? '',
      'cwd': params['cwd'] ?? known?['cwd'],
      'commandActions': params['commandActions'] ?? known?['commandActions'],
      'status': 'inProgress',
    }, cwd: _cwd)!;
    return {
      ...call,
      'status': 'pending',
      'rawInput': {
        ...?(call['rawInput'] as Map<String, Object?>?),
        if (params['reason'] != null) 'reason': params['reason'],
      },
      '_meta': {
        'codex': _dropNulls({
          'approvalKind': params['kind'],
          'networkApprovalContext': params['networkApprovalContext'],
          'proposedExecpolicyAmendment': params['proposedExecpolicyAmendment'],
        }),
      },
    };
  }

  JsonMap _fileAsk(JsonMap params) {
    final id = '${params['itemId']}';
    final known = _tools[id] ?? {'type': 'fileChange', 'id': id};
    final call = codexToolCall({...known, 'status': 'inProgress'}, cwd: _cwd)!;
    return {
      ...call,
      'status': 'pending',
      '_meta': {
        'codex': _dropNulls({
          'reason': params['reason'],
          'grantRoot': params['grantRoot'],
        }),
      },
    };
  }

  JsonMap _permissionsAsk(JsonMap params) => {
    'toolCallId': '${params['itemId']}',
    'title':
        'Codex asks for more access'
        '${params['reason'] is String ? ': ${params['reason']}' : ''}',
    'kind': 'other',
    'status': 'pending',
    'rawInput': {'permissions': params['permissions'], 'cwd': params['cwd']},
  };

  // Ends.

  void _codexGone() {
    _outputTimer?.cancel();
    final login = _login;
    if (login != null && !login.isCompleted) {
      login.complete({'success': false, 'error': 'Codex exited'});
    }
    final turn = _turn;
    if (turn != null && !turn.isCompleted) {
      turn.completeError(const AcpPeerClosed('turn/start'));
    }
    // The client's own peer fails its open prompt when its stream ends, as
    // it would for an ACP agent that died.
    unawaited(_client.close());
    unawaited(_errors.close());
  }

  void _say(String line) {
    if (!_errors.isClosed) _errors.add(line);
  }

  Future<Object?> _call(String method, Object? params) async {
    try {
      return await _codex.call(method, params);
    } on AcpRpcError catch (error) {
      throw _refused(method, error);
    }
  }

  /// Codex's own error codes mean nothing to ACP's client, which would read
  /// its -32000 as a login demand.
  static AcpRpcError _refused(String method, AcpRpcError error) => AcpRpcError(
    JsonRpcErrorCodes.internalError,
    'Codex refused $method: ${error.message}',
    data: {'codexCode': error.code, if (error.data != null) 'data': error.data},
  );
}

JsonMap _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

List<JsonMap> _list(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map) item.cast<String, Object?>(),
];

List<String> _strings(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is String) item,
];

JsonMap _dropNulls(JsonMap json) => {
  for (final entry in json.entries)
    if (entry.value != null) entry.key: entry.value,
};
