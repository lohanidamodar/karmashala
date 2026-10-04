import 'dart:async';
import 'dart:convert';

import 'package:karmashala_host/src/acp/acp_transport.dart';

typedef Json = Map<String, Object?>;

/// What one fake turn does when a user message arrives.
typedef FakeClaudeTurn = Future<void> Function(FakeClaude claude, Json user);

/// Every `claude` process a bridge started, in-memory: the first over the
/// launcher's argv, each relaunch over that plus its extra arguments. A
/// `--resume` of a conversation it does not hold dies as the real binary
/// does; `--version` prints one and exits.
class FakeClaudeMachine {
  FakeClaudeMachine({
    List<FakeClaudeTurn> turns = const [],
    this.loggedIn = true,
    Set<String> conversations = const {},
    this.version = '2.1.287',
    this.models = defaultModels,
    this.ignoreInterrupt = false,
  }) : turns = List.of(turns),
       conversations = {...conversations};

  final List<FakeClaudeTurn> turns;
  final bool loggedIn;
  final Set<String> conversations;
  final String version;
  final List<Json> models;

  /// Whether an interrupt is answered but the turn goes on, as a stuck
  /// `claude` would.
  final bool ignoreInterrupt;

  /// Every process started, in order.
  final launched = <FakeClaude>[];

  static const defaultModels = <Json>[
    {
      'value': 'default',
      'resolvedModel': 'claude-opus-5-5',
      'displayName': 'Default (recommended)',
      'description': 'Opus 5.5',
    },
    {
      'value': 'sonnet',
      'resolvedModel': 'claude-sonnet-5-5',
      'displayName': 'Sonnet 5.5',
      'description': 'Most efficient',
    },
    {
      'value': 'haiku',
      'resolvedModel': 'claude-haiku-4-5-20251001',
      'displayName': 'Haiku 4.5',
      'description': 'Fastest',
    },
  ];

  /// The processes that hold a conversation (not `--version` reads).
  List<FakeClaude> get conversing => [
    for (final c in launched)
      if (!c.args.contains('--version')) c,
  ];

  /// The live conversation process: the last one started for a session.
  FakeClaude get current => conversing.last;

  Future<AcpTransport> spawn() async => _start(const []).transport;

  FakeClaude _start(List<String> args) {
    final claude = FakeClaude._(this, List.of(args));
    launched.add(claude);
    scheduleMicrotask(claude._boot);
    return claude;
  }
}

/// One fake `claude -p --input-format stream-json` process.
class FakeClaude {
  FakeClaude._(this.machine, this.args);

  final FakeClaudeMachine machine;

  /// The arguments added to the launcher's own, empty for the first.
  final List<String> args;

  final _stdin = StreamController<List<int>>();
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<String>();
  final _exit = Completer<int>();
  final _waiters = <(bool Function(Json), Completer<Json>)>[];
  final _controlAnswers = <String, Completer<Json>>{};

  /// Everything the bridge wrote, decoded.
  final received = <Json>[];
  var stdinClosed = false;
  var killed = false;
  var _requests = 0;
  String? sessionId;
  String permissionMode = 'default';
  String? model;

  /// Whether an interrupt ends the open turn with an aborted result.
  var turnOpen = false;

  late final AcpTransport transport = AcpTransport.streams(
    output: _stdout.stream,
    input: _stdin.sink,
    exitCode: _exit.future,
    errorLines: _stderr.stream,
    kill: () async {
      killed = true;
      die(137);
    },
    relaunch: (extra) async => machine._start(extra).transport,
  );

  bool get exited => _exit.isCompleted;

