import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_controller.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  group('shellLaunch', () {
    test('uses cmd.exe on Windows and bash in WSL', () {
      final win = shellLaunch(EnvironmentKind.windowsNative);
      expect(win.executable, 'cmd.exe');
      expect(win.arguments, ['/Q']);
      expect(shellLaunch(EnvironmentKind.wsl).executable, 'bash');
    });
  });

  group('TerminalSession', () {
    test('streams stdout and stderr, runs commands, and stops', () async {
      final handle = FakeProcessHandle();
      final session = TerminalSession(Future.value(handle));
      final lines = <TerminalLine>[];
      session.lines.listen(lines.add);

      await Future<void>.delayed(Duration.zero);
      session.run('echo hi');
      handle.emitStdout('hi');
      handle.emitStderr('oops');
      await Future<void>.delayed(Duration.zero);

      expect(handle.written, ['echo hi']);
      expect(lines.firstWhere((l) => l.text == 'hi').isError, isFalse);
      expect(lines.firstWhere((l) => l.text == 'oops').isError, isTrue);

      await session.stop();
      expect(handle.killed, isTrue);
    });
  });

  group('TerminalController', () {
    test('starts a shell and accumulates output and echoes commands', () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());

      final handle = FakeProcessHandle();
      final runner = FakeCommandRunner(processFactory: (_) => handle);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(terminalControllerProvider.notifier);
      controller.start(windowsEnv());
      await Future<void>.delayed(Duration.zero);
      expect(container.read(terminalControllerProvider).running, isTrue);

      handle.emitStdout('ready');
      await Future<void>.delayed(Duration.zero);
      expect(
        container
            .read(terminalControllerProvider)
            .lines
            .any((l) => l.text == 'ready'),
        isTrue,
      );

      controller.run('dir');
      expect(handle.written, contains('dir'));
      expect(
        container
            .read(terminalControllerProvider)
            .lines
            .any((l) => l.text == r'$ dir'),
        isTrue,
      );
    });

    test('terminal visibility toggles', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(terminalVisibleProvider), isFalse);
      container.read(terminalVisibleProvider.notifier).toggle();
      expect(container.read(terminalVisibleProvider), isTrue);
    });
  });
}
