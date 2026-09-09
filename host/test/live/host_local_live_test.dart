@Tags(['live'])
library;

import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

import 'local_host_harness.dart';

/// The whole host on *this* machine: a real `serve`, a real unix domain socket
/// on Windows, a real ConPTY behind it, and a client that connects to the
/// socket directly rather than through `attach`.
///
/// This is the local stage's own proof, and the answer to "what listener".
/// Nothing here is a named pipe or a loopback port: `HostPaths.socketPath`
/// records why, and this test is what makes that claim checkable on the machine
/// it is claimed about.
///
/// Everything counts — bytes, offsets, frames. Every `Duration` is a failure
/// bound on a future, not a poll.
void main() {
  late LocalHost host;

  setUpAll(() async {
    host = await LocalHost.start(temporaryHome('karmashala-host-local'));
    expect(host.greeting, contains(host.socketPath));
    expect(
      host.greeting,
      contains(Platform.isWindows ? 'kernel32.dll' : 'libc'),
      reason: 'the host reports which pty layer it measured, never which it assumed',
    );
    expect(host.greeting, contains('restored 0 session(s)'));
  });

  tearDownAll(() => host.kill());

  test('a client reaches the socket, runs a shell, and reads its exit code', () async {
    final client = await LocalHostClient.connect(host.socketPath, 'pane-1');
    addTearDown(client.close);

    final welcome = await client.expect<WelcomeMessage>();
    expect(welcome.protocolVersion, kProtocolVersion);
    expect(welcome.hostVersion, kHostVersion);
    expect(welcome.operatingSystem, Platform.operatingSystem);

    client.send(
      OpenMessage(
        requestId: client.nextId(),
        sessionId: 'local-a',
        argv: probeShell,
        environment: const {'TERM': 'xterm-256color'},
        columns: 80,
        rows: 24,
      ),
    );
    final attached = await client.expect<AttachedMessage>();
    expect(attached.sessionId, 'local-a');
    expect(attached.holdsWriteToken, isTrue);
    expect(attached.replayFromOffset, 0);

    client
      ..type(attached.sessionRef, setA)
      ..type(attached.sessionRef, setB)
      ..type(attached.sessionRef, echoAB);
    expect(await client.output('karmashala'), isTrue, reason: client.tail(400));

    client.type(attached.sessionRef, 'exit 7');
    final exited = await client.expect<ExitedMessage>();
    // The exit code the host reports is the child's, and a code it could not
    // collect stays null rather than becoming a zero.
    expect(exited.exitCode, 7);
    expect(exited.sessionId, 'local-a');
  });

  test('a second client sees the session listed and is refused the write token', () async {
    final owner = await LocalHostClient.connect(host.socketPath, 'pane-owner');
    addTearDown(owner.close);
    await owner.expect<WelcomeMessage>();
    owner.send(
      OpenMessage(
        requestId: owner.nextId(),
        sessionId: 'local-b',
        argv: probeShell,
        environment: const {},
        columns: 80,
        rows: 24,
      ),
    );
    final held = await owner.expect<AttachedMessage>();
    expect(held.holdsWriteToken, isTrue);

    final observer = await LocalHostClient.connect(host.socketPath, 'pane-observer');
    addTearDown(observer.close);
    await observer.expect<WelcomeMessage>();
    observer.send(ListMessage(observer.nextId()));
    final listed = await observer.expect<SessionsMessage>();
    expect(listed.summaries.map((s) => s.id), contains('local-b'));

    observer.send(
      AttachMessage(
        requestId: observer.nextId(),
        sessionId: 'local-b',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    final second = await observer.expect<AttachedMessage>();
    expect(second.holdsWriteToken, isFalse, reason: 'single writer, many readers');
    expect(second.writeHolder, 'pane-owner');

    owner.send(CloseMessage(owner.nextId(), 'local-b'));
    await owner.expect<ClosedMessage>();
  });
}
