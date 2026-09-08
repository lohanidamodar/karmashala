
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/ssh/data/host_session_access.dart';
import 'package:karmashala/src/features/ssh/data/ssh_connection.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/features/ssh/data/known_host_dao.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_key_verifier.dart';
import 'package:karmashala/src/features/ssh/domain/host_deployment.dart';
import 'package:karmashala/src/features/ssh/domain/ssh_host.dart';
import 'package:karmashala/src/features/terminal/data/ssh_terminal_instance.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:xterm2/xterm.dart';

import 'fake_host_access.dart';
import 'package:karmashala_host/protocol.dart';

final _host = SshHost(
  id: 'h1',
  name: 'box',
  host: 'box.example',
  port: 22,
  username: 'me',
  authMethod: SshAuthMethod.password,
  createdAt: DateTime.utc(2026),
);

HostDeployment ready({bool restarted = false}) => readyDeployment(restarted: restarted);

/// A pane with a viewport wide enough that a notice is not wrapped by the
/// terminal — an assertion about a sentence should not depend on where 80
/// columns happened to fall.
SshTerminalInstance paneWith({HostSessionAccess? access}) =>
    _sized(_paneWith(access: access));

SshTerminalInstance _sized(SshTerminalInstance pane) {
  pane.terminal.resize(200, 60);
  return pane;
}

SshTerminalInstance _paneWith({HostSessionAccess? access}) => SshTerminalInstance(
  id: 'p1',
  title: 'box',
  profileId: 'default',
  host: _host,
  // Never dialled: every test here takes the host path or the fallback notice,
  // both of which stop before `connection.client()`.
  connection: SshConnection(
    host: _host,
    verifier: SshHostKeyVerifier(
      knownHosts: KnownHostDao(_UnusedDatabase()),
      host: _host.host,
      port: _host.port,
      clock: const SystemClock(),
    ),
  ),
  hostAccess: access,
);

/// The pane's whole visible buffer as plain text. terminalTailLines reads only
/// the bottom rows on purpose; these assertions are about notices that may have
/// scrolled, so they read all of it.
String screenText(Terminal terminal) => terminalTailLines(terminal, lines: 200).join('\n');

/// Lets the pane's own machinery finish.
///
/// The real delay is for PtyOutputCoalescer's 16 ms watchdog, which is what
/// hands bytes to the terminal when there is no frame pump — a plain `test()`
/// has none. It is a bound on the app's batching, not a poll for a condition.
Future<void> settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class _UnusedDatabase implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('the pane tests never reach the database');
}

