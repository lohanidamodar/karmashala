import 'dart:async';

import 'package:karmashala_acp/karmashala_acp.dart';

import '../acp_extensions.dart';
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
    this.asyncAfter = const Duration(milliseconds: 250),
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

  /// One app-server process serves every thread, so nothing above the bridge
  /// starts Codex again.
  @override
  AcpRelaunch? get relaunch => null;

  /// How long `authenticate` waits on a browser login a person completes.
  final Duration loginPatience;

  /// How often a running command's output is sent on.
  final Duration outputEvery;

  /// How long after a turn's end Codex's async questions are asked, so the
  /// client has settled the prompt first.
  final Duration asyncAfter;

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
  CodexMode _mode = codexModeById('workspace-write')!;
  JsonMap? _sandbox;
  Object? _reviewer;
  var _modeChosen = false;
  String? _model;
  String? _effort;
  var _modelChosen = false;
  List<JsonMap> _models = const [];

  /// Codex's Plan preset from `collaborationMode/list`, or null where it
  /// lists none (or the list was refused), and Plan is then not offered.
  JsonMap? _planPreset;
  var _presetsRead = false;

  Completer<JsonMap>? _turn;
  String? _turnId;
  var _interruptWanted = false;
  var _cancelAsked = false;
  String? _turnDiff;

  /// The proposed plan a plan turn's `plan` item carried.
  String? _turnPlan;
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
    if (notification.method == AcpMethods.sessionCancel) {
      if (_turn != null) _cancelAsked = true;
      _interrupt();
    }
  }

  /// Opted in to Codex's experimental API, which 0.160.0's schema gates the
  /// options its own TUI offers behind: `collaborationMode/list` and a turn's
  /// `collaborationMode` (Plan), and an approval's `availableDecisions`. It
  /// also lets Codex ask `currentTime/read`, answered from this machine's
  /// clock. Every stable shape stays as it was; experimental ones add fields.
  Future<JsonMap> _initialize(JsonMap params) async {
    final info = _map(params['clientInfo']);
    final init = _map(
      await _call('initialize', {
        'clientInfo': {
          'name': info['name'] ?? 'Karmashala',
          'title': info['title'],
          'version': info['version'] ?? '0',
        },
        'capabilities': {'experimentalApi': true, 'requestAttestation': false},
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
      'modes': codexModeState(_mode, planOffered: _planPreset != null),
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
      'modes': codexModeState(_mode, planOffered: _planPreset != null),
      'configOptions': _configOptions(),
      '_meta': _threadMeta(resumed),
    };
  }

  Future<void> _adopt(JsonMap opened) async {
    final thread = _map(opened['thread']);
    _threadId = thread['id'] as String?;
    _cwd = '${opened['cwd'] ?? thread['cwd'] ?? ''}';
    _sandbox = opened['sandbox'] is Map ? _map(opened['sandbox']) : null;
    _reviewer = opened['approvalsReviewer'];
    _mode = codexModeOf(
      opened['approvalPolicy'],
      _sandbox,
      approvalsReviewer: _reviewer,
    );
    _model = opened['model'] as String? ?? thread['model'] as String?;
    _effort =
        opened['reasoningEffort'] as String? ??
        thread['reasoningEffort'] as String?;
    _models = await _listModels();
    await _readPresets();
    await _readSkills();
    if (thread['name'] case final String name when name.isNotEmpty) {
      _update({'sessionUpdate': 'session_info_update', 'title': name});
    }
  }

  /// Codex's collaboration presets, read once: 0.160.0 lists Plan (`mode:
  /// plan`, its own reasoning effort) and Default. A Codex that lists no
  /// plan, or refuses the experimental call, is offered no Plan.
  Future<void> _readPresets() async {
    if (_presetsRead) return;
    _presetsRead = true;
    try {
      final listed = _map(await _codex.call('collaborationMode/list', {}));
      _planPreset = _list(
        listed['data'],
      ).where((m) => m['mode'] == 'plan').firstOrNull;
    } on AcpRpcError {
      _planPreset = null;
    }
  }

  /// The `collaborationMode` a turn takes for [mode]: Plan with its preset's
  /// effort unless the person chose one, Default with the thread's own. Null
  /// where Codex offers no Plan, so nothing it lacks is sent.
  JsonMap? _collaborationFor(CodexMode mode) {
    final preset = _planPreset;
    final model = _model;
    if (preset == null || model == null) return null;
    final plan = mode.collaboration == 'plan';
    return {
      'mode': mode.collaboration,
      'settings': {
        'model': model,
        'reasoning_effort': plan && !_modelChosen
            ? preset['reasoning_effort'] ?? _effort
            : _effort,
        // Null is "the built-in instructions for the selected mode".
        'developer_instructions': null,
      },
    };
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

  /// The thread's settings changed — by a turn, or by another client of the
  /// thread — so the mode and model shown follow them. A model the list
  /// does not hold has the list read again.
  Future<void> _settingsUpdated(JsonMap settings) async {
    if (settings.isEmpty) return;
    if (settings['sandboxPolicy'] case final Map<Object?, Object?> sandbox) {
      _sandbox = _map(sandbox);
    }
    if (settings.containsKey('approvalsReviewer')) {
      _reviewer = settings['approvalsReviewer'];
    }
    final mode = codexModeOf(
      settings['approvalPolicy'],
      _sandbox,
      approvalsReviewer: _reviewer,
      collaboration: _planPreset == null
          ? null
          : _map(settings['collaborationMode'])['mode'],
    );
    if (mode.id != _mode.id) {
      _mode = mode;
      _update({
        'sessionUpdate': 'current_mode_update',
        'currentModeId': mode.id,
      });
    }
    final model = settings['model'] as String? ?? _model;
    final effort = settings.containsKey('effort')
        ? settings['effort'] as String?
        : _effort;
    final unlisted =
        model != null && !_models.any((listed) => listed['model'] == model);
    if (model == _model && effort == _effort && !unlisted) return;
    _model = model;
    _effort = effort;
    if (unlisted) _models = await _listModels();
    _update({
      'sessionUpdate': 'config_option_update',
      'configOptions': _configOptions(),
    });
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
    final id = '${params['modeId']}';
    final mode = id == kCodexPlanMode && _planPreset == null
        ? null
        : codexModeById(id);
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
    // A message sent past Codex's async questions is the reply to them.
    if (_asyncOpen case final open?) {
      _asyncOpen = null;
      _update({
        'sessionUpdate': AcpExtensions.askWithdrawn,
        'toolCallId': open,
      });
    }
    final done = _turn = Completer<JsonMap>();
    _cancelAsked = false;
    final prompt = _list(params['prompt']);
    try {
      switch (_commandIn(prompt)) {
        case ('compact', _):
          _newTurn();
          await _call('thread/compact/start', {'threadId': thread});
        case ('review', final String rest):
          _newTurn();
          final started = _map(
            await _call('review/start', {
              'threadId': thread,
              'target': rest.isEmpty
                  ? {'type': 'uncommittedChanges'}
                  : {'type': 'custom', 'instructions': rest},
            }),
          );
          _turnId ??= _map(started['turn'])['id'] as String?;
          if (_interruptWanted) _interrupt();
        case (final String name, final String rest)
            when _skills.any((s) => s.name == name):
          final skill = _skills.firstWhere((s) => s.name == name);
          await _startTurn(thread, [
            {'type': 'skill', 'name': skill.name, 'path': skill.path},
            ...codexInput([
              {
                'type': 'text',
                'text': '\$$name${rest.isEmpty ? '' : ' $rest'}',
              },
              ...prompt.skip(1),
            ]),
          ]);
        default:
          await _startTurn(thread, codexInput(prompt));
      }
      return await done.future;
    } finally {
      if (identical(_turn, done)) _turn = null;
      _flushOutput();
    }
  }

  /// The command a prompt opens with, `/name rest`, and the rest: only a
  /// prompt whose first block is text starting with the slash.
  static (String, String)? _commandIn(List<JsonMap> prompt) {
    final first = prompt.firstOrNull;
    if (first == null || first['type'] != 'text') return null;
    final match = RegExp(
      r'^/(\S+)(?:\s+([\s\S]*))?$',
    ).firstMatch('${first['text'] ?? ''}'.trim());
    if (match == null) return null;
    return (match[1]!, (match[2] ?? '').trim());
  }

  void _newTurn() {
    _turnId = null;
    _interruptWanted = false;
    _turnDiff = null;
    _turnPlan = null;
  }

  /// Codex's skills for the thread's folder, announced with its own
  /// commands as the chat's slash commands; read again on `skills/changed`.
  Future<void> _readSkills() async {
    try {
      final listed = await _codex.call('skills/list', {
        'cwds': [if (_cwd.isNotEmpty) _cwd],
      });
      _skills = codexSkills(listed);
    } on AcpRpcError {
      _skills = const [];
    }
    _update({
      'sessionUpdate': 'available_commands_update',
      'availableCommands': codexAvailableCommands(_skills),
    });
  }

  List<CodexSkill> _skills = const [];

  /// One Codex turn on [thread], with what the person chose since.
  Future<void> _startTurn(String thread, List<JsonMap> input) async {
    _newTurn();
    final started = _map(
      await _call(
        'turn/start',
        _dropNulls({
          'threadId': thread,
          'input': input,
          // The reviewer and collaboration mode always ride with the mode,
          // so leaving Auto or Plan takes; each sticks for later turns.
          if (_modeChosen) ...{
            'approvalPolicy': _mode.approvalPolicy,
            'sandboxPolicy': codexSandboxPolicy(_mode, _sandbox),
            'approvalsReviewer': _mode.approvalsReviewer,
            'collaborationMode': _collaborationFor(_mode),
          },
          if (_modelChosen) ...{'model': _model, 'effort': _effort},
        }),
      ),
    );
    _turnId ??= _map(started['turn'])['id'] as String?;
    if (_interruptWanted) _interrupt();
  }

  /// What Codex's own TUI asks when a Plan turn ends with a plan ("Implement
  /// this plan?", 0.160.0): the app-server leaves it to its client. Asked as
  /// a plan prompt whose yeses are the modes it can be carried out in, so the
  /// session's rung picks one; a yes switches to it and sends what the TUI
  /// sends, "Implement the plan.", as the next turn of the same prompt. No,
  /// or a cancel, ends the prompt still in Plan.
  Future<void> _offerImplement(
    Completer<JsonMap> done,
    String plan,
    JsonMap ended,
  ) async {
    final chosen = await _ask(
      {
        'toolCallId': 'codex-plan-${_turnId ?? ''}',
        'title': 'Implement this plan?',
        'kind': 'switch_mode',
        'status': 'pending',
        'rawInput': {'plan': plan},
      },
      [
        for (final mode in codexImplementModes)
          (mode.id, 'Yes, implement this plan (${mode.name})', 'allow_once'),
        ('plan', 'No, stay in Plan mode', 'reject_once'),
      ],
    );
    final mode = chosen == null ? null : codexModeById(chosen);
    final thread = _threadId;
    if (done.isCompleted) return;
    if (_cancelAsked || mode == null || mode.id == kCodexPlanMode) {
      done.complete({...ended, if (_cancelAsked) 'stopReason': 'cancelled'});
      return;
    }
    _mode = mode;
    _modeChosen = true;
    _update({'sessionUpdate': 'current_mode_update', 'currentModeId': mode.id});
    if (thread == null) {
      done.complete(ended);
      return;
    }
    _note('Implementing the plan (${mode.name})');
    try {
      await _startTurn(
        thread,
        codexInput(const [
          {'type': 'text', 'text': 'Implement the plan.'},
        ]),
      );
    } on Object catch (error) {
      if (!done.isCompleted) done.completeError(error);
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
    final asyncAsked = _asyncWaiting;
    _asyncWaiting = null;
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
        _note('Interrupted by you');
        done.complete({'stopReason': 'cancelled', '_meta': meta});
      case 'failed':
        final info = error['codexErrorInfo'];
        final words = '${error['message'] ?? 'the turn failed'}';
        _note(words, error: true);
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
        final ended = {'stopReason': 'end_turn', '_meta': meta};
        final plan = _turnPlan;
        if (_mode.id == kCodexPlanMode && plan != null && !_cancelAsked) {
          unawaited(_offerImplement(done, plan, ended));
        } else {
          done.complete(ended);
          // Asked once the client has settled the prompt: settling closes
          // whatever ask is open, and this one belongs to no turn.
          if (asyncAsked != null) {
            Timer(asyncAfter, () => unawaited(_askAsync(asyncAsked)));
          }
        }
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
        final item = _map(params['item']);
        _itemCompleted(item);
        _keepAsyncQuestions(item);
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
      case 'thread/settings/updated':
        unawaited(_settingsUpdated(_map(params['threadSettings'])));
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
      case 'turn/started':
        // A compaction's turn is named only here.
        if (_turn != null && _turnId == null) {
          _turnId = _map(params['turn'])['id'] as String?;
          if (_interruptWanted) _interrupt();
        }
      case 'turn/completed':
        _turnCompleted(params);
      case 'skills/changed':
        unawaited(_readSkills());
      case 'serverRequest/resolved':
        _requestResolved(params['requestId']);
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
        // The plan whole, as its deltas need not add up to it (0.160.0's
        // PlanDeltaNotification says so).
        if (item['type'] == 'plan' && item['text'] is String) {
          _turnPlan = item['text'] as String;
        }
        return;
      case 'reasoning':
        if (!_streamed.remove(id)) {
          _thought(_strings(item['summary']).join('\n\n'));
        }
        return;
    }
    if (_noticeItem(item)) return;
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

  /// An agent message Codex delivers `async` with `questions` (0.160.0's
  /// AgentMessageDelivery, AsyncUserInputQuestion): asked once its turn is
  /// over, so it never stands in front of that turn's own asks.
  void _keepAsyncQuestions(JsonMap item) {
    if (item['type'] != 'agentMessage' || item['delivery'] != 'async') return;
    final questions = [
      for (final q in _list(item['questions']))
        if (q['title'] case final String title when title.trim().isNotEmpty) q,
    ];
    if (questions.isEmpty) return;
    final asked = ('${item['id']}', questions);
    if (_turn == null) {
      unawaited(_askAsync(asked));
    } else {
      _asyncWaiting = asked;
    }
  }

  (String, List<JsonMap>)? _asyncWaiting;

  /// The async questions' card while it is open, by tool call id.
  String? _asyncOpen;

  /// Codex's async questions as one card. Nothing in the protocol answers
  /// them — the item has no request id, and no client method takes one —
  /// so the answer goes back as Codex reads any reply: the next user
  /// message, sent as a turn of the bridge's own. Any words answer; a
  /// message the person sends instead closes the card.
  Future<void> _askAsync((String, List<JsonMap>) asked) async {
    final (itemId, questions) = asked;
    final toolCallId = 'codex-async-$itemId';
    _asyncOpen = toolCallId;
    String title(JsonMap q) => '${q['title']}'.trim();
    final outcome = await _outcome(
      {
        'toolCallId': toolCallId,
        'title': questions.length == 1
            ? title(questions.single)
            : 'Codex asks ${questions.length} questions',
        'kind': 'other',
        'status': 'pending',
        'rawInput': {'questions': questions},
        '_meta': {
          'codex': {'delivery': 'async', 'itemId': itemId},
          'karmashala': {
            'questions': [
              for (final q in questions)
                {
                  'question': title(q),
                  'ownWords': true,
                  'options': [
                    for (final option in _strings(q['options']))
                      {'label': option},
                  ],
                },
            ],
          },
        },
      },
      const [
        ('answer', 'Answer', 'allow_always'),
        ('skip', 'Not now', 'reject_once'),
      ],
    );
    if (_asyncOpen == toolCallId) _asyncOpen = null;
    final said = outcome?['optionId'] == 'answer'
        ? _map(_map(outcome?['_meta'])['karmashala'])['answers']
        : null;
    if (said is! Map) return;
    final replies = [
      for (final q in questions)
        if (said[title(q)] case final String words when words.trim().isNotEmpty)
          (title(q), words.trim()),
    ];
    if (replies.isEmpty) return;
    await _ownTurn(
      replies.length == 1 && questions.length == 1
          ? replies.single.$2
          : [for (final (q, a) in replies) '$q\n$a'].join('\n\n'),
    );
  }

  /// A turn no prompt asked for, carrying [text] as the person's message:
  /// the client sees it as the agent's own turn.
  Future<void> _ownTurn(String text) async {
    final thread = _threadId;
    if (thread == null || _turn != null) {
      _notice('Your answer was not sent: Codex is busy. Send it as a message.');
      return;
    }
    final done = _turn = Completer<JsonMap>();
    _cancelAsked = false;
    _update({'sessionUpdate': AcpExtensions.agentTurn, 'state': 'started'});
    _note('You answered: $text');
    try {
      await _startTurn(
        thread,
        codexInput([
          {'type': 'text', 'text': text},
        ]),
      );
      await done.future;
    } on Object catch (error) {
      _note('Codex did not take the answer: $error', error: true);
    } finally {
      if (identical(_turn, done)) _turn = null;
      _flushOutput();
      _update({'sessionUpdate': AcpExtensions.agentTurn, 'state': 'ended'});
    }
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
        if (_noticeItem(item)) return;
        final call = codexToolCall(item, cwd: _cwd);
        if (call != null) _update({'sessionUpdate': 'tool_call', ...call});
    }
  }

  /// Says an item that is a note rather than a call, and what a review it
  /// ends found; false for any other item.
  bool _noticeItem(JsonMap item) {
    final note = codexItemNotice(item);
    if (note == null) return false;
    _note(note);
    _message(codexReviewFindings(item), '${item['id']}');
    return true;
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

  /// A note for the chat, as a terminal session shows the same event.
  void _note(String text, {bool error = false}) => _update({
    'sessionUpdate': AcpExtensions.notice,
    'text': text,
    if (error) 'role': 'error',
  });

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
          request.respond({
            'decision': await _decide(
              _commandAsk(params),
              codexCommandDecisions(params['availableDecisions']),
              request.id,
            ),
          });
        case 'item/fileChange/requestApproval':
          request.respond({
            'decision': await _decide(
              _fileAsk(params),
              kCodexFileDecisions,
              request.id,
            ),
          });
        case 'item/permissions/requestApproval':
          final chosen = await _ask(
            _permissionsAsk(params),
            _grants,
            codexRequest: request.id,
          );
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
          request.respond(await _elicit(params, request.id));
        case 'item/tool/requestUserInput':
          request.respond({'answers': await _questions(params, request.id)});
        case 'execCommandApproval' || 'applyPatchApproval':
          request.respond({'decision': 'denied'});
        case 'currentTime/read':
          request.respond({
            'currentTimeAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          });
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

  /// Codex's decision for the option the person chose among [decisions];
  /// `cancel` when the turn was cancelled or the client could not be asked.
  Future<Object> _decide(
    JsonMap toolCall,
    List<CodexDecision> decisions,
    Object codexRequest,
  ) async {
    final chosen = await _ask(toolCall, [
      for (final d in decisions) (d.id, d.name, d.kind),
    ], codexRequest: codexRequest);
    return decisions.where((d) => d.id == chosen).firstOrNull?.decision ??
        'cancel';
  }

  /// An MCP server's elicitation, answered as MCP's `accept`, `decline` or
  /// `cancel`. One asking only consent is an Allow / Decline / Cancel ask;
  /// a form of text, choices, yes-or-no and numbers is a question card,
  /// one question a field, every field answered. Anything else — a link to
  /// open, a verification, a form with more in it — is cancelled, and the
  /// chat says why.
  Future<JsonMap> _elicit(JsonMap params, Object requestId) async {
    final server = '${params['serverName']}';
    final message = '${params['message'] ?? params['title'] ?? ''}'.trim();
    JsonMap answer(String action, [JsonMap? content]) => {
      'action': action,
      'content': content,
      '_meta': null,
    };
    JsonMap refuse(String why) {
      _notice(
        'The MCP server "$server" asked: ${message.isEmpty ? '(no message)' : message}'
        ' - cancelled, since $why.',
      );
      return answer('cancel');
    }

    final fields = switch (params['mode']) {
      'form' ||
      'openai/form' ||
      'openaiForm' => codexElicitationForm(params['requestedSchema']),
      _ => null,
    };
    if (fields == null) {
      return refuse(switch (params['mode']) {
        'url' => "Karmashala's chat does not open the link it sent",
        'openai/userVerification' => "Karmashala's chat cannot verify you",
        'form' || 'openai/form' || 'openaiForm' =>
          'its form asks for more than text, a choice, yes or no, or a '
              'number',
        _ => 'Karmashala does not know what it asks for',
      });
    }
    const options = [
      ('accept', 'Allow', 'allow_always'),
      ('decline', 'Decline', 'reject_once'),
      ('cancel', 'Cancel', 'reject_once'),
    ];
    final toolCall = <String, Object?>{
      'toolCallId': 'elicitation-$requestId',
      'title': 'The MCP server "$server" asks: $message',
      'kind': 'other',
      'status': 'pending',
      'rawInput': {
        'server': server,
        'message': message,
        'requestedSchema': params['requestedSchema'],
      },
    };
    if (fields.isEmpty) {
      final chosen = await _ask(toolCall, options, codexRequest: requestId);
      return chosen == 'accept'
          ? answer('accept', const {})
          : answer(chosen ?? 'cancel');
    }
    String asked(int i, CodexFormField f) => [
      if (i == 0 && message.isNotEmpty) '$message\n\n',
      f.title,
      if (f.description case final String d when d != f.title) ' — $d',
    ].join();
    final outcome = await _outcome(
      {
        ...toolCall,
        '_meta': {
          'karmashala': {
            'questions': [
              for (final (i, f) in fields.indexed)
                {
                  'question': asked(i, f),
                  'header': f.title,
                  'ownWords': f.choices.isEmpty && f.kind != 'boolean',
                  'options': [
                    if (f.kind == 'boolean') ...[
                      {'label': 'Yes'},
                      {'label': 'No'},
                    ],
                    for (final (_, label) in f.choices) {'label': label},
                  ],
                },
            ],
          },
        },
      },
      [('accept', 'Submit', 'allow_always'), ...options.skip(1)],
      codexRequest: requestId,
    );
    final chosen = outcome?['optionId'] as String?;
    if (chosen != 'accept') return answer(chosen ?? 'cancel');
    final said = _map(_map(outcome?['_meta'])['karmashala'])['answers'];
    final content = <String, Object?>{};
    for (final (i, f) in fields.indexed) {
      final words = said is Map ? said[asked(i, f)] : null;
      final value = words is String ? codexFormValue(f, words) : null;
      if (value == null) {
        return refuse(
          '"${f.title}" was not answered with ${switch (f.kind) {
            'number' || 'integer' => 'a number',
            'enum' || 'boolean' => 'one of its choices',
            _ => 'any words',
          }}',
        );
      }
      content[f.key] = value;
    }
    return answer('accept', content);
  }

  static const _grants = [
    ('turn', 'Allow for this turn', 'allow_once'),
    ('session', 'Allow for this session', 'allow_always'),
    ('decline', 'Reject', 'reject_once'),
  ];

  /// Codex's questions, asked as one permission request whose `_meta`
  /// carries them all under `karmashala.questions`, so a client that draws
  /// questions draws one card and answers them at once under
  /// `_meta.karmashala.answers`. A lone question with choices also has its
  /// choices as the request's options, for a client that draws none; they
  /// are `allow_always` because a client that answers for the person
  /// (autoRun) picks an `allow_once` unseen.
  ///
  /// Own words are taken where Codex said `isOther` — its TUI's "None of
  /// the above" — and go back as its CLI sends a free-form answer,
  /// `user_note: <words>`; and for a question with no options, which they
  /// answer outright, as its CLI's "Answer:" does. A secret question is
  /// still declined, said in the chat: nothing here hides what is typed.
  ///
  /// A request that `isBlocking: false` is one Codex goes on without: the
  /// chat says so, and when Codex resolves it itself (its TUI counts down
  /// "auto-resolves in"), `serverRequest/resolved` closes the card.
  Future<JsonMap> _questions(JsonMap params, Object requestId) async {
    final answers = <String, Object?>{};
    final asked = <JsonMap>[];
    for (final q in _list(params['questions'])) {
      if (q['isSecret'] == true) {
        _notice(
          'Codex asked: ${_questionText(q)} - declined, since Karmashala\'s '
          'chat cannot take a secret answer yet.',
        );
        continue;
      }
      asked.add(q);
    }
    if (asked.isEmpty) return answers;
    if (params['isBlocking'] == false) {
      _notice(
        'Codex asked without waiting for an answer, and carries on '
        'meanwhile: ${[for (final q in asked) _questionText(q)].join(' · ')}',
      );
    }
    final lone = asked.length == 1 ? _choices(asked.single) : const <String>[];
    final first = asked.first;
    final outcome = await _outcome(
      {
        'toolCallId': asked.length == 1
            ? '${params['itemId']}:${first['id']}'
            : '${params['itemId']}',
        'title': asked.length == 1
            ? _questionText(first)
            : 'Codex asks ${asked.length} questions',
        'kind': 'other',
        'status': 'pending',
        'rawInput': {
          'questions': [
            for (final q in asked)
              {
                'header': q['header'],
                'question': _questionText(q),
                'options': q['options'],
              },
          ],
        },
        '_meta': {
          'codex': {
            'questions': [for (final q in asked) '${q['id']}'],
            if (params['isBlocking'] == false) 'isBlocking': false,
          },
          'karmashala': {
            'questions': [
              for (final q in asked)
                {
                  'question': _questionText(q),
                  if (q['header'] case final String header) 'header': header,
                  'ownWords': q['isOther'] == true || _choices(q).isEmpty,
                  'options': [
                    for (final o in _list(q['options']))
                      if (o['label'] case final String label)
                        {
                          'label': label,
                          if (o['description'] case final String description)
                            'description': description,
                        },
                  ],
                },
            ],
          },
        },
      },
      [
        if (lone.isNotEmpty)
          for (final (i, label) in lone.indexed)
            ('choice-$i', label, 'allow_always')
        else
          ('answer', 'Answer', 'allow_always'),
        (
          'skip',
          asked.length == 1 ? 'Skip the question' : 'Skip the questions',
          'reject_once',
        ),
      ],
      codexRequest: requestId,
    );
    final chosen = outcome?['optionId'] as String?;
    final said = chosen == null || chosen == 'skip'
        ? null
        : _map(_map(outcome?['_meta'])['karmashala'])['answers'];
    for (final q in asked) {
      final id = '${q['id']}';
      final text = _questionText(q);
      final choices = _choices(q);
      final words = said is Map ? said[text] : null;
      if (words is String && words.trim().isNotEmpty) {
        final answer = words.trim();
        if (choices.contains(answer)) {
          answers[id] = {
            'answers': [answer],
          };
          continue;
        }
        if (choices.isEmpty) {
          answers[id] = {
            'answers': [answer],
          };
          continue;
        }
        if (q['isOther'] == true) {
          answers[id] = {
            'answers': ['user_note: $answer'],
          };
          continue;
        }
      }
      final index = words == null && chosen != null && lone.isNotEmpty
          ? int.tryParse(chosen.replaceFirst('choice-', ''))
          : null;
      if (index == null || index < 0 || index >= choices.length) {
        _notice('Codex asked: $text - no answer was given, so none was sent.');
        continue;
      }
      answers[id] = {
        'answers': [choices[index]],
      };
    }
    return answers;
  }

  static String _questionText(JsonMap q) =>
      '${q['question'] ?? q['header'] ?? ''}';

  static List<String> _choices(JsonMap q) => [
    for (final o in _list(q['options']))
      if (o['label'] case final String label) label,
  ];

  /// Codex's own requests now open in the client, by request id → the tool
  /// call they were asked as, so one Codex resolves itself can be withdrawn.
  final _openAsks = <String, String>{};

  void _requestResolved(Object? requestId) {
    final toolCallId = _openAsks.remove('$requestId');
    if (toolCallId == null) return;
    _update({
      'sessionUpdate': AcpExtensions.askWithdrawn,
      'toolCallId': toolCallId,
    });
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
    List<(String, String, String)> options, {
    Object? codexRequest,
  }) async =>
      (await _outcome(
            toolCall,
            options,
            codexRequest: codexRequest,
          ))?['optionId']
          as String?;

  /// The person's whole outcome, its `_meta` with it, or null when the turn
  /// was cancelled, the client could not be asked, or the ask was withdrawn.
  /// [codexRequest] is the Codex request it answers, so Codex resolving that
  /// itself withdraws it.
  Future<JsonMap?> _outcome(
    JsonMap toolCall,
    List<(String, String, String)> options, {
    Object? codexRequest,
  }) async {
    final key = codexRequest == null ? null : '$codexRequest';
    if (key != null) _openAsks[key] = '${toolCall['toolCallId']}';
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
      return outcome['outcome'] == 'selected' ? outcome : null;
    } on Object {
      return null;
    } finally {
      if (key != null) _openAsks.remove(key);
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
