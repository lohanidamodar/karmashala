import 'dart:async';

import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';

/// A scripted `codex app-server` over in-memory streams, speaking the v2
/// JSON-RPC the real one does (codex-cli 0.160.0): what the bridge sends is
/// kept per method, and a test drives each turn through [onTurn].
class FakeCodexAppServer {
  FakeCodexAppServer({
    this.account = const {
      'type': 'chatgpt',
      'email': 'someone@example.com',
      'planType': 'plus',
    },
    this.threads = const {},
    this.onTurn,
  }) {
    _peer = AcpPeer(_fromBridge.stream, _toBridge.sink);
    _peer.requests.listen(_onRequest);
    _peer.notifications.listen((n) => notifications.add(n.method));
  }

  /// What `account/read` answers; null is a Codex nobody has logged in to.
  JsonMap? account;

  /// Threads `thread/resume` finds, by id, as `Thread` objects.
  final Map<String, JsonMap> threads;

  /// Runs each turn once `turn/start` has been answered.
  Future<void> Function(FakeCodexTurn turn)? onTurn;

  final _toBridge = StreamController<List<int>>();
  final _fromBridge = StreamController<List<int>>();
  late final AcpPeer _peer;
  final exit = Completer<int>();
  final calls = <String, List<JsonMap>>{};
  final notifications = <String>[];
  var killed = false;
  FakeCodexTurn? turn;
  var _turns = 0;

  static const models = [
    {
      'id': 'gpt-fast',
      'model': 'gpt-fast',
      'displayName': 'GPT Fast',
      'description': 'Quick.',
      'hidden': false,
      'supportedReasoningEfforts': [
        {'reasoningEffort': 'low', 'description': 'Light'},
        {'reasoningEffort': 'medium', 'description': 'Balanced'},
      ],
      'defaultReasoningEffort': 'medium',
      'isDefault': true,
    },
    {
      'id': 'gpt-deep',
      'model': 'gpt-deep',
      'displayName': 'GPT Deep',
      'description': 'Thorough.',
      'hidden': false,
      'supportedReasoningEfforts': [
        {'reasoningEffort': 'high', 'description': 'Deep'},
        {'reasoningEffort': 'xhigh', 'description': 'Deeper'},
      ],
      'defaultReasoningEffort': 'high',
      'isDefault': false,
    },
    {
      'id': 'gpt-secret',
      'model': 'gpt-secret',
      'displayName': 'Hidden',
      'description': '',
      'hidden': true,
      'supportedReasoningEfforts': <Object?>[],
      'defaultReasoningEffort': 'low',
      'isDefault': false,
    },
  ];

  /// The process as the bridge wraps it.
  AcpTransport get transport => AcpTransport.streams(
    output: _toBridge.stream,
    input: _fromBridge.sink,
    exitCode: exit.future,
    errorLines: const Stream.empty(),
    kill: () async {
      killed = true;
      await die(137);
    },
  );

  List<JsonMap> callsTo(String method) => calls[method] ?? const [];

  /// The process ended with [code]: its exit, then its streams.
  Future<void> die(int code) async {
    if (!exit.isCompleted) exit.complete(code);
    await _peer.close();
    if (!_toBridge.isClosed) await _toBridge.close();
  }

  void notify(String method, JsonMap params) => _peer.notify(method, params);

  Future<Object?> request(String method, JsonMap params) =>
      _peer.call(method, params);

  JsonMap thread(String id, {List<JsonMap> turns = const [], String? name}) => {
    'id': id,
    'sessionId': id,
    'preview': '',
    'ephemeral': false,
    'modelProvider': 'openai',
    'model': 'gpt-fast',
    'reasoningEffort': 'medium',
    'createdAt': 1,
    'updatedAt': 1,
    'status': {'type': 'idle'},
    'path': null,
    'cwd': '/work',
    'cliVersion': '0.160.0',
    'source': 'appServer',
    'name': name,
    'turns': turns,
  };