void main() {
  test('a ready host is used, and the pane opens its own session id', () async {
    final access = PaneAccess(ready());
    final pane = paneWith(access: access);
    await settle();

    expect(access.execs.single, contains('karmashala_host-0.1.0-linux-x64 attach'));
    final channel = access.channels.single;
    expect(channel.only<HelloMessage>().clientId, 'pane-p1');
    // Attach before open: on a reconnect the session is already there.
    expect(channel.only<AttachMessage>().sessionId, 'karmashala_h1_p1');
    expect(channel.only<OpenMessage>().sessionId, 'karmashala_h1_p1');
    expect(channel.only<OpenMessage>().argv, ['/bin/sh', '-l']);

    pane.dispose();
  });

  test("the child's bytes reach the terminal, sequences and all", () async {
    final access = PaneAccess(ready());
    final pane = paneWith(access: access);
    await settle();

    access.channels.single.pushOutput(0, 'hello from the host\r\n');
    await settle();

    expect(nonBlankLineCount(pane.terminal), greaterThan(0));
    expect(screenText(pane.terminal), contains('hello from the host'));
    pane.dispose();
  });

  test('typing goes out as input, not down the tmux channel', () async {
    final access = PaneAccess(ready());
    final pane = paneWith(access: access);
    await settle();

    pane.terminal.onOutput!('ls\n');
    await settle();

    expect(
      String.fromCharCodes(access.channels.single.only<InputMessage>().bytes),
      'ls\n',
    );
    pane.dispose();
  });

  test('closing the pane disconnects and never asks the host to close', () async {
    final access = PaneAccess(ready());
    final pane = paneWith(access: access);
    await settle();

    pane.dispose();
    await settle();

    expect(access.channels.single.closed, isTrue);
    expect(
      access.channels.single.received.whereType<CloseMessage>(),
      isEmpty,
      reason: 'a closed pane must leave the session running',
    );
  });

  group('falling back', () {
    test('an unsupported machine says so in the pane, in words', () async {
      final access = PaneAccess(
        HostDeployment(
          status: HostDeploymentStatus.unsupportedPlatform,
          observedAt: DateTime.utc(2026),
          reason: 'fake.example runs musl libc.',
        ),
      );
      final pane = paneWith(access: access);
      await settle();

      final text = screenText(pane.terminal);
      expect(text, contains('session host unavailable'));
      expect(text, contains('musl'));
      expect(text, contains('tmux'));
      expect(access.execs, isEmpty, reason: 'nothing is attempted on the host');
      pane.dispose();
    });

    test('a host that cannot be started says which, and still falls back', () async {
      final access = PaneAccess(
        HostDeployment(
          status: HostDeploymentStatus.cannotStart,
          observedAt: DateTime.utc(2026),
          reason: 'the host was installed and started but never answered `hello`.',
        ),
      );
      final pane = paneWith(access: access);
      await settle();

      expect(screenText(pane.terminal), contains('never answered'));
      expect(access.execs, isEmpty);
      pane.dispose();
    });

    test('no reading at all is silent: unknown is not a negative answer', () async {
      final pane = paneWith();
      await settle();

      expect(screenText(pane.terminal), isNot(contains('session host unavailable')));
      pane.dispose();
    });
  });

  group('ending', () {
    test('an exit code is shown as itself', () async {
      final access = PaneAccess(ready());
      final pane = paneWith(access: access);
      await settle();

      access.channels.single.push(
        ExitedMessage(
          sessionRef: 1,
          sessionId: 'karmashala_h1_p1',
          exitCode: 7,
          reason: 'exited 7',
          observedAt: DateTime.utc(2026),
        ),
      );
      await settle();

      expect(pane.exitCode, 7);
      expect(screenText(pane.terminal), contains('exited with code 7'));
      pane.dispose();
    });

    test('an unknown exit code is never rendered as a zero', () async {
      final access = PaneAccess(ready());
      final pane = paneWith(access: access);
      await settle();

      access.channels.single.push(
        ExitedMessage(
          sessionRef: 1,
          sessionId: 'karmashala_h1_p1',
          exitCode: null,
          reason: 'ended, exit code unknown (the child could not be reaped)',
          observedAt: DateTime.utc(2026),
        ),
      );
      await settle();

      expect(pane.exitCode, isNull);
      final text = screenText(pane.terminal);
      expect(text, contains('exit code unknown'));
      expect(text, isNot(contains('exited with code 0')));
      pane.dispose();
    });

    test('a host that had to be restarted says its sessions are gone', () async {
      final access = PaneAccess(ready(restarted: true));
      final pane = paneWith(access: access);
      await settle();

      final text = screenText(pane.terminal);
      expect(text, contains('was not running and has been restarted'));
      expect(text, contains('sessions it held before are gone'));
      expect(access.execs, hasLength(1), reason: 'and it still runs the pane');
      pane.dispose();
    });

    test('a host that was already running says nothing about restarts', () async {
      final access = PaneAccess(ready());
      final pane = paneWith(access: access);
      await settle();

      expect(screenText(pane.terminal), isNot(contains('restarted')));
      pane.dispose();
    });

    test('a dropped link says the session survives, and where it will resume', () async {
      final access = PaneAccess(ready());
      final pane = paneWith(access: access);
      await settle();
      access.channels.single.pushOutput(0, 'abcdef');
      await settle();

      await access.channels.single.close();
      await settle();

      final text = screenText(pane.terminal);
      expect(text, contains('still running there'));
      expect(text, contains('byte 6'));
      pane.dispose();
    });
  });

  group('reconnecting', () {
    test('the pool coming back re-dials and attaches from the last byte seen', () async {
      final access = PaneAccess(ready());
      final pane = paneWith(access: access);
      await settle();
      access.channels.single.pushOutput(0, 'before the drop');
      await settle();
      await access.channels.single.close();
      await settle();

      access.reconnect();
      await settle();

      expect(access.channels, hasLength(2), reason: 'a second link, not a second pane');
      final resumed = access.channels.last;
      // Attach, never open: the session is already there.
      expect(resumed.received.whereType<OpenMessage>(), isEmpty);
      expect(resumed.only<AttachMessage>().sinceOffset, 15);
      expect(resumed.only<AttachMessage>().sessionId, 'karmashala_h1_p1');
      expect(screenText(pane.terminal), contains('resuming from byte 15'));
      pane.dispose();
    });

    test('nothing re-dials while the link is still up', () async {
      final access = PaneAccess(ready());
      final pane = paneWith(access: access);
      await settle();

      access.reconnect();
      await settle();

      expect(access.channels, hasLength(1));
      pane.dispose();
    });

    test('a host restarted while the pane was away says the sessions are gone', () async {
      final access = PaneAccess(ready());
      final pane = paneWith(access: access);
      await settle();
      access.channels.single.pushOutput(0, 'abc');
      await settle();
      await access.channels.single.close();
      await settle();

      access.reconnect(nowReporting: ready(restarted: true));
      await settle();

      expect(
        screenText(pane.terminal),
        contains('was restarted while this pane was away'),
      );
      pane.dispose();
    });

    test('a machine that came back without a usable host falls back, in words', () async {
      final access = PaneAccess(ready());
      final pane = paneWith(access: access);
      await settle();
      await access.channels.single.close();
      await settle();

      access.reconnect(
        nowReporting: HostDeployment(
          status: HostDeploymentStatus.cannotStart,
          observedAt: DateTime.utc(2026),
          reason: 'the host would not start after the reboot.',
        ),
      );
      await settle();

      expect(screenText(pane.terminal), contains('no longer available'));
      expect(screenText(pane.terminal), contains('would not start after the reboot'));
      expect(access.channels, hasLength(1), reason: 'nothing was dialled');
      pane.dispose();
    });

    test('a pane that ended does not re-dial when the connection returns', () async {
      final access = PaneAccess(ready());
      final pane = paneWith(access: access);
      await settle();
      access.channels.single.push(
        ExitedMessage(
          sessionRef: 1,
          sessionId: 'karmashala_h1_p1',
          exitCode: 0,
          reason: 'exited 0',
          observedAt: DateTime.utc(2026),
        ),
      );
      await settle();

      access.reconnect();
      await settle();

      expect(access.channels, hasLength(1));
      pane.dispose();
    });
  });

  test('a reading that cannot be taken falls back rather than claiming anything', () async {
    final access = PaneAccess(ready())..deploymentError = StateError('the pool is gone');
    final pane = paneWith(access: access);
    await settle();

    final text = screenText(pane.terminal);
    expect(text, contains('could not ask ${_host.address} about its session host'));
    expect(text, contains('tmux'));
    expect(access.execs, isEmpty);
    pane.dispose();
  });
}
