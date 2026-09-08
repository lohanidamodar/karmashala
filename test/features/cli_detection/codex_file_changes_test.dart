import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/process_handle.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_app_server_client.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_thread.dart';

import '../../support/fake_codex_app_server.dart';

/// **What Codex's own record says a thread changed**, read through the one
/// method that carries it, and driven by scripted JSON rather than a real
/// `codex`.
///
/// Every shape below was measured against codex 0.153.4 on 2026-09-08, over the
/// owner's 19 real threads:
///
/// * `itemsView` accepts `notLoaded`, `summary` and `full` — the server names
///   all three in the `-32600` it answers an unknown variant with. The default
///   is `summary`, and a summary turn carries **only** `userMessage` and
///   `agentMessage` items (19 + 14 across one 23-turn thread), so a reader that
///   omits the field sees no file change at all and would report a thread that
///   rewrote 58 files as having changed nothing.
/// * A `fileChange` item's `changes` is a **list**, each entry
///   `{path, kind: {type, move_path?}, diff}`. 110 changes over that thread:
///   86 `update`, 21 `add`, 3 `delete`. `move_path` was null in all 110.
/// * `limit` pages the turns and `nextCursor` is an **object**, handed back
///   verbatim as `cursor`. A string cursor is refused (`invalid cursor: 0`).
///   Paging matters: one `full` page of a 23-turn thread is 15.4 MB of JSON,
///   and four turns at a time caps it at 7.5 MB.
/// * A thread this store does not hold answers `-32600 "thread not loaded"`,
///   which is a **failure**, not an empty list — the whole of §19 in one reply.
void main() {
  /// One `full` turn holding [changes] file changes.
  Map<String, Object?> turn(List<Map<String, Object?>> changes) => {
    'id': 'turn-1',
    'itemsView': 'full',
    'status': 'completed',
    'error': null,
    'items': [
      {'type': 'reasoning', 'id': 'r1'},
      {'type': 'fileChange', 'id': 'exec-1', 'changes': changes},
      {'type': 'commandExecution', 'id': 'c1'},
    ],
  };

  test('it asks for the full item view, or it would see no change at all', () async {
    final server = FakeCodexAppServer(
      reply: (_, id, method, params) => jsonEncode({
        'id': id,
        'result': {'data': <Object?>[], 'nextCursor': null},
      }),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    await client.listFileChanges('t1');

    expect(server.methods, contains('thread/turns/list'));
    final params = server.requests
        .firstWhere((r) => r['method'] == 'thread/turns/list')['params']!;
    expect(
      (params as Map)['itemsView'],
      'full',
      reason:
          'the default is "summary", whose turns carry only user and agent '
          'messages — a reader that omits this reports every thread as having '
          'changed nothing',
    );
    expect(params['threadId'], 't1');
  });

  test('it reads the path and the kind of every change', () async {
    final server = FakeCodexAppServer(
      reply: (_, id, method, params) => jsonEncode({
        'id': id,
        'result': {
          'data': [
            turn([
              {
                'path': '/home/me/app/lib/main.dart',
                'kind': {'type': 'update', 'move_path': null},
                'diff': '@@ -1,3 +1,3 @@\n-a\n+b\n',
              },
              {
                'path': '/home/me/app/lib/added.dart',
                'kind': {'type': 'add'},
                'diff': '@@ -0,0 +1 @@\n+x\n',
              },
              {
                'path': '/home/me/app/lib/gone.dart',
                'kind': {'type': 'delete'},
                'diff': '',
              },
              {
                'path': '/home/me/app/lib/old.dart',
                'kind': {'type': 'update', 'move_path': '/home/me/app/lib/new.dart'},
                'diff': '',
              },
            ]),
          ],
          'nextCursor': null,
        },
      }),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.listFileChanges('t1');

    expect(result.ok, isTrue);
    expect(result.turnsRead, 1);
    expect(
      result.changes.map((c) => '${c.kind.name} ${c.path}'),
      [
        'update /home/me/app/lib/main.dart',
        'add /home/me/app/lib/added.dart',
        'delete /home/me/app/lib/gone.dart',
        'update /home/me/app/lib/old.dart',
      ],
    );
    expect(result.changes.last.movedTo, '/home/me/app/lib/new.dart');
    expect(result.changes.first.movedTo, isNull);
  });

  test('a kind this build does not know is unknown, never a modification', () async {
    final server = FakeCodexAppServer(
      reply: (_, id, method, params) => jsonEncode({
        'id': id,
        'result': {
          'data': [
            turn([
              {
                'path': '/home/me/app/x.dart',
                'kind': {'type': 'chmod'},
                'diff': '',
              },
            ]),
          ],
          'nextCursor': null,
        },
      }),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.listFileChanges('t1');

    expect(result.changes.single.kind, CodexFileChangeKind.unknown);
  });

  test('it pages on the cursor object the server hands back, verbatim', () async {
    final pages = [
      {
        'data': [turn([_change('/a.dart')])],
        'nextCursor': {'rolloutOrdinal': 4320, 'includeAnchor': false},
      },
      {
        'data': [turn([_change('/b.dart')])],
        'nextCursor': null,
      },
    ];
    var page = 0;
    final server = FakeCodexAppServer(
      reply: (_, id, method, params) =>
          jsonEncode({'id': id, 'result': pages[page++]}),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.listFileChanges('t1', pageSize: 4);

    expect(result.changes.map((c) => c.path), ['/a.dart', '/b.dart']);
    expect(result.turnsRead, 2);
    final calls = server.requests
        .where((r) => r['method'] == 'thread/turns/list')
        .map((r) => (r['params']! as Map).cast<String, Object?>())
        .toList();
    expect(calls.length, 2);
    expect(calls.first.containsKey('cursor'), isFalse);
    expect(calls.first['limit'], 4);
    expect(
      calls.last['cursor'],
      {'rolloutOrdinal': 4320, 'includeAnchor': false},
      reason:
          'the cursor is an opaque object; a client that reduced it to a '
          'string got "invalid cursor" from the real server',
    );
  });

  test('a repeated cursor ends the walk rather than spinning', () async {
    var calls = 0;
    final server = FakeCodexAppServer(
      reply: (_, id, method, params) {
        calls++;
        return jsonEncode({
          'id': id,
          'result': {
            'data': [turn([_change('/a.dart')])],
            'nextCursor': {'rolloutOrdinal': 1},
          },
        });
      },
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.listFileChanges('t1');

    expect(result.ok, isTrue);
    expect(calls, 2, reason: 'the second page repeated the first cursor');
  });

  test('a thread this store does not hold fails; it does not read as empty', () async {
    final server = FakeCodexAppServer(
      reply: (_, id, method, params) => jsonEncode({
        'error': {'code': -32600, 'message': 'thread not loaded: t9'},
        'id': id,
      }),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.listFileChanges('t9');

    expect(result.ok, isFalse);
    expect(result.failure!.kind, CodexAppServerFailureKind.rpcError);
    expect(result.failure!.message, contains('thread not loaded'));
    expect(result.changes, isEmpty);
  });

  test('a reply without a data array is malformed, not empty', () async {
    final server = FakeCodexAppServer(
      reply: (_, id, method, params) =>
          jsonEncode({'id': id, 'result': <String, Object?>{}}),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.listFileChanges('t1');

    expect(result.ok, isFalse);
    expect(result.failure!.kind, CodexAppServerFailureKind.malformed);
  });

  test('a thread that changed nothing answers an empty list, and succeeds', () async {
    final server = FakeCodexAppServer(
      reply: (_, id, method, params) => jsonEncode({
        'id': id,
        'result': {
          'data': [
            {
              'id': 'turn-1',
              'itemsView': 'full',
              'status': 'completed',
              'items': [
                {'type': 'agentMessage', 'id': 'm1'},
              ],
            },
          ],
          'nextCursor': null,
        },
      }),
    );
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.listFileChanges('t1');

    expect(result.ok, isTrue);
    expect(result.changes, isEmpty);
    expect(result.turnsRead, 1);
  });
}

Map<String, Object?> _change(String path) => {
  'path': path,
  'kind': {'type': 'update', 'move_path': null},
  'diff': '@@ -1 +1 @@\n-a\n+b\n',
};

CodexAppServerClient _clientFor(FakeCodexAppServer server) =>
    CodexAppServerClient(
      connect: () async => server as ProcessHandle,
      timeout: const Duration(seconds: 5),
    );