  JsonMap _threadResult(JsonMap thread) => {
    'thread': thread,
    'model': 'gpt-fast',
    'modelProvider': 'openai',
    'serviceTier': null,
    'cwd': thread['cwd'],
    'approvalPolicy': 'on-request',
    'approvalsReviewer': 'user',
    'sandbox': {
      'type': 'workspaceWrite',
      'writableRoots': ['/extra'],
      'networkAccess': true,
      'excludeTmpdirEnvVar': false,
      'excludeSlashTmp': false,
    },
    'reasoningEffort': 'medium',
  };

  void _onRequest(AcpIncomingRequest request) {
    final params = request.paramsMap;
    calls.putIfAbsent(request.method, () => []).add(params);
    switch (request.method) {
      case 'initialize':
        request.respond({
          'userAgent':
              'Karmashala/0.160.0 (Windows 10.0.26200; x86_64) '
              'xterm-256color (Karmashala; 1)',
          'codexHome': '/home/someone/.codex',
          'platformFamily': 'unix',
          'platformOs': 'linux',
        });
      case 'account/read':
        request.respond({'account': account, 'requiresOpenaiAuth': true});
      case 'account/login/start':
        request.respond({
          'type': 'chatgpt',
          'loginId': 'login-1',
          'authUrl': 'https://auth.example.com/oauth?state=1',
        });
        Timer(const Duration(milliseconds: 10), () {
          account = const {'type': 'chatgpt', 'planType': 'plus'};
          notify('account/login/completed', {
            'loginId': 'login-1',
            'success': true,
            'error': null,
          });
        });
      case 'account/logout':
        account = null;
        request.respond(const <String, Object?>{});
      case 'model/list':
        request.respond({'data': models, 'nextCursor': null});
      case 'thread/start':
        request.respond(_threadResult(thread('thr-new')));
      case 'thread/resume':
        final id = params['threadId'];
        final found = threads[id];
        if (found == null) {
          request.fail(-32600, 'no rollout found for thread id $id');
        } else {
          request.respond(_threadResult(found));
        }
      case 'turn/start':
        final id = 'turn-${++_turns}';
        final turn = this.turn = FakeCodexTurn(
          this,
          '${params['threadId']}',
          id,
        );
        request.respond({
          'turn': {'id': id, 'items': <Object?>[], 'status': 'inProgress'},
        });
        final script = onTurn;
        if (script != null) {
          scheduleMicrotask(() async {
            await script(turn);
          });
        }
      case 'turn/interrupt':
        request.respond(const <String, Object?>{});
        turn?.interrupted.complete();
      default:
        request.fail(-32600, 'unknown method ${request.method}');
    }
  }
}

/// One turn the fake is running: what it says, and how it ends.
class FakeCodexTurn {
  FakeCodexTurn(this.server, this.threadId, this.id);

  final FakeCodexAppServer server;
  final String threadId;
  final String id;

  /// Completes when the bridge asks for `turn/interrupt`.
  final interrupted = Completer<void>();

  void notify(String method, JsonMap params) =>
      server.notify(method, {'threadId': threadId, 'turnId': id, ...params});

  void started(JsonMap item) => notify('item/started', {'item': item});

  void completed(JsonMap item) => notify('item/completed', {'item': item});

  void delta(String method, String itemId, String delta) =>
      notify(method, {'itemId': itemId, 'delta': delta});

  Future<Object?> ask(String method, JsonMap params) => server.request(method, {
    'threadId': threadId,
    'turnId': id,
    'startedAtMs': 1,
    ...params,
  });

  void end(String status, {JsonMap? error}) => server.notify('turn/completed', {
    'threadId': threadId,
    'turn': {
      'id': id,
      'items': <Object?>[],
      'status': status,
      'error': error,
      'durationMs': 1200,
    },
  });
}
