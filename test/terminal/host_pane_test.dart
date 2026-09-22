import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/launch.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_host/protocol.dart';

import 'fake_host_access.dart';

/// A local pane whose process belongs to the session host.
///
/// The same fake machine the SSH pane is tested against, because it is the same
/// conversation: the point of the transport seam is that the pane cannot tell
/// which side of it it is on.
/// Lets the pane's own machinery finish.
///
/// The real delay is for `PtyOutputCoalescer`'s 16 ms watchdog, which is what
/// hands bytes to the terminal when there is no frame pump — a plain `test()`
/// has none. It is a bound on the app's batching, not a poll for a condition,
/// and it is the same helper the SSH pane's tests use.
Future<void> settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  const launch = PtyLaunch(
    executable: 'cmd.exe',
    arguments: ['/k'],
    workingDirectory: r'C:\work',
    environment: {'KARMASHALA_SESSION': 's1'},
  );

  HostTerminalInstance paneOn(PaneAccess access) {
    final instance = HostTerminalInstance(
      id: 'p1',
      title: 'Local',
      profileId: 'powershell',
      access: access,
      launch: launch,
      workingDirectory: r'C:\work',
    );
    instance.terminal.resize(120, 40);
    addTearDown(instance.dispose);
    return instance;
  }

  String screenOf(HostTerminalInstance pane) =>
      terminalTailLines(pane.terminal, lines: 200).join('\n');

  test('the pane opens the launch it was given, on the host', () async {
    final access = PaneAccess(readyDeployment());
    final pane = paneOn(access);
    await settle();

    final opened = access.channels.single.only<OpenMessage>();
    expect(opened.argv, ['cmd.exe', '/k']);
    expect(opened.workingDirectory, r'C:\work');
    expect(opened.environment['TERM'], 'xterm-256color');
    expect(
      opened.environment['KARMASHALA_SESSION'],
      's1',
      reason: "the launch's own variables cross with it",
    );
    // The pane's own id, not one the host invents, so the same pane finds the
    // same session after the app restarts.
    expect(opened.sessionId, 'karmashala_local_p1');
    expect(pane.liveness.value, PaneLiveness.live);
  });

  group('names the launch withholds', () {
    const withholding = PtyLaunch(
      executable: 'claude.exe',
      workingDirectory: r'C:\work',
      removedEnvironment: {'ANTHROPIC_API_KEY'},
    );

    HostTerminalInstance withholdingPaneOn(PaneAccess access) {
      final instance = HostTerminalInstance(
        id: 'p1',
        title: 'Claude',
        profileId: 'powershell',
        access: access,
        launch: withholding,
        workingDirectory: r'C:\work',
      );
      instance.terminal.resize(120, 40);
      addTearDown(instance.dispose);
      return instance;
    }

    test('cross to the host with the open', () async {
      final access = PaneAccess(readyDeployment());
      withholdingPaneOn(access);
      await settle();

      final opened = access.channels.single.only<OpenMessage>();
      expect(opened.removedEnvironment, {'ANTHROPIC_API_KEY'});
    });

    test(
      'an older host that cannot withhold them refuses the pane in words',
      () async {
        final access = PaneAccess(readyDeployment())
          ..predatesWithholding = true;
        final pane = withholdingPaneOn(access);
        await settle();

        // Unwrapped: the sentence is longer than the pane is wide.
        final screen = screenOf(pane).replaceAll('\n', '');
        expect(screen, contains('cannot leave ANTHROPIC_API_KEY out'));
        expect(screen, contains('Restart the session host'));
        expect(screen, contains('0x14'), reason: 'what the host said, quoted');
        expect(access.liveSessions, isEmpty, reason: 'nothing was started');
      },
    );
  });

  test(
    'bytes from the host reach the buffer, and typing reaches the host',
    () async {
      final access = PaneAccess(readyDeployment());
      final pane = paneOn(access);
      await settle();

      access.channels.single.pushOutput(0, 'C:\\work> hello from the host\r\n');
      await settle();
      expect(screenOf(pane), contains('hello from the host'));

      pane.terminal.textInput('dir\r');
      await settle();
      final typed = access.channels.single.received
          .whereType<InputMessage>()
          .single;
      expect(String.fromCharCodes(typed.bytes), 'dir\r');
    },
  );

  test('an exit code the host reports is the pane\'s exit code', () async {
    final access = PaneAccess(readyDeployment());
    final pane = paneOn(access);
    await settle();

    access.channels.single.push(
      ExitedMessage(
        sessionRef: 1,
        sessionId: 'karmashala_local_p1',
        exitCode: 7,
        reason: 'exited 7',
        observedAt: DateTime.utc(2026),
      ),
    );
    await settle();

    expect(pane.exitCode, 7);
    expect(pane.liveness.value, PaneLiveness.exited);
    expect(screenOf(pane), contains('exited with code 7'));
  });

  test('a code the host could not collect stays unknown, never zero', () async {
    final access = PaneAccess(readyDeployment());
    final pane = paneOn(access);
    await settle();

    access.channels.single.push(
      ExitedMessage(
        sessionRef: 1,
        sessionId: 'karmashala_local_p1',
        exitCode: null,
        reason: 'the host stopped while it was running',
        observedAt: DateTime.utc(2026),
      ),
    );
    await settle();

    expect(pane.exitCode, isNull);
    expect(screenOf(pane), contains('exit code unknown'));
    expect(screenOf(pane), contains('the host stopped while it was running'));
  });

  test(
    'a host that is not ready ends the pane in words, and never dials',
    () async {
      final access = PaneAccess(
        HostDeployment(
          status: HostDeploymentStatus.noBinary,
          observedAt: DateTime.utc(2026),
          reason: 'No karmashala_host.exe beside this app.',
        ),
      );
      final pane = paneOn(access);
      await settle();

      expect(
        access.channels,
        isEmpty,
        reason: 'there is no fallback to slide into',
      );
      expect(pane.liveness.value, PaneLiveness.exited);
      expect(
        screenOf(pane),
        contains('No karmashala_host.exe beside this app.'),
      );
    },
  );

  test(
    'a host we had to start says the earlier session is not running',
    () async {
      final access = PaneAccess(readyDeployment(restarted: true));
      final pane = paneOn(access);
      await settle();
      expect(screenOf(pane), contains('has been started'));
      expect(screenOf(pane), contains('no longer running'));
    },
  );

  test(
    'closing the pane is a disconnect: the session is never closed',
    () async {
      final access = PaneAccess(readyDeployment());
      final pane = paneOn(access);
      await settle();
      final channel = access.channels.single;

      pane.dispose();
      await pane.reaped;

      expect(channel.closed, isTrue);
      expect(
        channel.received.whereType<CloseMessage>(),
        isEmpty,
        reason: 'a session outliving its pane is the whole point of the host',
      );
    },
  );

  test(
    'a resumed session that died with its host is cleared away once shown',
    () async {
      final access = PaneAccess(readyDeployment())
        ..liveSessions.add('karmashala_local_p1');
      final pane = paneOn(access);
      await settle();

      final channel = access.channels.single;
      expect(channel.received.whereType<AttachMessage>(), hasLength(1));
      expect(channel.received.whereType<OpenMessage>(), isEmpty);

      channel
        ..pushOutput(0, 'what the agent was doing\r\n')
        ..push(
          ExitedMessage(
            sessionRef: 1,
            sessionId: 'karmashala_local_p1',
            exitCode: null,
            reason:
                'the host that owned this session stopped while it was running',
            observedAt: DateTime.utc(2026),
          ),
        );
      await settle();

      expect(screenOf(pane), contains('what the agent was doing'));
      // Shown, then let go: the record is what a person came back for, and
      // keeping it would make every later start of this pane replay a corpse.
      expect(channel.only<CloseMessage>().sessionId, 'karmashala_local_p1');
    },
  );

  test('a resumed session that really exited is left alone', () async {
    final access = PaneAccess(readyDeployment())
      ..liveSessions.add('karmashala_local_p1');
    final pane = paneOn(access);
    await settle();

    access.channels.single.push(
      ExitedMessage(
        sessionRef: 1,
        sessionId: 'karmashala_local_p1',
        exitCode: 0,
        reason: 'exited 0',
        observedAt: DateTime.utc(2026),
      ),
    );
    await settle();

    expect(pane.exitCode, 0);
    expect(
      access.channels.single.received.whereType<CloseMessage>(),
      isEmpty,
      reason:
          'the host keeps an ended session so a late pane can read its code',
    );
  });

  test(
    'a resumed session is not printed twice over the app\'s own record',
    () async {
      final access = PaneAccess(readyDeployment())
        ..liveSessions.add('karmashala_local_p1')
        ..resumedTotalBytes = 26;
      final pane = HostTerminalInstance(
        id: 'p1',
        title: 'Local',
        profileId: 'powershell',
        access: access,
        launch: launch,
        // What the app stored when it last closed — the same output the host
        // still holds in its ring.
        restoredScrollback: 'a build that was running\r\n',
      );
      addTearDown(pane.dispose);
      pane.terminal.resize(120, 40);
      await settle();

      access.channels.single.pushOutput(
        0,
        'a build that was running\r\nand now this\r\n',
      );
      await settle();

      final screen = screenOf(pane);
      expect(
        'a build that was running'.allMatches(screen).length,
        1,
        reason: 'the host replayed it; the stored copy is the one that goes',
      );
      expect(screen, contains('and now this'));
    },
  );

  test(
    'a pane with no stored history keeps every byte the host replays',
    () async {
      final access = PaneAccess(readyDeployment())
        ..liveSessions.add('karmashala_local_p1');
      final pane = paneOn(access);
      await settle();

      access.channels.single.pushOutput(0, 'only the host has this\r\n');
      await settle();
      expect(screenOf(pane), contains('only the host has this'));
    },
  );

  test('a resize reaches the host', () async {
    final access = PaneAccess(readyDeployment());
    final pane = paneOn(access);
    await settle();

    pane.terminal.resize(100, 30);
    await settle();
    final resized = access.channels.single.received
        .whereType<ResizeMessage>()
        .last;
    expect((resized.columns, resized.rows), (100, 30));
  });

  test(
    'a session found at another size is told the size of the pane',
    () async {
      // The host kept the session at the grid its last pane had. This pane was
      // laid out before the link existed, so no resize of its own will say so.
      final access = PaneAccess(readyDeployment())
        ..liveSessions.add('karmashala_local_p1');
      paneOn(access);
      await settle();

      final resized = access.channels.single.all<ResizeMessage>().toList();
      expect(
        [for (final r in resized) (r.sessionRef, r.columns, r.rows)],
        [(1, 120, 40)],
      );
    },
  );

  test(
    'a session opened at the size of the pane is not resized again',
    () async {
      final access = PaneAccess(readyDeployment());
      paneOn(access);
      await settle();

      expect(access.channels.single.all<ResizeMessage>(), isEmpty);
    },
  );

  test('an agent pane keeps its session id across pane replacement', () async {
    final access = PaneAccess(readyDeployment());
    final pane = HostTerminalInstance(
      id: 'p9',
      title: 'Claude',
      profileId: 'agent',
      access: access,
      launch: launch,
      agentLaunch: const AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        sessionId: 'sess-1',
      ),
    );
    addTearDown(pane.dispose);
    expect(pane.hostSessionId, 'karmashala_sess-1');
  });
}
