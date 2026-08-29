import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/devices/data/android_sdk_discovery.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/environments/domain/execution_environment.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

ExecutionEnvironment _windows() => ExecutionEnvironment(
  id: 'windows',
  kind: EnvironmentKind.windowsNative,
  name: 'Windows',
  createdAt: DateTime.utc(2026),
);

ExecutionEnvironment _wsl() => ExecutionEnvironment(
  id: 'wsl:Ubuntu',
  kind: EnvironmentKind.wsl,
  name: 'Ubuntu',
  wslDistribution: 'Ubuntu',
  createdAt: DateTime.utc(2026),
);

void main() {
  group('sdkCandidateRoots', () {
    test('prefers ANDROID_HOME, then ANDROID_SDK_ROOT, then well-known paths',
        () {
      final roots = sdkCandidateRoots(
        kind: EnvironmentKind.windowsNative,
        env: {
          'ANDROID_HOME': r'C:\sdk-a',
          'ANDROID_SDK_ROOT': r'C:\sdk-b',
          'LOCALAPPDATA': r'C:\Users\d\AppData\Local',
        },
      );
      expect(roots.first, r'C:\sdk-a');
      expect(roots[1], r'C:\sdk-b');
      expect(roots, contains(r'C:\Users\d\AppData\Local\Android\Sdk'));
    });

    test('falls back to the well-known Windows location with no env vars', () {
      final roots = sdkCandidateRoots(
        kind: EnvironmentKind.windowsNative,
        env: {'LOCALAPPDATA': r'C:\Users\d\AppData\Local'},
      );
      expect(roots, [r'C:\Users\d\AppData\Local\Android\Sdk']);
    });

    test('uses POSIX well-known locations inside WSL', () {
      final roots = sdkCandidateRoots(
        kind: EnvironmentKind.wsl,
        env: {'HOME': '/home/d'},
      );
      expect(roots, contains('/home/d/Android/Sdk'));
    });

    test('ignores blank env values', () {
      final roots = sdkCandidateRoots(
        kind: EnvironmentKind.windowsNative,
        env: {'ANDROID_HOME': '   ', 'LOCALAPPDATA': r'C:\L'},
      );
      expect(roots, [r'C:\L\Android\Sdk']);
    });
  });

  group('adbPathIn', () {
    test('appends .exe on Windows only', () {
      expect(
        adbPathIn(r'C:\sdk', EnvironmentKind.windowsNative),
        r'C:\sdk\platform-tools\adb.exe',
      );
      expect(
        adbPathIn('/opt/sdk', EnvironmentKind.wsl),
        '/opt/sdk/platform-tools/adb',
      );
    });
  });

  group('AndroidSdkDiscoveryService', () {
    test('finds the SDK at a well-known path when no env var is set', () async {
      // Mirrors this machine: the SDK exists but ANDROID_HOME is unset and adb
      // is not on PATH.
      final runner = FakeCommandRunner(
        responder: (request) {
          final joined = '${request.executable} ${request.arguments.join(' ')}';
          if (joined.contains('ANDROID_HOME') ||
              joined.contains('ANDROID_SDK_ROOT')) {
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          }
          if (joined.contains('LOCALAPPDATA')) {
            return const CommandResult(
              exitCode: 0,
              stdout: r'C:\Users\d\AppData\Local',
              stderr: '',
            );
          }
          // The existence probe succeeds only for the well-known adb.
          if (joined.contains('adb.exe')) {
            return const CommandResult(exitCode: 0, stdout: 'OK', stderr: '');
          }
          return const CommandResult(exitCode: 1, stdout: '', stderr: '');
        },
      );

      final sdk = await AndroidSdkDiscoveryService(
        runner: runner,
        environment: _windows(),
      ).discover();

      expect(sdk, isNotNull);
      expect(sdk!.adb.path, r'C:\Users\d\AppData\Local\Android\Sdk\platform-tools\adb.exe');
      expect(sdk.adb.environmentId, 'windows');
      expect(sdk.root.path, r'C:\Users\d\AppData\Local\Android\Sdk');
    });

    test('falls back to adb on PATH and derives the SDK root from it', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          final joined = '${request.executable} ${request.arguments.join(' ')}';
          if (request.executable == 'where' &&
              request.arguments.contains('adb')) {
            return const CommandResult(
              exitCode: 0,
              stdout: r'C:\tools\sdk\platform-tools\adb.exe',
              stderr: '',
            );
          }
          // No env vars, and no well-known path exists.
          if (joined.contains('echo')) {
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          }
          return const CommandResult(exitCode: 1, stdout: '', stderr: '');
        },
      );

      final sdk = await AndroidSdkDiscoveryService(
        runner: runner,
        environment: _windows(),
      ).discover();

      expect(sdk, isNotNull);
      expect(sdk!.adb.path, r'C:\tools\sdk\platform-tools\adb.exe');
      expect(sdk.root.path, r'C:\tools\sdk');
    });

    test('returns null when there is no SDK anywhere', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: ''),
      );
      final sdk = await AndroidSdkDiscoveryService(
        runner: runner,
        environment: _windows(),
      ).discover();
      expect(sdk, isNull);
    });

    test('survives an unavailable environment instead of throwing', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('wsl is not running'),
      );
      final sdk = await AndroidSdkDiscoveryService(
        runner: runner,
        environment: _wsl(),
      ).discover();
      expect(sdk, isNull);
    });

    test('reports the emulator binary when it is present', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          final joined = '${request.executable} ${request.arguments.join(' ')}';
          if (joined.contains('ANDROID_HOME')) {
            return const CommandResult(
              exitCode: 0,
              stdout: r'C:\sdk',
              stderr: '',
            );
          }
          if (joined.contains('adb.exe') || joined.contains('emulator.exe')) {
            return const CommandResult(exitCode: 0, stdout: 'OK', stderr: '');
          }
          return const CommandResult(exitCode: 1, stdout: '', stderr: '');
        },
      );
      final sdk = await AndroidSdkDiscoveryService(
        runner: runner,
        environment: _windows(),
      ).discover();
      expect(sdk!.emulator?.path, r'C:\sdk\emulator\emulator.exe');
      expect(sdk.canManageAvds, isTrue);
    });
  });
}
