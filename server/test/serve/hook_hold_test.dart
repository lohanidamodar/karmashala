import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:test/test.dart';

import 'pipe_connection.dart';

/// A `PreToolUse` posted to the host's endpoint is held — the agent's request
/// stays open — until a watching app replies, or the bound, and not at all with
/// nobody watching.
void main() {
  final clock = DateTime.utc(2026, 9, 25, 10, 0);
  late HostServer server;
  late HookServer endpoint;

  /// The bound is short here so the release-at-bound case is quick; every
  /// other case replies (or does not hold) long before it.
  const bound = Duration(milliseconds: 400);

  setUp(() async {
    server = HostServer(
      registry: SessionRegistry(
        launcher: FakePtyLauncher(),
        clock: () => clock,
      ),
      ptyLibrary: 'libc.so.6',
      clock: () => clock,
      holds: HookHolds(bound: bound),
    );
    endpoint = await HookServer.bind(
      onHook: server.lifecycle.relayHook,
      clock: () => clock,
    );
  });

  tearDown(() => endpoint.close());

  Future<HostLifecycleWatch> watch() async {
    final (client, host) = PipeEnd.pair();
    unawaited(server.serveConnection(host));
    return HostLifecycleWatch.over(client, clientId: 'app');
  }

  /// Posts one hook as the installed script does; completes with the status
  /// once the host answers, and how long that took.
  Future<(int, Duration)> post(String event) async {
    final client = HttpClient();
    final took = Stopwatch()..start();
    try {
      final request = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${endpoint.port}/agent-hook'
          '?agent=claude-code&event=$event',
        ),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${endpoint.token}',
      );
      request.write(jsonEncode({'session_id': 'c1'}));
      final response = await request.close();
      await response.drain<void>();
      return (response.statusCode, took.elapsed);
    } finally {
      client.close();
    }
  }

  /// Whether [answer] is still open after [wait].
  Future<bool> stillOpen(Future<Object?> answer, Duration wait) async {
    var done = false;
    unawaited(answer.then((_) => done = true));
    await Future<void>.delayed(wait);
    return !done;
  }

  test('a PreToolUse stays open until the watching app replies', () async {
    final app = await watch();
    addTearDown(app.close);
    final relayed = StreamIterator(app.hooks);

    final answer = post('PreToolUse');
    expect(await relayed.moveNext(), isTrue);
    final holdId = relayed.current.holdId;
    expect(holdId, isNotNull, reason: 'relayed as held');
    expect(
      await stillOpen(answer, const Duration(milliseconds: 150)),
      isTrue,
      reason: 'nobody has replied yet',
    );

    app.replyHook(holdId!);
    final (status, took) = await answer;
    expect(status, HttpStatus.ok);
    expect(took, lessThan(bound), reason: 'released by the reply');
    expect(
      server.lifecycle.hooks.latest().single.holdId,
      isNull,
      reason: 'the snapshot never carries a hold',
    );
  });

  test('with no reply, the hold is released at the bound', () async {
    final app = await watch();
    addTearDown(app.close);
    final relayed = <AgentHookEvent>[];
    app.hooks.listen(relayed.add);

    final (status, took) = await post('PreToolUse');
    expect(status, HttpStatus.ok);
    expect(took, greaterThanOrEqualTo(bound));
    expect(relayed.single.holdId, isNotNull);
    expect(
      server.lifecycle.replyHook(relayed.single.holdId!),
      isFalse,
      reason: 'a reply after the bound finds nothing to release',
    );
  });

  test('with nobody watching, it is answered at once and kept unheld for '
      'the snapshot', () async {
    expect(server.lifecycle.hasWatchers, isFalse);
    final (status, took) = await post('PreToolUse');
    expect(status, HttpStatus.ok);
    expect(took, lessThan(bound));

    final app = await watch();
    addTearDown(app.close);
    expect(app.hookSnapshot.single.event, 'PreToolUse');
    expect(app.hookSnapshot.single.holdId, isNull);
  });

  test('another event is not held, even with an app watching', () async {
    final app = await watch();
    addTearDown(app.close);
    final relayed = <AgentHookEvent>[];
    app.hooks.listen(relayed.add);

    final (_, took) = await post('Stop');
    expect(took, lessThan(bound));
    await Future<void>.delayed(Duration.zero);
    expect(relayed.single.holdId, isNull);
  });

  test('with two apps watching, the first reply releases it', () async {
    final first = await watch();
    final second = await watch();
    addTearDown(first.close);
    addTearDown(second.close);
    final one = StreamIterator(first.hooks);
    final two = StreamIterator(second.hooks);

    final answer = post('PreToolUse');
    expect(await one.moveNext(), isTrue);
    expect(await two.moveNext(), isTrue);
    expect(one.current.holdId, two.current.holdId);

    second.replyHook(two.current.holdId!);
    final (_, took) = await answer;
    expect(took, lessThan(bound));
    expect(server.lifecycle.replyHook(one.current.holdId!), isFalse);
  });

  test('the last app hanging up releases the hold', () async {
    final app = await watch();
    final relayed = StreamIterator(app.hooks);

    final answer = post('PreToolUse');
    expect(await relayed.moveNext(), isTrue);
    await app.close();
    final (_, took) = await answer;
    expect(took, lessThan(bound));
  });
}
