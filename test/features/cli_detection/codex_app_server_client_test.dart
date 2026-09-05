import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/process_handle.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_app_server_client.dart';

/// **The client that finally reaches Codex**, driven by scripted JSON rather
/// than by a real `codex`.
///
/// Nothing here spawns a process, reads `~/.codex` or opens a socket: the
/// transport is a [CodexAppServerConnect] handing back a [_ScriptedCodex], so
/// the suite runs identically on a machine with no Codex installed.
///
/// Every reply below is the shape the real thing was measured to send — no
/// `jsonrpc` field on a reply, an unsolicited notification straight after the
/// handshake, and an unknown method answering `-32600` **without an id**. Those
/// are the three details a plausible-looking hand-written fake gets wrong, and
/// each of them would have hung or dropped a real call.
void main() {
  test('the handshake happens once, in order, however many calls follow', () async {
    final server = _ScriptedCodex();
    final client = _clientFor(server);
    addTearDown(client.close);

    await client.setThreadName('t1', 'one');
    await client.setThreadName('t2', 'two');

    expect(
      server.methods,
      ['initialize', 'initialized', 'thread/name/set', 'thread/name/set'],
      reason:
          'one connection serves many calls: a client that handshook per call '
          'would pay the 1708 ms spawn every rename',
    );
    expect(client.connectionsOpened, 1);
    expect(server.requests.first['params'], {
      'clientInfo': {
        'name': 'karmashala',
        'title': 'Karmashala',
        'version': '0.0.0',
      },
    });
    // `initialized` is a notification, so it carries no id and expects no reply.
    expect(server.requests[1].containsKey('id'), isFalse);
  });

  test('nothing is started until the first call', () async {
    final server = _ScriptedCodex();
    final client = _clientFor(server);
    addTearDown(client.close);

    expect(client.connectionsOpened, 0);
    expect(client.info, isNull);

    await client.setThreadName('t1', 'one');

    expect(client.connectionsOpened, 1);
    expect(client.info?.codexHome, '/home/me/.codex');
  });

  test('a rename issues thread/name/set with the thread id and the name', () async {
    final server = _ScriptedCodex();
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.setThreadName('01a06f57-1efb', 'social campaigns');

    expect(result.ok, isTrue);
    expect(result.value, isEmpty, reason: 'the real call answers {}');
    final rename = server.requests.last;
    expect(rename['method'], 'thread/name/set');
    expect(rename['params'], {
      'threadId': '01a06f57-1efb',
      'name': 'social campaigns',
    });
  });

  test('an unknown method is a typed failure, not a hang', () async {
    // Measured against Codex 0.145.0 and 0.153.4: the error that names the 151
    // valid methods arrives with **no id**, because the request never parsed
    // far enough to have one. Charged to the oldest waiter, or the call waits
    // out its whole budget for an answer that already came.
    final server = _ScriptedCodex(
      reply: (server, id, method, params) => jsonEncode({
        'error': {
          'code': -32600,
          'message': 'Invalid request: unknown variant `$method`, expected one '
              'of `initialize`, `thread/name/set`, `thread/list`',
        },
      }),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.call('thread/setName', {'threadId': 't1'});

    expect(result.ok, isFalse);
    expect(result.failure!.kind, CodexAppServerFailureKind.rpcError);
    expect(result.failure!.code, -32600);
    expect(result.failure!.message, contains('unknown variant'));
  });

  test('an error that does carry its id fails only that call', () async {
    final server = _ScriptedCodex(
      reply: (server, id, method, params) => jsonEncode({
        'id': id,
        'error': {'code': -32600, 'message': 'no rollout found for thread id x'},
      }),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.setThreadName('x', 'whatever');

    expect(result.failure!.kind, CodexAppServerFailureKind.rpcError);
    expect(result.failure!.message, contains('no rollout'));
  });

  test('a Codex that cannot be started fails as unavailable, never throws', () async {
    final client = CodexAppServerClient(
      connect: () => Future<ProcessHandle>.error(
        const ProcessException('codex', ['app-server']),
      ),
    );
    addTearDown(client.close);

    final result = await client.setThreadName('t1', 'one');

    expect(result.ok, isFalse);
    expect(result.failure!.kind, CodexAppServerFailureKind.unavailable);
    expect(result.failure!.cause, isA<ProcessException>());
    expect(client.connectionsOpened, 0);
  });

  test('a failed connection is not cached — the next call tries again', () async {
    var attempts = 0;
    final server = _ScriptedCodex();
    final client = CodexAppServerClient(
      connect: () {
        attempts++;
        return attempts == 1
            ? Future<ProcessHandle>.error(
                const ProcessException('codex', ['app-server']),
              )
            : Future<ProcessHandle>.value(server);
      },
    );
    addTearDown(client.close);

    expect((await client.setThreadName('t1', 'one')).ok, isFalse);
    expect((await client.setThreadName('t1', 'one')).ok, isTrue);
    expect(attempts, 2);
  });

  test('an app-server that exits mid-call fails the call rather than hanging', () async {
    final server = _ScriptedCodex(reply: (server, id, method, params) => null);
    final client = _clientFor(server);
    addTearDown(client.close);

    final pending = client.setThreadName('t1', 'one');
    // Wait for the request to be written before taking the process away, so
    // this is a call that was in flight rather than one never sent.
    while (server.methods.length < 3) {
      await Future<void>.delayed(Duration.zero);
    }
    server.emitStderr('codex: fatal');
    await Future<void>.delayed(Duration.zero);
    server.complete(1);

    final result = await pending;
    expect(result.failure!.kind, CodexAppServerFailureKind.exited);
    expect(result.failure!.message, contains('code 1'));
    expect(
      result.failure!.message,
      contains('codex: fatal'),
      reason: 'what Codex printed is the only clue an exit leaves',
    );
  });

  test('a call that is never answered fails as a timeout', () async {
    final server = _ScriptedCodex(reply: (server, id, method, params) => null);
    // A budget, not a measurement: the assertion is *which failure*, never how
    // long anything took.
    final client = _clientFor(server, timeout: const Duration(milliseconds: 50));
    addTearDown(client.close);

    final result = await client.setThreadName('t1', 'one');

    expect(result.failure!.kind, CodexAppServerFailureKind.timeout);
  });

  test('a reply that is not an object is malformed, not a crash', () async {
    final server = _ScriptedCodex(
      reply: (server, id, method, params) =>
          jsonEncode({'id': id, 'result': 'yes'}),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    expect(
      (await client.setThreadName('t1', 'one')).failure!.kind,
      CodexAppServerFailureKind.malformed,
    );
  });

  test('a non-JSON line on stdout is ignored, not charged to a call', () async {
    final server = _ScriptedCodex(
      reply: (server, id, method, params) {
        server.emitStdout('WARNING: proceeding, even though …');
        return jsonEncode({'id': id, 'result': <String, Object?>{}});
      },
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    expect((await client.setThreadName('t1', 'one')).ok, isTrue);
  });

  test('close kills the app-server and leaves nothing running', () async {
    final server = _ScriptedCodex();
    final client = _clientFor(server);

    await client.setThreadName('t1', 'one');
    await client.close();

    expect(server.killed, isTrue);
    expect(
      (await client.setThreadName('t2', 'two')).failure!.kind,
      CodexAppServerFailureKind.closed,
    );
    expect(client.connectionsOpened, 1, reason: 'a closed client starts nothing');
  });

  test('close fails a call that was still waiting', () async {
    final server = _ScriptedCodex(reply: (server, id, method, params) => null);
    final client = _clientFor(server);

    final pending = client.setThreadName('t1', 'one');
    while (server.methods.length < 3) {
      await Future<void>.delayed(Duration.zero);
    }
    await client.close();

    expect((await pending).failure!.kind, CodexAppServerFailureKind.closed);
  });

  group('the store the server actually serves', () {
    test('a different codexHome is refused before any call is made', () async {
      final server = _ScriptedCodex(codexHome: '/home/someone-else/.codex');
      final client = _clientFor(server, expectedCodexHome: '/home/me/.codex');
      addTearDown(client.close);

      final result = await client.setThreadName('t1', 'one');

      expect(result.failure!.kind, CodexAppServerFailureKind.wrongStore);
      expect(
        server.methods,
        ['initialize'],
        reason: 'a rename must never reach the wrong store',
      );
      expect(server.killed, isTrue);
    });

    test('the same home spelled differently is still the same store', () async {
      final server = _ScriptedCodex(codexHome: r'C:\Users\Me\.codex');
      final client = _clientFor(server, expectedCodexHome: r'c:\users\me\.codex\');
      addTearDown(client.close);

      expect((await client.setThreadName('t1', 'one')).ok, isTrue);
    });
  });
}

CodexAppServerClient _clientFor(
  _ScriptedCodex server, {
  Duration timeout = const Duration(seconds: 5),
  String? expectedCodexHome,
}) => CodexAppServerClient(
  connect: () async => server,
  timeout: timeout,
  expectedCodexHome: expectedCodexHome,
);

/// A `codex app-server` that exists only as JSON.
///
/// It answers on the shape the real one was measured to use: replies with no
/// `jsonrpc` field, and an unsolicited `remoteControl/status/changed` right
/// after `initialize`, which is exactly what a live Codex sends and what a
/// client must not mistake for an answer.
class _ScriptedCodex implements ProcessHandle {
  _ScriptedCodex({this.codexHome = '/home/me/.codex', this.reply});

  final String codexHome;

  /// Answers one non-handshake request, or `null` to answer nothing at all.
  final String? Function(
    _ScriptedCodex server,
    int id,
    String method,
    Map<String, Object?> params,
  )?
  reply;

  final List<Map<String, Object?>> requests = [];
  List<String> get methods => [
    for (final request in requests) request['method']! as String,
  ];

  bool killed = false;

  final StreamController<String> _stdout = StreamController<String>();
  final StreamController<String> _stderr = StreamController<String>();
  final Completer<int> _exit = Completer<int>();

  void emitStdout(String line) {
    if (!_stdout.isClosed) _stdout.add(line);
  }

  void emitStderr(String line) {
    if (!_stderr.isClosed) _stderr.add(line);
  }

  void complete([int code = 0]) {
    if (!_exit.isCompleted) _exit.complete(code);
    if (!_stdout.isClosed) _stdout.close();
    if (!_stderr.isClosed) _stderr.close();
  }

  @override
  void writeLine(String line) {
    final request = jsonDecode(line) as Map<String, Object?>;
    requests.add(request);
    final id = request['id'];
    if (id is! int) return;
    final method = request['method']! as String;
    if (method == 'initialize') {
      emitStdout(
        jsonEncode({
          'id': id,
          'result': {
            'userAgent': 'karmashala/0.0.0',
            'codexHome': codexHome,
            'platformFamily': 'unix',
            'platformOs': 'linux',
          },
        }),
      );
      emitStdout(
        jsonEncode({
          'method': 'remoteControl/status/changed',
          'params': {'status': 'disabled'},
        }),
      );
      return;
    }
    final scripted = reply;
    if (scripted == null) {
      emitStdout(jsonEncode({'id': id, 'result': <String, Object?>{}}));
      return;
    }
    final answer = scripted(
      this,
      id,
      method,
      (request['params'] as Map?)?.cast<String, Object?>() ?? const {},
    );
    if (answer != null) emitStdout(answer);
  }

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<List<int>> get stdoutBytes => const Stream<List<int>>.empty();

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> kill() async {
    killed = true;
    complete(137);
  }
}
