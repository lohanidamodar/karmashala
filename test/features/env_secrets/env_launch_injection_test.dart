import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/env_secrets/domain/env_variable.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/launch_context.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';

const _overlay = {'TOKEN': 'super-secret-value', 'EDITOR': 'nvim'};

const _wslProfile = TerminalProfile(
  id: 'wsl-ubuntu',
  label: 'Ubuntu',
  shell: TerminalShell.wsl,
  wslDistribution: 'Ubuntu',
);

void main() {
  group('a plain shell pane carries the overlay', () {
    test('PowerShell', () {
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        context: const LaunchContext.powerShell(),
        environment: _overlay,
      );
      expect(launch.environment, _overlay);
    });

    test('cmd.exe', () {
      final launch = ptyLaunchFor(
        TerminalProfile.commandPrompt,
        context: const LaunchContext.commandPrompt(),
        environment: _overlay,
      );
      expect(launch.environment, _overlay);
    });

    test('a POSIX login shell', () {
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        context: const LaunchContext.posix(shell: '/bin/zsh'),
        environment: _overlay,
      );
      expect(launch.environment, _overlay);
    });

    test('and a launch that carries nothing is untouched', () {
      expect(
        ptyLaunchFor(
          TerminalProfile.powerShell,
          context: const LaunchContext.powerShell(),
        ).environment,
        isEmpty,
        reason: 'no overlay must be byte-identical to before this existed',
      );
    });
  });

  group('WSL', () {
    test('a WSL shell pane names every variable in WSLENV, with /u', () {
      final launch = ptyLaunchFor(
        _wslProfile,
        context: const LaunchContext.wsl('Ubuntu'),
        environment: _overlay,
      );

      expect(launch.environment['TOKEN'], 'super-secret-value');
      expect(launch.environment['WSLENV'], 'TOKEN/u:EDITOR/u');
    });

    test('a WSL agent pane names the overlay and the session plumbing', () {
      final launch = agentPtyLaunchFor(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          sessionId: 's1',
          wslDistribution: 'Ubuntu',
        ),
        context: const LaunchContext.wsl('Ubuntu'),
        environment: _overlay,
      );

      final names = launch.environment['WSLENV']!.split(':');
      expect(names, contains('TOKEN/u'));
      expect(names, contains('KARMASHALA_SESSION_ID/u'));
      expect(names.every((n) => n.endsWith('/u')), isTrue);
    });

    test('WSLENV is absent when there is nothing to carry', () {
      final launch = ptyLaunchFor(
        _wslProfile,
        context: const LaunchContext.wsl('Ubuntu'),
      );
      expect(launch.environment, isEmpty);
    });

    test('withWslEnv never translates paths (/p would corrupt a value)', () {
      final crossed = withWslEnv({'API_BASE': 'https://example.test/v1'});
      expect(crossed['WSLENV'], 'API_BASE/u');
      expect(crossed['WSLENV'], isNot(contains('/p')));
      expect(crossed['API_BASE'], 'https://example.test/v1');
    });
  });

  group('the session plumbing cannot be displaced', () {
    test('a KARMASHALA_ overlay entry loses to the real one', () {
      final launch = agentPtyLaunchFor(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          sessionId: 'the-real-session',
        ),
        context: const LaunchContext.windowsNative(),
        environment: const {
          kSessionIdEnvironmentVariable: 'an-impostor',
          'TOKEN': 'super-secret-value',
        },
      );

      expect(
        launch.environment[kSessionIdEnvironmentVariable],
        'the-real-session',
      );
      expect(launch.environment['TOKEN'], 'super-secret-value');
    });

    test('and the editor refuses those names in the first place', () {
      expect(envNameRefusal('KARMASHALA_SESSION_ID'), isNotNull);
      expect(envNameRefusal('WSLENV'), isNotNull);
      expect(envNameRefusal('PATH'), isNotNull);
      expect(envNameRefusal('Path'), isNotNull);
      expect(envNameRefusal('SystemRoot'), isNotNull);
      expect(envNameRefusal('GITHUB_TOKEN'), isNull);
    });
  });

  group('values never reach a command line', () {
    // `terminal_instance.dart` renders a failed launch as
    // `Failed to start "<exe> <args>"` straight into the pane buffer — not
    // redacted, persisted as scrollback, and readable by an agent through
    // `terminal_output`. It stringifies `arguments` and never `environment`,
    // so keeping values in the environment is what makes that banner safe.
    // This is the test that stops someone "simplifying" them into argv.
    for (final context in const [
      LaunchContext.powerShell(),
      LaunchContext.commandPrompt(),
      LaunchContext.wsl('Ubuntu'),
      LaunchContext.posix(shell: '/bin/bash'),
    ]) {
      test('no argument contains a value — ${context.kind.name}', () {
        final launch = ptyLaunchFor(
          context.kind == ShellContextKind.wsl
              ? _wslProfile
              : TerminalProfile.powerShell,
          context: context,
          environment: _overlay,
        );

        for (final argument in launch.arguments) {
          expect(argument, isNot(contains('super-secret-value')));
          expect(argument, isNot(contains('nvim')));
        }
        expect(launch.executable, isNot(contains('super-secret-value')));
      });
    }

    test('an agent launch keeps values out of argv too', () {
      final launch = agentPtyLaunchFor(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          sessionId: 's1',
        ),
        context: const LaunchContext.windowsNative(),
        environment: _overlay,
      );

      for (final argument in launch.arguments) {
        expect(argument, isNot(contains('super-secret-value')));
      }
    });
  });

  test('PtyLaunch.toString names no value', () {
    final launch = ptyLaunchFor(
      TerminalProfile.powerShell,
      context: const LaunchContext.powerShell(),
      environment: _overlay,
    );

    final described = launch.toString();
    expect(described, isNot(contains('super-secret-value')));
    expect(described, isNot(contains('nvim')));
    expect(described, isNot(contains('TOKEN')));
    expect(described, contains('2 environment variable(s)'));
  });

  test('the external-terminal path carries no environment at all', () {
    // Deliberate: a "copy command" line is clipboard-visible and an external
    // terminal is another process's argv. Neither is a place for a secret.
    final argv = wrapForExternalTerminal(
      const ShellCommand(
        executable: 'claude',
        environment: {'TOKEN': 'super-secret-value'},
      ),
      const LaunchContext.wsl('Ubuntu'),
    );

    expect(argv.join(' '), isNot(contains('super-secret-value')));
  });
}
