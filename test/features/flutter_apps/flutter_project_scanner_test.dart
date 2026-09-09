import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/flutter_apps/data/flutter_project_scanner.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';

const String _app = '''
name: an_app
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
''';

void main() {
  group('the local host, read with dart:io', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('flutter-scan');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    void write(String relative, String contents) {
      final file = File(p.join(root.path, relative));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(contents);
    }

    FlutterProjectScanner scanner() => FlutterProjectScanner(
      runner: FakeCommandRunner(),
      kind: Platform.isWindows
          ? EnvironmentKind.windowsNative
          : EnvironmentKind.localPosix,
    );

    Future<List<String>> scan({int maxDepth = 2}) async {
      final found = await scanner().scan(
        EnvironmentPath(environmentId: 'here', path: root.path),
        maxDepth: maxDepth,
      );
      return found.map((project) => project.name).toList();
    }

    test('the root project', () async {
      write('pubspec.yaml', _app);
      expect(await scan(), ['an_app']);
    });

    test('a project two directories down is found', () async {
      write('packages/mobile/pubspec.yaml', _app);
      expect(await scan(), ['an_app']);
    });

    test('three directories down is past the bound', () async {
      write('packages/a/example/pubspec.yaml', _app);
      expect(await scan(), isEmpty);
    });

    test('build/ and the platform folders are not descended into', () async {
      write('build/staged/pubspec.yaml', _app);
      write('android/app/pubspec.yaml', _app);
      write('.dart_tool/cache/pubspec.yaml', _app);
      expect(await scan(), isEmpty);
    });

    test('a checkout with no pubspec at all answers with an empty list', () async {
      write('README.md', '# nothing here');
      expect(await scan(), isEmpty);
    });

    test('a directory that does not exist is empty, not a throw', () async {
      final missing = EnvironmentPath(
        environmentId: 'here',
        path: p.join(root.path, 'nope'),
      );
      expect(await scanner().scan(missing), isEmpty);
    });
  });

  group('a distribution or another machine, read through the runner', () {
    late FakeCommandRunner runner;

    FlutterProjectScanner scanner(EnvironmentKind kind) =>
        FlutterProjectScanner(runner: runner, kind: kind);

    setUp(() {
      runner = FakeCommandRunner(environmentId: 'ubuntu');
      runner.responder = (request) {
        if (request.executable == 'find') {
          return const CommandResult(
            exitCode: 0,
            stdout: '/home/me/repo/pubspec.yaml\n/home/me/repo/app/pubspec.yaml\n',
            stderr: '',
          );
        }
        return CommandResult(
          exitCode: 0,
          stdout: request.arguments.last.contains('/app/')
              ? _app.replaceFirst('an_app', 'inner')
              : _app,
          stderr: '',
        );
      };
    });

    test('nothing local is stat-ed: every read is a command', () async {
      final found = await scanner(EnvironmentKind.wsl).scan(
        const EnvironmentPath(environmentId: 'ubuntu', path: '/home/me/repo'),
      );
      expect(found.map((project) => project.name), ['an_app', 'inner']);
      expect(runner.requests.first.executable, 'find');
      expect(runner.requests.first.arguments, contains('-maxdepth'));
      expect(
        runner.requests.where((request) => request.executable == 'cat').length,
        2,
      );
    });

    test('the depth bound reaches find as maxdepth + 1', () async {
      await scanner(EnvironmentKind.ssh).scan(
        const EnvironmentPath(environmentId: 'ubuntu', path: '/home/me/repo'),
        maxDepth: 2,
      );
      final find = runner.requests.first.arguments;
      expect(find[find.indexOf('-maxdepth') + 1], '3');
    });

    test('an environment that cannot be reached answers empty, not a throw',
        () async {
      runner.throwError = CommandException('the distribution is not running');
      expect(
        await scanner(EnvironmentKind.wsl).scan(
          const EnvironmentPath(environmentId: 'ubuntu', path: '/home/me/repo'),
        ),
        isEmpty,
      );
    });

    test('a non-zero find is empty rather than a partial answer', () async {
      runner.responder = (_) =>
          const CommandResult(exitCode: 1, stdout: '', stderr: 'no such dir');
      expect(
        await scanner(EnvironmentKind.wsl).scan(
          const EnvironmentPath(environmentId: 'ubuntu', path: '/home/me/repo'),
        ),
        isEmpty,
      );
    });
  });
}
