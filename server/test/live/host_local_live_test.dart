@Tags(['live'])
library;

import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

import 'local_host_harness.dart';

/// The whole host on *this* machine: a real `serve`, a real unix domain socket
/// on Windows, a real ConPTY, and a client connecting straight to the socket.
/// Every `Duration` is a failure bound on a future, not a poll.
void main() {
  late LocalHost host;

  setUpAll(() async {
    host = await LocalHost.start(temporaryHome('karmashala-host-local'));
    expect(host.greeting, contains(host.socketPath));
    expect(
      host.greeting,
      contains(
        Platform.isWindows
            ? 'kernel32.dll'
            : Platform.isMacOS
            ? 'libSystem'
            : 'libc',
      ),
      reason:
          'the host reports which pty layer it measured, never which it assumed',
    );
    expect(host.greeting, contains('restored 0 session(s)'));
    // A real `serve` opened a store and counted its paired phones. Started as
    // the app starts it, so remote access is off until server.json turns it on
    // (2db93f96); a store that would not open says "companion unavailable".
    expect(
      host.greeting,
      contains('companion off'),
      reason: 'a store that would not open reports itself instead',
    );
    expect(host.greeting, contains('0 phone(s) paired'));
  });

  tearDownAll(() => host.kill());

  test(
    'a client reaches the socket, runs a shell, and reads its exit code',
    () async {
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
      expect(
        await client.output('karmashala'),
        isTrue,
        reason: client.tail(400),
      );

      client.type(attached.sessionRef, 'exit 7');
      final exited = await client.expect<ExitedMessage>();
      // The child's own code, and null rather than zero when it was not collected.
      expect(exited.exitCode, 7);
      expect(exited.sessionId, 'local-a');
    },
  );

  test(
    'a second client sees the session listed and is refused the write token',
    () async {
      final owner = await LocalHostClient.connect(
        host.socketPath,
        'pane-owner',
      );
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

      final observer = await LocalHostClient.connect(
        host.socketPath,
        'pane-observer',
      );
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
      expect(
        second.holdsWriteToken,
        isFalse,
        reason: 'single writer, many readers',
      );
      expect(second.writeHolder, 'pane-owner');

      owner.send(CloseMessage(owner.nextId(), 'local-b'));
      await owner.expect<ClosedMessage>();
    },
  );

  Future<void> ownsItsTerminal(LocalHost host) async {
    // 2026-09-24: `ps` showed no controlling tty for any child of the
    // installed host, and Claude Code in its panes never heard of a
    // resize. The in-process launcher gave its child one, so only the real
    // `serve` can answer this.
    final client = await LocalHostClient.connect(host.socketPath, 'pane-w');
    addTearDown(client.close);
    await client.expect<WelcomeMessage>();
    client.send(
      OpenMessage(
        requestId: client.nextId(),
        sessionId: 'local-winch',
        // An interactive zsh, as a pane runs: `/bin/sh` happened to keep its
        // terminal and hid the bug, zsh and Claude Code did not.
        argv: const [
          '/bin/zsh',
          '-f',
          '-i',
          '-c',
          r'TRAPWINCH() { echo winched }; echo "ctty=$(ps -o tty= -p $$)"; '
              r'echo ready; for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.3; done',
        ],
        environment: const {'TERM': 'xterm-256color'},
        columns: 80,
        rows: 24,
      ),
    );
    final attached = await client.expect<AttachedMessage>();
    expect(await client.output('ready'), isTrue, reason: client.tail(400));
    expect(client.tail(400), isNot(contains('ctty=??')));

    client.send(ResizeMessage(attached.sessionRef, 100, 30));
    expect(await client.output('winched'), isTrue, reason: client.tail(400));
  }

  test(
    'a session owns its terminal in the real host, so a resize reaches it',
    () => ownsItsTerminal(host),
    testOn: '!windows',
  );

  test('and in one started detached, as the app starts it', () async {
    final detached = await LocalHost.start(
      temporaryHome('karmashala-host-detached'),
      detached: true,
    );
    addTearDown(detached.kill);
    await ownsItsTerminal(detached);
  }, testOn: '!windows');
}
