import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:agent_cli/src/process/process_handle.dart';
import 'package:agent_cli/src/cli_detection/data/codex_app_server_client.dart';
import 'package:agent_cli/src/cli_detection/data/codex_thread.dart';

import '../support/fake_codex_app_server.dart';

/// **The client that finally reaches Codex**, driven by scripted JSON rather
/// than by a real `codex`.
///
/// Nothing here spawns a process, reads `~/.codex` or opens a socket: the
/// transport is a [CodexAppServerConnect] handing back a [FakeCodexAppServer], so
/// the suite runs identically on a machine with no Codex installed.
///
/// Every reply below is the shape the real thing was measured to send: no
/// `jsonrpc` field, an unsolicited notification straight after the handshake,
/// and `-32600` for an unknown method — carrying its id, like every other
/// reply, as the last key after a 3.7 KB message.
///
/// That last detail was got wrong here once, and the way it was got wrong is
/// worth keeping: the probe that "measured" it truncated each printed line at
/// 400 characters, which cut `"id":77` off the end of the longest error the
/// server sends, while a short domain error kept its id and made the contrast
/// look like a rule. Re-measured against both binaries with the raw key list
/// printed, every error reply carries its id. Nothing here correlates a reply
/// any other way.
void main() {
  test('the handshake happens once, in order, however many calls follow', () async {
    final server = FakeCodexAppServer();
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
    final server = FakeCodexAppServer();
    final client = _clientFor(server);
    addTearDown(client.close);

    expect(client.connectionsOpened, 0);
    expect(client.info, isNull);

    await client.setThreadName('t1', 'one');

    expect(client.connectionsOpened, 1);
    expect(client.info?.codexHome, '/home/me/.codex');
  });

  test('a rename issues thread/name/set with the thread id and the name', () async {
    final server = FakeCodexAppServer();
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

  test('a thread/name/updated notification reaches the title listener', () async {
    final updates = <CodexThreadNameUpdate>[];
    final server = FakeCodexAppServer();
    final client = CodexAppServerClient(
      connect: () async => server,
      onThreadNameUpdated: updates.add,
    );
    addTearDown(client.close);

    await client.setThreadName('t1', ' renamed in Codex ');

    expect(updates, hasLength(1));
    expect(updates.single.threadId, 't1');
    expect(updates.single.name, 'renamed in Codex');
  });

  test('a name with non-ASCII characters crosses as escaped ASCII', () async {
    final server = FakeCodexAppServer();
    final client = _clientFor(server);
    addTearDown(client.close);

    await client.setThreadName('t1', 'नाम — caf\u00e9');

    // A ProcessHandle's stdin defaults to `systemEncoding`, which on a Windows
    // host is the ANSI code page: anything outside it reaches Codex as `?`.
    expect(
      server.written.last.codeUnits.every((unit) => unit < 0x80),
      isTrue,
      reason: 'the line must survive an encoding that cannot spell the name',
    );
    expect(server.lastNameSet, {'threadId': 't1', 'name': 'नाम — caf\u00e9'});
  });

  test('an unknown method is a typed failure, not a hang', () async {
    // The real reply, key order included: `error` first, then the id. Measured
    // on 0.145.0 and 0.153.4 — `thread/setName` does not exist on either.
    final server = FakeCodexAppServer(
      reply: (server, id, method, params) => jsonEncode({
        'error': {
          'code': -32600,
          'message': 'Invalid request: unknown variant `$method`, expected one '
              'of `initialize`, `thread/name/set`, `thread/list`',
        },
        'id': id,
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

  test('a domain error is the same shape, and fails only its own call', () async {
    final server = FakeCodexAppServer(
      reply: (server, id, method, params) => jsonEncode({
        'error': {'code': -32600, 'message': 'no rollout found for thread id x'},
        'id': id,
      }),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.setThreadName('x', 'whatever');

    expect(result.failure!.kind, CodexAppServerFailureKind.rpcError);
    expect(result.failure!.message, contains('no rollout'));
  });

  test('an error naming no call is dropped, never charged to a waiting one', () async {
    // Codex attributes every reply it sends, so this should not arise at all —
    // and if it ever does, guessing an owner can only fail the wrong call. The
    // waiting call keeps waiting for the answer that is addressed to it.
    final server = FakeCodexAppServer(
      reply: (server, id, method, params) {
        server.emitStdout(
          jsonEncode({
            'error': {'code': -32600, 'message': 'addressed to nobody'},
          }),
        );
        return jsonEncode({'id': id, 'result': <String, Object?>{}});
      },
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    expect((await client.setThreadName('t1', 'one')).ok, isTrue);
  });

  test('a request Codex never answers is left to the timeout', () async {
    // Measured: malformed JSON — an unterminated object, a bare non-JSON line —
    // draws no reply of any kind, and the next well-formed request is still
    // answered. So the connection survives and the budget is the whole of the
    // handling. Nothing else in this client is allowed to invent a failure for
    // an unanswered call.
    var answered = 0;
    final server = FakeCodexAppServer(
      reply: (server, id, method, params) {
        answered++;
        return answered == 1
            ? null
            : jsonEncode({'id': id, 'result': <String, Object?>{}});
      },
    );
    final client = _clientFor(server, timeout: const Duration(milliseconds: 50));
    addTearDown(client.close);

    expect(
      (await client.setThreadName('t1', 'one')).failure!.kind,
      CodexAppServerFailureKind.timeout,
    );
    expect(
      (await client.setThreadName('t2', 'two')).ok,
      isTrue,
      reason: 'a dropped request must not poison the connection',
    );
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
    final server = FakeCodexAppServer();
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
    final server = FakeCodexAppServer(reply: (server, id, method, params) => null);
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
    final server = FakeCodexAppServer(reply: (server, id, method, params) => null);
    // A budget, not a measurement: the assertion is *which failure*, never how
    // long anything took.
    final client = _clientFor(server, timeout: const Duration(milliseconds: 50));
    addTearDown(client.close);

    final result = await client.setThreadName('t1', 'one');

    expect(result.failure!.kind, CodexAppServerFailureKind.timeout);
  });

  test('a reply that is not an object is malformed, not a crash', () async {
    final server = FakeCodexAppServer(
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
    final server = FakeCodexAppServer(
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
    final server = FakeCodexAppServer();
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

  test('closing while the spawn is in flight still kills it', () async {
    final server = FakeCodexAppServer();
    final spawned = Completer<void>();
    final client = CodexAppServerClient(
      connect: () async {
        spawned.complete();
        return server;
      },
    );

    final pending = client.setThreadName('t1', 'one');
    await spawned.future;
    await client.close();

    expect((await pending).failure!.kind, CodexAppServerFailureKind.closed);
    expect(
      server.killed,
      isTrue,
      reason: 'a process that arrived after close must not wait out a timeout',
    );
  });

  test('close fails a call that was still waiting', () async {
    final server = FakeCodexAppServer(reply: (server, id, method, params) => null);
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
      final server = FakeCodexAppServer(codexHome: '/home/someone-else/.codex');
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
      final server = FakeCodexAppServer(codexHome: r'C:\Users\Me\.codex');
      final client = _clientFor(server, expectedCodexHome: r'c:\users\me\.codex\');
      addTearDown(client.close);

      expect((await client.setThreadName('t1', 'one')).ok, isTrue);
    });
  });

  group('thread/list', () {
    test('every source kind is asked for, on every page', () async {
      final server = FakeCodexAppServer.withThreads(
        [for (var i = 0; i < 5; i++) _row('t$i')],
        pageSize: 2,
      );
      final client = _clientFor(server);
      addTearDown(client.close);

      final list = await client.listThreads(pageSize: 2);

      expect(list.ok, isTrue);
      expect(list.threads.length, 5);
      // The trap this test exists for: omit `sourceKinds` and Codex applies an
      // "interactive sources" default that answered 11 of 16 real threads.
      for (final params in server.threadListParams) {
        expect(
          params['sourceKinds'],
          codexThreadSourceKinds,
          reason: 'a page that drops a kind drops the sessions of that kind',
        );
        expect(params['useStateDbOnly'], isTrue);
      }
      expect(codexThreadSourceKinds, hasLength(10));
    });

    test('paging follows nextCursor to exhaustion', () async {
      final server = FakeCodexAppServer.withThreads(
        [for (var i = 0; i < 7; i++) _row('t$i')],
        pageSize: 3,
      );
      final client = _clientFor(server);
      addTearDown(client.close);

      final list = await client.listThreads(pageSize: 3);

      expect(list.threads.map((t) => t.id), [
        for (var i = 0; i < 7; i++) 't$i',
      ]);
      expect(client.threadsPaged, 3, reason: '3 + 3 + 1');
      expect(server.threadListParams.first.containsKey('cursor'), isFalse);
      expect(server.threadListParams[1]['cursor'], '3');
      expect(server.threadListParams[2]['cursor'], '6');
    });

    test('a repeated cursor ends the loop instead of spinning', () async {
      final server = FakeCodexAppServer(
        reply: (server, id, method, params) => jsonEncode({
          'id': id,
          'result': {
            'data': [_row('t1')],
            'nextCursor': 'always-the-same',
          },
        }),
      );
      final client = _clientFor(server);
      addTearDown(client.close);

      final list = await client.listThreads();

      expect(list.threads, hasLength(2), reason: 'the page, then the repeat');
      expect(client.threadsPaged, 2);
    });

    test('rows are parsed with epoch-second timestamps', () async {
      final server = FakeCodexAppServer.withThreads([
        {
          'id': '01a06f57',
          'name': 'social campaigns',
          'preview': 'i want you to create a chatgpt site',
          'cwd': '/mnt/c/users/me/projects',
          'path': '/home/me/.codex/sessions/2026/09/05/rollout-x.jsonl',
          'createdAt': 1788574375,
          'updatedAt': 1788585458,
        },
      ]);
      final client = _clientFor(server);
      addTearDown(client.close);

      final thread = (await client.listThreads()).threads.single;

      expect(thread.id, '01a06f57');
      expect(thread.name, 'social campaigns');
      expect(thread.preview, 'i want you to create a chatgpt site');
      expect(thread.cwd, '/mnt/c/users/me/projects');
      expect(thread.path, '/home/me/.codex/sessions/2026/09/05/rollout-x.jsonl');
      // Seconds, not milliseconds: reading them as milliseconds dates every
      // session to 1970.
      expect(
        thread.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1788574375000, isUtc: true),
      );
      expect(
        thread.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1788585458000, isUtc: true),
      );
    });

    test('a row with no id or no cwd is dropped, not guessed at', () async {
      final server = FakeCodexAppServer.withThreads([
        {'id': 'ok', 'cwd': '/w'},
        {'cwd': '/w'},
        {'id': 'no-cwd'},
        {'id': 'blank-cwd', 'cwd': ''},
      ]);
      final client = _clientFor(server);
      addTearDown(client.close);

      expect((await client.listThreads()).threads.map((t) => t.id), ['ok']);
    });

    test('an rpc error is the failure, not an empty store', () async {
      final server = FakeCodexAppServer(
        reply: (server, id, method, params) => jsonEncode({
          'error': {'code': -32600, 'message': 'Invalid request'},
          'id': id,
        }),
      );
      final client = _clientFor(server);
      addTearDown(client.close);

      final list = await client.listThreads();

      expect(list.ok, isFalse);
      expect(list.failure!.kind, CodexAppServerFailureKind.rpcError);
      expect(
        list.threads,
        isEmpty,
        reason: 'a caller must be able to tell "none" from "could not ask"',
      );
    });

    test('a reply with no data array is malformed, not empty', () async {
      final server = FakeCodexAppServer(
        reply: (server, id, method, params) =>
            jsonEncode({'id': id, 'result': <String, Object?>{}}),
      );
      final client = _clientFor(server);
      addTearDown(client.close);

      final list = await client.listThreads();

      expect(list.failure!.kind, CodexAppServerFailureKind.malformed);
    });
  });
}

/// A `thread/list` row with only the fields that must be present.
Map<String, Object?> _row(String id) => {'id': id, 'cwd': '/w/$id'};

CodexAppServerClient _clientFor(
  FakeCodexAppServer server, {
  Duration timeout = const Duration(seconds: 5),
  String? expectedCodexHome,
}) => CodexAppServerClient(
  connect: () async => server,
  timeout: timeout,
  expectedCodexHome: expectedCodexHome,
);
