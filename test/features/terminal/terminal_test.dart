import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/pty_launch.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import '../../support/fixtures.dart';

/// A process-free [TerminalInstance] so the controller can be tested without
/// spawning a real PTY.
class _FakeInstance implements TerminalInstance {
  _FakeInstance(this.id, this.title);
  @override
  final String id;
  @override
  final String title;
  @override
  final Terminal terminal = Terminal();
  bool disposed = false;
  @override
  void dispose() => disposed = true;
}

void main() {
  group('terminalProfilesFor', () {
    test('always offers PowerShell and Command Prompt, then WSL distros', () {
      final profiles = terminalProfilesFor([
        windowsEnv(),
        wslEnv(distro: 'Ubuntu'),
        wslEnv(id: 'wsl:Debian', distro: 'Debian'),
      ]);
      expect(profiles.map((p) => p.id), [
        'powershell',
        'cmd',
        'wsl:Ubuntu',
        'wsl:Debian',
      ]);
      expect(profiles[2].shell, TerminalShell.wsl);
      expect(profiles[2].wslDistribution, 'Ubuntu');
    });

    test(
      'resolveTerminalProfile falls back to the first when id is unknown',
      () {
        final profiles = terminalProfilesFor([windowsEnv()]);
        expect(resolveTerminalProfile('wsl:Gone', profiles).id, 'powershell');
        expect(resolveTerminalProfile('cmd', profiles).id, 'cmd');
      },
    );
  });

  group('ptyLaunchFor', () {
    test('PowerShell runs powershell.exe with the host working dir', () {
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws\app',
      );
      expect(launch.executable, 'powershell.exe');
      expect(launch.arguments, ['-NoLogo']);
      expect(launch.workingDirectory, r'C:\ws\app');
    });

    test('WSL launches the distro via wsl.exe --cd, not a host cwd', () {
      final launch = ptyLaunchFor(
        const TerminalProfile(
          id: 'wsl:Ubuntu',
          label: 'Ubuntu (WSL)',
          shell: TerminalShell.wsl,
          wslDistribution: 'Ubuntu',
        ),
        workingDirectory: '/home/me/app',
      );
      expect(launch.executable, 'wsl.exe');
      expect(launch.arguments, ['-d', 'Ubuntu', '--cd', '/home/me/app']);
      expect(launch.workingDirectory, isNull);
    });
  });

  group('TerminalSessionsController', () {
    ProviderContainer containerWithFake() {
      final container = ProviderContainer(
        overrides: [
          terminalInstanceFactoryProvider.overrideWithValue(
            ({required id, required profile, workingDirectory}) =>
                _FakeInstance(id, profile.label),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('opens tabs, activates the newest, and switches', () {
      final container = containerWithFake();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final first = controller.open(TerminalProfile.powerShell);
      final second = controller.open(TerminalProfile.commandPrompt);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.sessions.length, 2);
      expect(state.activeId, second);

      controller.activate(first);
      expect(
        container.read(terminalSessionsControllerProvider).activeId,
        first,
      );
    });

    test('closing the active tab disposes it and re-activates another', () {
      final container = containerWithFake();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final first = controller.open(TerminalProfile.powerShell);
      final second = controller.open(TerminalProfile.commandPrompt);

      final closed =
          container
                  .read(terminalSessionsControllerProvider)
                  .sessions
                  .firstWhere((s) => s.id == second)
              as _FakeInstance;

      controller.close(second);

      final state = container.read(terminalSessionsControllerProvider);
      expect(closed.disposed, isTrue);
      expect(state.sessions.length, 1);
      expect(state.activeId, first);
    });
  });

  group('terminalVisibleProvider', () {
    test('toggles visibility', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(terminalVisibleProvider), isFalse);
      container.read(terminalVisibleProvider.notifier).toggle();
      expect(container.read(terminalVisibleProvider), isTrue);
    });
  });
}
