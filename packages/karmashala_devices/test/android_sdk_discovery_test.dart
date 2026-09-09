import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/src/data/android_sdk_discovery.dart';
import 'package:test/test.dart';

import './support/fake_command_runner.dart';

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

/// The environment probe's answer, in the shape the one shell prints it.
///
/// Every variable is read in a single call now, so a fake that answers "the
/// value of ANDROID_HOME" per request describes a discovery that no longer
/// happens — it has to answer them all at once, as a login shell would.
CommandResult _env(Map<String, String> values) => CommandResult(
  exitCode: 0,
  stdout: [
    // Interleaved with noise on purpose: a login shell runs the user's profile,
    // and profiles print things. Only the marked lines are ours.
    'nvm: using node v22',
    for (final entry in values.entries)
      '$kEnvMarker${entry.key}=${entry.value}',
  ].join('\n'),
  stderr: '',
);

void main() {
  group('sdkCandidateRoots', () {
    test(
      'prefers ANDROID_HOME, then ANDROID_SDK_ROOT, then well-known paths',
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
      },
    );

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

  group('reading the environment', () {
    test('asks one shell for every variable, not one shell each', () {
      final request = environmentRequest(EnvironmentKind.localPosix, const [
        'ANDROID_HOME',
        'ANDROID_SDK_ROOT',
        'HOME',
      ]);

      // A login shell is 63ms on the owner's Mac and three of them were 190ms
      // of the device pane's first open, for three values one shell can print.
      expect(request.executable, 'bash');
      expect(request.arguments.first, '-lc');
      final script = request.arguments.last;
      expect(script, contains(r'$ANDROID_HOME'));
      expect(script, contains(r'$ANDROID_SDK_ROOT'));
      expect(script, contains(r'$HOME'));
    });

    test('a profile that prints things cannot shift a value', () {
      // The reason each value names itself instead of being read off a line
      // number: a login shell runs the user's profile, and profiles print
      // banners, warnings and fortunes. On line numbers, the SDK root becomes
      // whatever the version manager said.
      final values = parseEnvironmentOutput(
        'Welcome to your shell!\n'
        'nvm: using node v22\n'
        '${kEnvMarker}ANDROID_HOME=/Users/d/Library/Android/sdk\n'
        'some trailing chatter\n',
      );

      expect(values, {'ANDROID_HOME': '/Users/d/Library/Android/sdk'});
    });

    test('an unset variable is absent, on either platform', () {
      // POSIX prints an empty value; `cmd` echoes the literal `%NAME%`. Both
      // mean "not set", and a path of `%ANDROID_HOME%` would send discovery
      // looking for an SDK in a folder named after the variable.
      expect(
        parseEnvironmentOutput(
          '${kEnvMarker}ANDROID_HOME=\n'
          '${kEnvMarker}ANDROID_SDK_ROOT=%ANDROID_SDK_ROOT%\n'
          '${kEnvMarker}HOME=/Users/d\n',
        ),
        {'HOME': '/Users/d'},
      );
    });

    test('a value with an = in it survives', () {
      // Split on the *first* `=` only: a path can contain one, and a truncated
      // path is worse than no path because it looks like an answer.
      expect(parseEnvironmentOutput('${kEnvMarker}HOME=/Users/d/a=b'), {
        'HOME': '/Users/d/a=b',
      });
    });

    test(
      'the Windows form is one call too, and picks up no trailing space',
      () {
        final request = environmentRequest(
          EnvironmentKind.windowsNative,
          const ['ANDROID_HOME', 'LOCALAPPDATA'],
        );

        expect(request.executable, 'cmd');
        // A space before `&` lands inside the *previous* echo's output, which
        // would put a trailing space on every value but the last.
        expect(request.arguments.last, isNot(contains(' &')));
        expect(request.arguments.last, contains('%ANDROID_HOME%'));
        expect(request.arguments.last, contains('%LOCALAPPDATA%'));
      },
    );
  });

  group('AndroidSdkDiscoveryService', () {
    test('finds the SDK at a well-known path when no env var is set', () async {
      // Mirrors this machine: the SDK exists but ANDROID_HOME is unset and adb
      // is not on PATH.
      final runner = FakeCommandRunner(
        responder: (request) {
          final joined = '${request.executable} ${request.arguments.join(' ')}';
          if (joined.contains(kEnvMarker)) {
            // Neither SDK variable is set here; only the well-known location.
            return _env({'LOCALAPPDATA': r'C:\Users\d\AppData\Local'});
          }
          // The probe runs the tool itself; only the well-known adb runs.
          if (request.executable.endsWith('adb.exe')) {
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
      expect(
        sdk!.adb.path,
        r'C:\Users\d\AppData\Local\Android\Sdk\platform-tools\adb.exe',
      );
      expect(sdk.adb.environmentId, 'windows');
      expect(sdk.root.path, r'C:\Users\d\AppData\Local\Android\Sdk');
    });

    test(
      'falls back to adb on PATH and derives the SDK root from it',
      () async {
        final runner = FakeCommandRunner(
          responder: (request) {
            final joined =
                '${request.executable} ${request.arguments.join(' ')}';
            if (request.executable == 'where' &&
                request.arguments.contains('adb')) {
              return const CommandResult(
                exitCode: 0,
                stdout: r'C:\tools\sdk\platform-tools\adb.exe',
                stderr: '',
              );
            }
            // No env vars, and no well-known path exists.
            if (joined.contains(kEnvMarker)) return _env(const {});
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
      },
    );

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
          if (joined.contains(kEnvMarker)) {
            return _env({'ANDROID_HOME': r'C:\sdk'});
          }
          if (request.executable.endsWith('adb.exe') ||
              request.executable.endsWith('emulator.exe')) {
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
