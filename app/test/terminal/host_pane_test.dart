import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
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
  /// What the server's `terminals.open` does for [sessionId] on the fake
  /// machine: answers a running session as adopted, replaces an ended record,
  /// starts one otherwise — and records the grid it was asked at.
  final asked = <(String, int, int)>[];
  TerminalOpener openerOn(PaneAccess access, String sessionId) =>
      (columns, rows) async {
        asked.add((sessionId, columns, rows));
        final adopted = access.liveSessions.contains(sessionId);
        if (!adopted) access.grids[sessionId] = (columns, rows);
        access.endedSessions.remove(sessionId);
        access.liveSessions.add(sessionId);
        return (
          sessionId: sessionId,
          adopted: adopted,
          shellIntegration: false,
        );
      };

  setUp(asked.clear);

  HostTerminalInstance paneOn(PaneAccess access) {
    final instance = HostTerminalInstance(
      id: 'p1',
      title: 'Local',
      profileId: 'powershell',
      access: access,
      sessionId: 'karmashala_local_p1',
      opener: openerOn(access, 'karmashala_local_p1'),
      workingDirectory: r'C:\work',
      redialDelays: const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 10),
        Duration(milliseconds: 10),
      ],
    );
    instance.terminal.resize(120, 40);
    addTearDown(instance.dispose);
    return instance;
  }

  String screenOf(HostTerminalInstance pane) =>
      terminalTailLines(pane.terminal, lines: 200).join('\n');

  test('the pane asks the server for its terminal, then attaches to it',
      () async {
    final access = PaneAccess(readyDeployment());
    final pane = paneOn(access);
    await settle();

    // The server builds the launch (slice 5a): the pane only names the
    // session its own id gives, at its own grid.
    expect(asked, [('karmashala_local_p1', 120, 40)]);
    final channel = access.channels.single;
    expect(channel.all<OpenMessage>(), isEmpty);
    expect(channel.only<AttachMessage>().sessionId, 'karmashala_local_p1');
    expect(pane.liveness.value, PaneLiveness.live);
  });

  test('a refusal from the server ends the pane in its words', () async {
    final access = PaneAccess(readyDeployment());
    final pane = HostTerminalInstance(
      id: 'p1',
      title: 'Local',
      profileId: 'powershell',
      access: access,
      sessionId: 'karmashala_local_p1',
      opener: (_, _) async =>
          throw StateError('this server does not offer the shell "cmd"'),
    );
    addTearDown(pane.dispose);
    pane.terminal.resize(120, 40);
    await settle();

    expect(pane.liveness.value, PaneLiveness.exited);
    expect(
      screenOf(pane).replaceAll('\n', ''),
      contains('does not offer the shell "cmd"'),
    );
    expect(access.channels.single.all<AttachMessage>(), isEmpty);
  });

  group('a run the server hosts (attach only, slice 3d)', () {
    HostTerminalInstance attachingPaneOn(PaneAccess access) {
      final instance = HostTerminalInstance(
        id: 'hosted-r1',
        title: 'run · app',
        profileId: 'powershell',
        access: access,
        sessionId: 'karmashala_local_hosted-r1',
      );
      instance.terminal.resize(120, 40);
      addTearDown(instance.dispose);
      return instance;
    }

    test('attaches to the session the server started', () async {
      final access = PaneAccess(readyDeployment());
      access.liveSessions.add('karmashala_local_hosted-r1');
      final pane = attachingPaneOn(access);
      await settle();

      final attach = access.channels.single.only<AttachMessage>();
      expect(attach.sessionId, 'karmashala_local_hosted-r1');
      expect(access.channels.single.all<OpenMessage>(), isEmpty);
      expect(pane.liveness.value, PaneLiveness.live);
    });

    test('a session that is gone ends the pane; nothing is started in its '
        'place', () async {
      final access = PaneAccess(readyDeployment());
      final pane = attachingPaneOn(access);
      await settle();

      expect(access.channels.single.all<OpenMessage>(), isEmpty);
      expect(pane.liveness.value, PaneLiveness.exited);
      expect(pane.exitCode, isNull);
    });
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
        sessionId: 'karmashala_local_p1',
        opener: openerOn(access, 'karmashala_local_p1'),
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

  group('a link that closes under a live pane', () {
    test('is redialled, and the session resumes from the byte the pane '
        'stopped at', () async {
      final access = PaneAccess(readyDeployment());
      final pane = paneOn(access);
      await settle();
      final first = access.channels.single;
      first.pushOutput(0, 'before the drop\r\n');
      await settle();

      await first.close();
      await settle();

      expect(access.channels, hasLength(2), reason: 'nothing reached it again');
      final second = access.channels.last;
      final attach = second.only<AttachMessage>();
      expect(attach.sessionId, 'karmashala_local_p1');
      expect(attach.sinceOffset, 'before the drop\r\n'.length);
      expect(second.all<OpenMessage>(), isEmpty, reason: 'a second process');
      expect(pane.liveness.value, PaneLiveness.live);
      expect(screenOf(pane), contains('before the drop'));
      expect(screenOf(pane), contains('reconnecting'));
    });

    test('a host that answers but is not ready is waited for, never '
        'dialled, and the pane says so when it gives up', () async {
      final access = PaneAccess(readyDeployment());
      final pane = paneOn(access);
      await settle();
      access.reconnect(
        nowReporting: HostDeployment(
          status: HostDeploymentStatus.unknown,
          observedAt: DateTime.utc(2026, 9, 23),
          reason: 'the handshake ran out of time',
        ),
      );

      await access.channels.single.close();
      await settle();

      expect(access.channels, hasLength(1));
      expect(access.deploymentAsks, 4, reason: 'one per bounded attempt');
      expect(screenOf(pane).replaceAll('\n', ''), contains('could not reach'));
    });

    test('a host that died and was replaced ends the pane with no code, and '
        'nothing is opened in the new one', () async {
      final access = PaneAccess(readyDeployment());
      final pane = paneOn(access);
      await settle();
      final first = access.channels.single;
      first.pushOutput(0, 'working\r\n');
      await settle();

      // The host went, and took its session with it; another answers now.
      access.hostPid = 12;
      access.liveSessions.clear();
      await first.close();
      await settle();

      expect(access.channels, hasLength(2));
      final second = access.channels.last;
      expect(second.all<AttachMessage>(), isEmpty);
      expect(second.all<OpenMessage>(), isEmpty, reason: 'a fresh session');
      expect(pane.liveness.value, PaneLiveness.exited);
      expect(pane.exitCode, isNull, reason: 'never a zero');
      expect(
        screenOf(pane).replaceAll('\n', ''),
        contains('the session host stopped'),
      );
      expect(screenOf(pane), contains('working'), reason: 'what it showed');
    });

    test('the same host no longer holding the session ends the pane; it is '
        'never opened again in its place', () async {
      final access = PaneAccess(readyDeployment());
      final pane = paneOn(access);
      await settle();
      final first = access.channels.single;

      access.liveSessions.clear();
      await first.close();
      await settle();

      final second = access.channels.last;
      expect(second.only<AttachMessage>().sessionId, 'karmashala_local_p1');
      expect(second.all<OpenMessage>(), isEmpty);
      expect(pane.liveness.value, PaneLiveness.exited);
      expect(pane.exitCode, isNull);
      expect(
        screenOf(pane).replaceAll('\n', ''),
        contains('no longer holds this session'),
      );
    });

    test('a pane closed meanwhile dials nothing', () async {
      final access = PaneAccess(readyDeployment());
      final pane = paneOn(access);
      await settle();
      final first = access.channels.single;
      pane.dispose();
      await first.close();
      await settle();
      expect(access.channels, hasLength(1));
    });
  });

  group('an agent pane attaching fresh to a session the host holds', () {
    // 26 bytes, so the fake's resumed total covers exactly this replay.
    const replay = 'OLD-WIDTH-FRAME-DEBRIS!\r\n';

    HostTerminalInstance agentPane(
      PaneAccess access, {
      String? stored,
      required int columns,
      required int rows,
    }) {
      final pane = HostTerminalInstance(
        id: 'p1',
        title: 'Claude',
        profileId: 'agent',
        access: access,
        sessionId: 'karmashala_sess-1',
        opener: openerOn(access, 'karmashala_sess-1'),
        agentLaunch: const AgentPaneLaunch(
          agentId: 'claudeCode',
          executable: 'claude',
          sessionId: 'sess-1',
        ),
        restoredScrollback: stored,
      );
      addTearDown(pane.dispose);
      pane.terminal.resize(columns, rows);
      return pane;
    }

    PaneAccess holding() => PaneAccess(readyDeployment())
      ..liveSessions.add('karmashala_sess-1')
      ..resumedTotalBytes = replay.length;

    test('the replay is not drawn; the app\'s own record stays', () async {
      final access = holding();
      final pane = agentPane(
        access,
        stored: 'what the pane showed when the app closed\r\n',
        columns: 80,
        rows: 24,
      );
      await settle();
      final channel = access.channels.single;
      channel
        ..pushOutput(0, replay)
        ..pushOutput(replay.length, 'what it draws now\r\n');
      await settle();

      final screen = screenOf(pane);
      expect(screen, isNot(contains('DEBRIS')));
      expect(screen, contains('what the pane showed when the app closed'));
      expect(screen, contains('what it draws now'));
      expect(channel.all<ResizeMessage>(), isEmpty, reason: 'nothing to redo');
    });

    test('at another size the record stays, and the size is sent', () async {
      final access = holding();
      final pane = agentPane(
        access,
        stored: 'stored at the old width\r\n',
        columns: 120,
        rows: 40,
      );
      await settle();
      final channel = access.channels.single;
      channel.pushOutput(0, replay);
      await settle();

      expect(
        screenOf(pane),
        contains('stored at the old width'),
        reason: 'never cleared: the agent does not reprint its conversation',
      );
      expect(screenOf(pane), isNot(contains('DEBRIS')));
      final resize = channel.only<ResizeMessage>();
      expect((resize.columns, resize.rows), (120, 40));
    });

    test('with nothing stored, the replay is all there is to show', () async {
      final access = holding();
      final pane = agentPane(access, columns: 80, rows: 24);
      await settle();
      final channel = access.channels.single;
      channel.pushOutput(0, replay);
      await settle();

      expect(screenOf(pane), contains('DEBRIS'));
      expect(channel.all<ResizeMessage>(), isEmpty, reason: 'no nudge');
    });
  });

  group('the pane\'s own notes', () {
    tearDown(() => HostTerminalInstance.writesNotesToTerminal = true);

    test('are written into the terminal in a debug build', () async {
      HostTerminalInstance.writesNotesToTerminal = true;
      final pane = paneOn(PaneAccess(readyDeployment()));
      await settle();
      expect(screenOf(pane), contains('bytes so far'));
    });

    test('stay out of the program\'s screen in a release one', () async {
      HostTerminalInstance.writesNotesToTerminal = false;
      final pane = paneOn(PaneAccess(readyDeployment()));
      await settle();
      expect(screenOf(pane), isNot(contains('bytes so far')));
      expect(screenOf(pane), isNot(contains('karmashala_local_p1')));
      expect(pane.liveness.value, PaneLiveness.live);
    });
  });
}
