import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/terminal/data/ssh_terminal_instance.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/launch_context.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';

ExecutionEnvironment _wsl(String distro) => ExecutionEnvironment(
  id: 'wsl:$distro',
  name: distro,
  kind: EnvironmentKind.wsl,
  wslDistribution: distro,
  createdAt: DateTime.utc(2026),
);

void main() {
  group('on a Windows host', () {
    test('offers the two host shells and every distribution', () {
      final profiles = terminalProfilesFor([_wsl('Ubuntu')]);

      expect(
        profiles.map((p) => p.id),
        ['powershell', 'cmd', 'wsl:Ubuntu'],
      );
    });
  });

  group('on a POSIX host', () {
    test('offers the installed shells, login shell first', () {
      // PowerShell and Command Prompt were offered on every host, so a Mac's
      // settings page listed two shells it does not have — and picking either
      // changed nothing, because the launch path ignored the profile off
      // Windows and opened $SHELL regardless.
      final profiles = terminalProfilesFor(
        const [],
        hostIsWindows: false,
        loginShell: '/bin/zsh',
        shells: ['/bin/bash', '/bin/zsh', '/opt/homebrew/bin/fish'],
      );

      expect(profiles.map((p) => p.label), [
        'zsh (login shell)',
        'bash',
        'fish',
      ]);
      expect(profiles.first.id, 'posix:/bin/zsh');
      expect(profiles.every((p) => p.shell == TerminalShell.posix), isTrue);
    });

    test('a machine whose shells could not be listed still gets one', () {
      final profiles = terminalProfilesFor(
        const [],
        hostIsWindows: false,
        loginShell: '/bin/zsh',
      );

      expect(profiles.single.posixShellPath, '/bin/zsh');
    });

    test('and with no login shell either, falls back to sh', () {
      final profiles = terminalProfilesFor(const [], hostIsWindows: false);

      expect(profiles.single.posixShellPath, '/bin/sh');
    });

    test('a login shell missing from /etc/shells is still not lost', () {
      // chsh validates against /etc/shells, but a shell can be set by other
      // means; the one the user is actually in has to be offered.
      final profiles = terminalProfilesFor(
        const [],
        hostIsWindows: false,
        loginShell: '/usr/local/bin/nu',
        shells: ['/bin/zsh'],
      );

      expect(
        profiles.map((p) => p.posixShellPath),
        contains('/usr/local/bin/nu'),
      );
    });
  });

  group('round-tripping an id', () {
    test('a posix profile comes back from its id alone', () {
      final restored = terminalProfileFromId('posix:/opt/homebrew/bin/fish');

      expect(restored?.posixShellPath, '/opt/homebrew/bin/fish');
      expect(restored?.label, 'fish');
    });

    test('an empty path is not a profile', () {
      expect(terminalProfileFromId('posix:'), isNull);
    });
  });

  test('the chosen shell is the one that launches', () {
    // Off Windows every profile collapsed to $SHELL, which made the picker
    // inert: choosing bash on a machine whose login shell is zsh opened zsh.
    final context = LaunchContext.forProfile(
      TerminalProfile.posix('/bin/bash'),
      hostIsWindows: false,
      posixShell: '/bin/zsh',
    );

    expect(context.posixShell, '/bin/bash');
  });

  group('SSH terminal profiles', () {
    final sshEnv = ExecutionEnvironment(
      id: 'ssh:server1',
      name: 'prod-server',
      kind: EnvironmentKind.ssh,
      sshHostId: 'server1',
      createdAt: DateTime.utc(2026),
    );

    test('terminalProfilesFor includes SSH environments', () {
      final profiles = terminalProfilesFor([sshEnv]);

      expect(
        profiles.map((p) => p.id),
        contains('ssh:server1'),
      );
      final sshProfile = profiles.firstWhere((p) => p.id == 'ssh:server1');
      expect(sshProfile.shell, TerminalShell.ssh);
      expect(sshProfile.sshHostId, 'server1');
      expect(sshProfile.label, 'SSH: prod-server');
    });

    test('terminalProfileFromId restores ssh profile', () {
      final restored = terminalProfileFromId('ssh:server1');

      expect(restored, isNotNull);
      expect(restored!.shell, TerminalShell.ssh);
      expect(restored.sshHostId, 'server1');
      expect(restored.id, 'ssh:server1');
    });

    test('an SSH profile is never reinterpreted as a local launch', () {
      expect(
        () => LaunchContext.forProfile(
          TerminalProfile.ssh('server1'),
          hostIsWindows: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => LaunchContext.forProfile(
          TerminalProfile.ssh('server1'),
          hostIsWindows: false,
        ),
        throwsArgumentError,
      );
    });
  });

  group('SSH terminal commands', () {
    test('plain panes on one host use distinct persistent tmux sessions', () {
      final first = buildSshTerminalScript(paneId: 'pane-1', hostId: 'host:1');
      final second = buildSshTerminalScript(paneId: 'pane-2', hostId: 'host:1');

      expect(first, contains('TMUX_SESSION="karmashala_host_1_pane-1"'));
      expect(second, contains('TMUX_SESSION="karmashala_host_1_pane-2"'));
      expect(first, isNot(second));
    });

    test('restoring a pane reuses its tmux session', () {
      final before = buildSshTerminalScript(paneId: 'pane-1', hostId: 'host-1');
      final restored = buildSshTerminalScript(
        paneId: 'pane-1',
        hostId: 'host-1',
      );

      expect(restored, before);
    });

    test('agent session identity survives pane replacement', () {
      const launch = AgentPaneLaunch(
        agentId: 'codex',
        executable: 'codex',
        arguments: ['resume', 'conversation-1'],
        sessionId: 'session:1',
      );

      final first = buildSshTerminalScript(
        paneId: 'old-pane',
        hostId: 'host-1',
        agentLaunch: launch,
      );
      final replacement = buildSshTerminalScript(
        paneId: 'new-pane',
        hostId: 'host-1',
        agentLaunch: launch,
      );

      expect(first, contains('TMUX_SESSION="karmashala_session_1"'));
      expect(replacement, contains('TMUX_SESSION="karmashala_session_1"'));
    });

    test('quotes remote directories and every agent argument', () {
      const launch = AgentPaneLaunch(
        agentId: 'codex',
        executable: 'code x',
        arguments: ['run', "hello'; touch /tmp/pwn"],
        sessionId: 'session-1',
      );

      final script = buildSshTerminalScript(
        paneId: 'pane-1',
        hostId: 'host-1',
        workingDirectory: "/srv/work dir's",
        agentLaunch: launch,
      );

      expect(script, contains(r"cd '/srv/work dir'\''s'"));
      expect(script, contains("'code x' 'run' 'hello'\\''; touch /tmp/pwn'"));
    });
  });
}
