import 'dart:async';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:test/test.dart';

import 'pipe_connection.dart';

/// A hook a client took itself (its own route, a spool) reaches the server's
/// checkpoint recorder: `hookForward`, never held, never relayed back.
void main() {
  final clock = DateTime.utc(2026, 9, 27, 9);

  test('a forwarded hook reaches onForwardedHook, whole', () async {
    final server = HostServer(
      registry: SessionRegistry(
        launcher: FakePtyLauncher(),
        clock: () => clock,
      ),
      ptyLibrary: 'libc.so.6',
      clock: () => clock,
    );
    final forwarded = <AgentHookEvent>[];
    server.onForwardedHook = forwarded.add;
    final (client, host) = PipeEnd.pair();
    unawaited(server.serveConnection(host));
    final app = await HostLifecycleWatch.over(client, clientId: 'app');
    addTearDown(app.close);
    final relayed = <AgentHookEvent>[];
    app.hooks.listen(relayed.add);

    app.forwardHook(
      AgentHookEvent(
        agent: 'claudeCode',
        event: 'PreToolUse',
        sessionHeader: 'row-1',
        receivedAt: clock,
        body: const {
          'session_id': 'c1',
          'tool_input': {'file_path': '/src/a.dart'},
        },
      ),
    );
    for (var i = 0; i < 20 && forwarded.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final hook = forwarded.single;
    expect(hook.event, 'PreToolUse');
    expect(hook.sessionHeader, 'row-1');
    expect(hook.receivedAt, clock);
    expect((hook.body['tool_input'] as Map)['file_path'], '/src/a.dart');
    expect(relayed, isEmpty, reason: 'the client took it; nothing comes back');
    expect(server.lifecycle.hooks.latest(), isEmpty);
  });

  test('with nobody listening, a forwarded hook is dropped quietly', () async {
    final server = HostServer(
      registry: SessionRegistry(
        launcher: FakePtyLauncher(),
        clock: () => clock,
      ),
      ptyLibrary: 'libc.so.6',
      clock: () => clock,
    );
    final (client, host) = PipeEnd.pair();
    unawaited(server.serveConnection(host));
    final app = await HostLifecycleWatch.over(client, clientId: 'app');
    addTearDown(app.close);
    app.forwardHook(
      AgentHookEvent(
        agent: 'claudeCode',
        event: 'Stop',
        receivedAt: clock,
        body: const {},
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.clientCount, 1, reason: 'the link is still up');
  });
}
