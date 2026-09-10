
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/ssh/data/host_session_access.dart';
import 'package:karmashala/src/features/ssh/data/ssh_connection.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/ssh/data/known_host_dao.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_key_verifier.dart';
import 'package:karmashala/src/features/ssh/domain/host_deployment.dart';
import 'package:karmashala/src/features/ssh/domain/ssh_host.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
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
SshTerminalInstance paneWith({
  HostSessionAccess? access,
  String? restoredScrollback,
  AgentPaneLaunch? agentLaunch,
}) => _sized(
  _paneWith(
    access: access,
    restoredScrollback: restoredScrollback,
    agentLaunch: agentLaunch,
  ),
);

SshTerminalInstance _sized(SshTerminalInstance pane) {
  pane.terminal.resize(200, 60);
  return pane;
}

SshTerminalInstance _paneWith({
  HostSessionAccess? access,
  String? restoredScrollback,
  AgentPaneLaunch? agentLaunch,
}) => SshTerminalInstance(
  agentLaunch: agentLaunch,
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
  restoredScrollback: restoredScrollback,
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

  group('a session already living in tmux', () {
    test('keeps attaching through tmux, and nothing is deployed for it', () async {
      final access = PaneAccess(ready())..tmuxSessions.add('karmashala_h1_p1');
      final pane = paneWith(access: access);
      await settle();

      // The whole point: the owner had an agent running in one of these while
      // this app was deciding to "upgrade" the pane to the session host, which
      // would have opened a second, empty session under the same name.
      expect(access.execs, isEmpty);
      expect(
        access.deploymentAsks,
        0,
        reason: 'a pane staying with tmux does not cost the machine an upload',
      );
      final text = screenText(pane.terminal);
      expect(text, contains('karmashala_h1_p1'));
      expect(text, contains('already running under tmux'));
      pane.dispose();
    });

    test("an agent's session is found under the name tmux knows it by", () async {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        sessionId: '074b5189-c547-4979-8bb5-790b1343f938',
      );
      final access = PaneAccess(ready())
        ..tmuxSessions.add('karmashala_074b5189-c547-4979-8bb5-790b1343f938');
      final pane = paneWith(access: access, agentLaunch: launch);
      await settle();

      expect(access.execs, isEmpty);
      expect(screenText(pane.terminal), contains('already running under tmux'));
      pane.dispose();
    });

    test('a resume whose tmux session is gone takes the host', () async {
      final access = PaneAccess(ready())..tmuxSessions.add('karmashala_h1_someone_else');
      final pane = paneWith(access: access);
      await settle();

      expect(access.tmuxAsks, 1);
      expect(access.execs.single, contains('attach'));
      expect(screenText(pane.terminal), contains('session host 0.1.0'));
      pane.dispose();
    });

    test('a machine that will not say stays on tmux: unknown is not "no"', () async {
      final access = PaneAccess(ready())..tmuxUnknown = true;
      final pane = paneWith(access: access);
      await settle();

      expect(access.execs, isEmpty);
      expect(screenText(pane.terminal), contains('did not say whether'));
      pane.dispose();
    });
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

  group('a restored pane and the host both hold the same history', () {
    test('a resumed session is not printed twice over the app\'s own record',
        () async {
      final access = PaneAccess(ready())
        ..liveSessions.add('karmashala_h1_p1')
        ..resumedTotalBytes = 26;
      final pane = paneWith(
        access: access,
        // What the app stored when it last closed — the same output the host
        // still holds in its ring.
        restoredScrollback: 'a build that was running\r\n',
      );
      await settle();

      access.channels.single.pushOutput(
        0,
        'a build that was running\r\nand now this\r\n',
      );
      await settle();

      final screen = screenText(pane.terminal);
      expect(
        'a build that was running'.allMatches(screen).length,
        1,
        reason: 'the host replayed it; the stored copy is the one that goes',
      );
      expect(screen, contains('and now this'));
      pane.dispose();
    });

    test('a pane with no stored history keeps every byte the host replays',
        () async {
      final access = PaneAccess(ready())..liveSessions.add('karmashala_h1_p1');
      final pane = paneWith(access: access);
      await settle();

      access.channels.single.pushOutput(0, 'only the host has this\r\n');
      await settle();

      expect(screenText(pane.terminal), contains('only the host has this'));
      pane.dispose();
    });

    test('a first run keeps its restored text — nothing replayed it', () async {
      // No live session on the host, so this pane OPENS one: there is no
      // second record, and clearing here would throw the only one away.
      final access = PaneAccess(ready());
      final pane = paneWith(
        access: access,
        restoredScrollback: 'what it said last time\r\n',
      );
      await settle();

      expect(screenText(pane.terminal), contains('what it said last time'));
      pane.dispose();
    });
  });

  group('the notice both routes print', () {
    test('a code nobody collected is never a zero', () {
      // The tmux path used to read dartssh2's missing status as `?? 0` and
      // announce a success nobody observed. One spelling now, and it cannot
      // say "0" for a code it does not have.
      final notice = remoteExitNotice(null);
      expect(notice, contains('exit code unknown'));
      expect(notice, isNot(contains('code 0')));
      expect(notice, isNot(contains('exited with')));
    });

    test('a code that was collected is shown as itself', () {
      expect(remoteExitNotice(7), contains('exited with code 7'));
      expect(remoteExitNotice(0), contains('exited with code 0'));
    });

    test('the host\'s reason rides along when there is one', () {
      expect(
        remoteExitNotice(null, reason: 'the child could not be reaped'),
        contains('unknown (the child could not be reaped)'),
      );
      // And nothing is invented for the route that has none.
      expect(remoteExitNotice(null, reason: ''), isNot(contains('(')));
    });
  });
}
