import 'package:chitragupta/src/app/shell/reveal_in_file_manager.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/path_translator.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/environments/domain/execution_environment.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

ExecutionEnvironment _windows() => ExecutionEnvironment(
  id: 'windows',
  kind: EnvironmentKind.windowsNative,
  name: 'Windows',
  createdAt: testTime,
);

ExecutionEnvironment _wsl({String distro = 'Ubuntu'}) => ExecutionEnvironment(
  id: 'wsl:$distro',
  kind: EnvironmentKind.wsl,
  name: distro,
  wslDistribution: distro,
  createdAt: testTime,
);

ExecutionEnvironment _ssh() => ExecutionEnvironment(
  id: 'ssh:h1',
  kind: EnvironmentKind.ssh,
  name: 'build-box',
  sshHostId: 'h1',
  createdAt: testTime,
);

({RevealInFileManager reveal, FakeCommandRunner host}) harness({
  List<ExecutionEnvironment> environments = const [],
  HostFileManager manager = HostFileManager.windowsExplorer,
}) {
  final host = FakeCommandRunner();
  return (
    host: host,
    reveal: RevealInFileManager(
      host: host,
      translator: const PathTranslator(),
      environmentFor: (id) => environments.where((e) => e.id == id).firstOrNull,
      fileManagerOverride: manager,
    ),
  );
}

void main() {
  group('hostPathFor', () {
    test('a Windows path is already the host spelling', () {
      final h = harness(environments: [_windows()]);
      expect(
        h.reveal.hostPathFor(
          const EnvironmentPath(environmentId: 'windows', path: r'C:\src\app'),
        ),
        r'C:\src\app',
      );
    });

    test('a WSL /mnt path is the drive it is mounted from', () {
      final h = harness(environments: [_wsl()]);
      expect(
        h.reveal.hostPathFor(
          const EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/mnt/c/src/app',
          ),
        ),
        r'C:\src\app',
      );
    });

    test('a WSL home path is a UNC path into the distribution', () {
      final h = harness(environments: [_wsl()]);
      expect(
        h.reveal.hostPathFor(
          const EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/home/me/src/app',
          ),
        ),
        r'\\wsl.localhost\Ubuntu\home\me\src\app',
      );
    });

    test('an SSH path has no spelling on this machine', () {
      final h = harness(environments: [_ssh()]);
      const path = EnvironmentPath(
        environmentId: 'ssh:h1',
        path: '/home/me/src/app',
      );
      expect(h.reveal.hostPathFor(path), isNull);
      expect(h.reveal.canReveal(path), isFalse);
    });

    test('an environment the app does not know is not guessed at', () {
      final h = harness();
      expect(
        h.reveal.hostPathFor(
          const EnvironmentPath(environmentId: 'gone', path: '/x'),
        ),
        isNull,
      );
    });
  });

  group('reveal', () {
    test('opens Explorer on the folder', () async {
      final h = harness(environments: [_windows()]);
      final outcome = await h.reveal.reveal(
        const EnvironmentPath(environmentId: 'windows', path: r'C:\src\app'),
      );

      expect(outcome.ok, isTrue);
      expect(h.host.requests.single.executable, 'explorer.exe');
      expect(h.host.requests.single.arguments, [r'C:\src\app']);
    });

    test('selecting an entry is one argument, switch and operand', () {
      // Explorer parses `/select,<path>` out of a single token; splitting it
      // into two arguments opens Documents instead.
      final request = RevealInFileManager.requestFor(
        HostFileManager.windowsExplorer,
        r'C:\src\app\pubspec.yaml',
        select: true,
      );
      expect(request.arguments, [r'/select,C:\src\app\pubspec.yaml']);
    });

    test('Finder and xdg-open get their own shapes', () {
      expect(
        RevealInFileManager.requestFor(
          HostFileManager.macFinder,
          '/Users/me/app/pubspec.yaml',
          select: true,
        ).arguments,
        ['-R', '/Users/me/app/pubspec.yaml'],
      );
      // xdg-open has no "select"; asking for one still opens the folder.
      expect(
        RevealInFileManager.requestFor(
          HostFileManager.xdgOpen,
          '/home/me/app',
          select: true,
        ).arguments,
        ['/home/me/app'],
      );
    });

    test('a non-zero exit is not a failure — explorer.exe returns 1', () async {
      final h = harness(environments: [_windows()]);
      h.host.responder = (_) =>
          const CommandResult(exitCode: 1, stdout: '', stderr: '');

      final outcome = await h.reveal.reveal(
        const EnvironmentPath(environmentId: 'windows', path: r'C:\src\app'),
      );

      expect(outcome.ok, isTrue);
    });

    test(
      'a remote path says where it actually is, and starts nothing',
      () async {
        final h = harness(environments: [_ssh()]);
        final outcome = await h.reveal.reveal(
          const EnvironmentPath(environmentId: 'ssh:h1', path: '/srv/app'),
        );

        expect(outcome.ok, isFalse);
        expect(outcome.error, contains('build-box'));
        expect(h.host.requests, isEmpty);
      },
    );

    test('a missing file manager is reported, not thrown', () async {
      final h = harness(environments: [_windows()]);
      h.host.throwError = CommandException('not found');

      final outcome = await h.reveal.reveal(
        const EnvironmentPath(environmentId: 'windows', path: r'C:\src\app'),
      );

      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('not found'));
    });
  });
}
