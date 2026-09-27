import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/src/data/android_sdk_discovery.dart';
import 'package:test/test.dart';

import './support/fake_command_runner.dart';

/// The local POSIX host — a Mac, where the owner's PATH lives in `~/.zshrc`.
ExecutionEnvironment _posix() => ExecutionEnvironment(
  id: 'windows',
  kind: EnvironmentKind.localPosix,
  name: 'macOS',
  createdAt: DateTime.utc(2026),
);

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

/// The environment probe's answer, in the shape the one shell prints it. Every
/// variable is read in a single call, so a fake must answer them all at once.
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

    test('a hand-set SDK comes before everything the environment says', () {
      // The one rule the pane, the server's tools and `flutter run` share:
      // two adb versions on one machine restart each other's daemon.
      final roots = sdkCandidateRoots(
        kind: EnvironmentKind.localPosix,
        env: {'ANDROID_HOME': '/env/sdk', 'HOME': '/home/d'},
        handSet: '/chosen/sdk',
      );
      expect(roots.take(2), ['/chosen/sdk', '/env/sdk']);
    });
  });

  group('androidSdkPathIn', () {
    test('reads the setting, and nothing for a blank or absent one', () {
      expect(androidSdkPathIn({'androidSdkPath': ' /sdk '}), '/sdk');
      expect(androidSdkPathIn({'androidSdkPath': '  '}), isNull);
      expect(androidSdkPathIn(const <String, Object?>{}), isNull);
      expect(androidSdkPathIn('not a map'), isNull);
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
      ], loginShell: '/bin/zsh');

      // A login shell is 63ms on the owner's Mac and three of them were 190ms
      // of the device pane's first open, for three values one shell can print.
      //
      // And it is the **owner's** shell, not a hardcoded `bash`. This assertion
      // read `'bash'` until 2026-09-16, which is the same mistake agent CLI
      // discovery was fixed for: on a Mac `bash -l` reads `~/.bash_profile` and
      // never `~/.zprofile`, so an `ANDROID_HOME` the user's terminal shows
      // them was invisible here. It passed only because `$SHELL` is unset on
      // the Windows machine this suite usually runs on.
      expect(request.executable, '/bin/zsh');
      expect(request.arguments.first, '-lc');
      final script = request.arguments.last;
      expect(script, contains(r'$ANDROID_HOME'));
      expect(script, contains(r'$ANDROID_SDK_ROOT'));
      expect(script, contains(r'$HOME'));
    });

    test('a remote environment keeps bash, whatever this machine runs', () {
      // WSL and SSH are configured through their profile files and bash is what
      // is guaranteed to be installed there; the owner's shell is a fact about
      // the desktop, not about the far end.
      for (final kind in [EnvironmentKind.wsl, EnvironmentKind.ssh]) {
        expect(
          environmentRequest(kind, const ['HOME']).executable,
          'bash',
          reason: '$kind must not inherit the desktop owner\'s shell',
        );
      }
    });

    test('a profile that prints things cannot shift a value', () {
      // The reason each value names itself instead of being read off a line
      // number: a login shell runs the user's profile, and profiles print
      // banners.
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
      // mean "not set", and a path of `%ANDROID_HOME%` misdirects discovery.
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

    test(
      'finds adb the way the owner\'s terminal does, not just a login shell',
      () async {
        // The bug this is written for, measured on the owner's Mac 2026-09-16:
        // `bash -lc 'command -v adb'` exits 1 under launchd's PATH, while the
        // interactive probe answers
        // `~/Library/Android/sdk/platform-tools/adb`. The SDK's platform-tools
        // is added in `~/.zshrc`, which a login shell never reads, so an app
        // launched from Finder found no Android SDK at all while `adb` worked
        // perfectly in the terminal beside it.
        var interactiveProbes = 0;
        final runner = FakeCommandRunner(
          responder: (request) {
            final joined =
                '${request.executable} ${request.arguments.join(' ')}';
            if (joined.contains(kEnvMarker)) return _env(const {});
            if (request.arguments.contains('-ilc')) {
              interactiveProbes++;
              return const CommandResult(
                exitCode: 0,
                stdout:
                    '$kAgentPathMarker/Users/d/Library/Android/sdk/'
                    'platform-tools/adb\n',
                stderr: '',
              );
            }
            // Everything a login shell is asked — and every well-known path —
            // comes back empty, exactly as it does from a Finder launch.
            return const CommandResult(exitCode: 1, stdout: '', stderr: '');
          },
        );

        final sdk = await AndroidSdkDiscoveryService(
          runner: runner,
          environment: _posix(),
        ).discover();

        expect(sdk, isNotNull, reason: 'the interactive probe found adb');
        expect(
          sdk!.adb.path,
          '/Users/d/Library/Android/sdk/platform-tools/adb',
        );
        expect(sdk.root.path, '/Users/d/Library/Android/sdk');
        expect(interactiveProbes, greaterThan(0));
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