  void _boot() {
    _stdin.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _onLine(jsonDecode(line) as Json),
          onDone: () {
            stdinClosed = true;
            if (!turnOpen) die(0);
          },
        );
    if (args.contains('--version')) {
      _stdout.add(utf8.encode('${machine.version} (Claude Code)\n'));
      die(0);
      return;
    }
    final resume = _after('--resume');
    if (resume != null && !machine.conversations.contains(resume)) {
      _stderr.add('No conversation found with session ID: $resume');
      emit({
        'type': 'result',
        'subtype': 'error_during_execution',
        'is_error': true,
        'session_id': resume,
      });
      die(1);
      return;
    }
    sessionId = resume ?? _after('--session-id');
    if (sessionId != null) machine.conversations.add(sessionId!);
  }

  String? _after(String flag) {
    final at = args.indexOf(flag);
    return at < 0 || at + 1 >= args.length ? null : args[at + 1];
  }

  void _onLine(Json message) {
    received.add(message);
    for (final waiter in List.of(_waiters)) {
      if (waiter.$1(message)) {
        _waiters.remove(waiter);
        waiter.$2.complete(message);
      }
    }
    switch (message['type']) {
      case 'control_request':
        _onControl(message);
      case 'control_response':
        final response = message['response'] as Json;
        _controlAnswers.remove(response['request_id'])?.complete(response);
      case 'user':
        if (machine.turns.isEmpty) return;
        final turn = machine.turns.removeAt(0);
        turnOpen = true;
        unawaited(turn(this, message));
    }
  }

  void _onControl(Json message) {
    final id = message['request_id'] as String;
    final request = message['request'] as Json;
    switch (request['subtype']) {
      case 'initialize':
        _answer(id, {
          'commands': [
            {'name': 'review', 'description': 'Review', 'argumentHint': ''},
          ],
          'models': machine.models,
          'account': machine.loggedIn
              ? {
                  'email': 'someone@example.com',
                  'subscriptionType': 'max',
                  'apiProvider': 'firstParty',
                }
              : {'tokenSource': 'none', 'apiProvider': 'firstParty'},
          'current_permission_mode': permissionMode,
          'pid': 1,
        });
      case 'set_permission_mode':
        final mode = request['mode'] as String;
        if (mode == 'nonsense') {
          _fail(id, 'Invalid permission mode: nonsense');
          return;
        }
        permissionMode = mode;
        _answer(id, {'mode': mode});
        emit({
          'type': 'system',
          'subtype': 'status',
          'status': null,
          'permissionMode': mode,
        });
      case 'set_model':
        model = request['model'] as String?;
        _answer(id, null);
      case 'mcp_set_servers':
        _answer(id, {
          'added': (request['servers'] as Json).keys.toList(),
          'removed': <String>[],
          'errors': <String, Object?>{},
        });
      case 'interrupt':
        _answer(id, {'still_queued': <Object?>[]});
        if (turnOpen && !machine.ignoreInterrupt) {
          emit({
            'type': 'user',
            'message': {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '[Request interrupted by user]'},
              ],
            },
          });
          result(subtype: 'error_during_execution', isError: true);
        }
      default:
        _fail(id, 'Unsupported control request subtype: ${request['subtype']}');
    }
  }

  void _answer(String id, Json? response) => emit({
    'type': 'control_response',
    'response': {'subtype': 'success', 'request_id': id, 'response': ?response},
  });

  void _fail(String id, String error) => emit({
    'type': 'control_response',
    'response': {'subtype': 'error', 'request_id': id, 'error': error},
  });

  // What a turn writes.

  void emit(Json message) {
    if (_stdout.isClosed) return;
    _stdout.add(
      utf8.encode('${jsonEncode({...message, 'session_id': ?sessionId})}\n'),
    );
  }

  void init({String model = 'claude-opus-5-5'}) => emit({
    'type': 'system',
    'subtype': 'init',
    'model': model,
    'permissionMode': permissionMode,
    'claude_code_version': machine.version,
  });

  /// Streamed deltas for [text] in message [id], as `--include-partial-messages`.
  void streamText(String id, List<String> parts, {bool thinking = false}) {
    emit({
      'type': 'stream_event',
      'event': {
        'type': 'message_start',
        'message': {'id': id},
      },
      'parent_tool_use_id': null,
    });
    for (final part in parts) {
      emit({
        'type': 'stream_event',
        'event': {
          'type': 'content_block_delta',
          'index': 0,
          'delta': thinking
              ? {'type': 'thinking_delta', 'thinking': part}
              : {'type': 'text_delta', 'text': part},
        },
        'parent_tool_use_id': null,
      });
    }
  }

  void assistant(
    String id,
    List<Json> content, {
    String? parentToolUseId,
    Json usage = const {
      'input_tokens': 10,
      'cache_creation_input_tokens': 100,
      'cache_read_input_tokens': 1000,
      'output_tokens': 5,
    },
  }) => emit({
    'type': 'assistant',
    'message': {
      'id': id,
      'role': 'assistant',
      'content': content,
      'usage': usage,
    },
    'parent_tool_use_id': parentToolUseId,
  });

  void toolUse(
    String id,
    String name,
    Json input, {
    String message = 'msg_tool',
    String? parentToolUseId,
  }) => assistant(message, [
    {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
  ], parentToolUseId: parentToolUseId);

  void toolResult(
    String id,
    Object content, {
    bool isError = false,
    Object? toolUseResult,
    String? parentToolUseId,
  }) => emit({
    'type': 'user',
    'message': {
      'role': 'user',
      'content': [
        {
          'type': 'tool_result',
          'tool_use_id': id,
          'content': content,
          if (isError) 'is_error': true,
        },
      ],
    },
    'parent_tool_use_id': parentToolUseId,
    'tool_use_result': ?toolUseResult,
  });

  void system(String subtype, Json fields) =>
      emit({'type': 'system', 'subtype': subtype, ...fields});

  /// Ends the turn as `result` does.
  void result({
    String subtype = 'success',
    bool isError = false,
    String? text = 'Done.',
    String? stopReason = 'end_turn',
    double cost = 0.25,
    List<String>? errors,
    Json? origin,
  }) {
    turnOpen = false;
    emit({
      'type': 'result',
      'subtype': subtype,
      'is_error': isError,
      'result': ?text,
      'stop_reason': stopReason,
      'total_cost_usd': cost,
      'duration_ms': 1200,
      'num_turns': 1,
      'errors': ?errors,
      'origin': ?origin,
      'modelUsage': {
        'claude-opus-5-5': {'contextWindow': 200000, 'costUSD': cost},
      },
    });
    if (stdinClosed) die(0);
  }

  /// Asks the bridge `can_use_tool` and completes with its answer's
  /// `response`.
  Future<Json> askPermission(
    String toolUseId,
    String toolName,
    Json input, {
    List<Json> suggestions = const [],
  }) {
    final id = 'perm-${++_requests}';
    final answer = Completer<Json>();
    _controlAnswers[id] = answer;
    emit({
      'type': 'control_request',
      'request_id': id,
      'request': {
        'subtype': 'can_use_tool',
        'tool_name': toolName,
        'input': input,
        'tool_use_id': toolUseId,
        'permission_suggestions': suggestions,
      },
    });
    return answer.future.then((r) => (r['response'] as Json?) ?? r);
  }

  /// The next message the bridge writes that [test] accepts, or one it
  /// already wrote.
  Future<Json> next(bool Function(Json message) test) {
    for (final message in received) {
      if (test(message)) return Future.value(message);
    }
    final waiter = Completer<Json>();
    _waiters.add((test, waiter));
    return waiter.future;
  }

  /// The control requests the bridge sent, by subtype.
  List<Json> controls(String subtype) => [
    for (final m in received)
      if (m['type'] == 'control_request' &&
          (m['request'] as Json)['subtype'] == subtype)
        m['request'] as Json,
  ];

  void stderr(String line) {
    if (!_stderr.isClosed) _stderr.add(line);
  }

  void die(int code) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}
