import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/application/wsl_path_existence.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_store/database.dart';
import 'package:riverpod/riverpod.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **A WSL project's folder is asked about with `wsl.exe`, from inside the
/// distribution — batched, kept, and never over `\\wsl.localhost`.**
///
/// The Explorer ran `Directory.exists` on the translated UNC path once per
/// built WSL row. Bitdefender's on-access scanner flags file access over that
/// share, and it is slow (docs/windows-antivirus.md).
void main() {
  /// A Windows host whose `wsl.exe` knows [folders] per distribution and which
  /// of them are [running].
  FakeCommandRunner windowsHost({
    required Map<String, Set<String>> folders,
    Set<String>? running,
    String? garbage,
  }) => FakeCommandRunner(
    responder: (request) {
      expect(request.executable, 'wsl.exe');
      final arguments = request.arguments;
      if (arguments.contains('--running')) {
        final names = running ?? folders.keys.toSet();
        return CommandResult(
          exitCode: names.isEmpty ? 1 : 0,
          // As `wsl.exe` prints it: UTF-16, read as bytes.
          stdout: names
              .map((name) => '${name.split('').join('\x00')}\r\n')
              .join(),
          stderr: '',
        );
      }
      if (garbage != null) {
        return CommandResult(exitCode: 0, stdout: garbage, stderr: '');
      }
      final distribution = arguments[arguments.indexOf('-d') + 1];
      final paths = arguments.sublist(
        arguments.indexOf('karmashala-exists') + 1,
      );
      final digits = [
        for (final path in paths)
          folders[distribution]!.contains(path) ? '1' : '0',
      ].join();
      return CommandResult(
        exitCode: 0,
        stdout: '$kWslExistsMarker$digits\n',
        stderr: '',
      );
    },
  );

  List<CommandRequest> existsCalls(FakeCommandRunner host) => [
    for (final request in host.requests)
      if (request.arguments.contains('--exec')) request,
  ];

  group('WslPathExistence', () {
    test('every path wanted in one turn is one wsl.exe call per distribution, '
        'and none of it names the share', () async {
      final host = windowsHost(
        folders: {
          'Ubuntu': {'/home/me/a', '/home/me/with space'},
          'archlinux': {'/srv/x'},
        },
      );
      final clock = MovableClock(testTime);
      final checker = WslPathExistence(host: host, now: clock.nowUtc);

      final answers = await Future.wait([
        checker.exists('Ubuntu', '/home/me/a'),
        checker.exists('Ubuntu', '/home/me/gone'),
        checker.exists('Ubuntu', '/home/me/with space'),
        checker.exists('archlinux', '/srv/x'),
        checker.exists('Ubuntu', '/home/me/a'),
      ]);

      expect(answers, [true, false, true, true, true]);
      expect(host.requests, hasLength(3), reason: 'running + one per distro');
      final ubuntu = existsCalls(
        host,
      ).singleWhere((request) => request.arguments[1] == 'Ubuntu');
      expect(
        ubuntu.arguments,
        wslDirectoriesExistArguments(
          distribution: 'Ubuntu',
          paths: ['/home/me/a', '/home/me/gone', '/home/me/with space'],
        ),
      );
      for (final request in host.requests) {
        final line = request.arguments.join(' ');
        expect(line, isNot(contains('wsl.localhost')));
        expect(line, isNot(contains(r'wsl$')));
      }
    });

    test(
      'an answer is kept: asking again spawns nothing until it is old',
      () async {
        final host = windowsHost(
          folders: {
            'Ubuntu': {'/home/me/a'},
          },
        );
        final clock = MovableClock(testTime);
        final checker = WslPathExistence(host: host, now: clock.nowUtc);

        expect(await checker.exists('Ubuntu', '/home/me/a'), isTrue);
        final spent = host.requests.length;

        for (var i = 0; i < 50; i++) {
          expect(await checker.exists('Ubuntu', '/home/me/a'), isTrue);
        }
        clock.now = clock.now.add(const Duration(minutes: 9));
        expect(await checker.exists('Ubuntu', '/home/me/a'), isTrue);
        expect(host.requests, hasLength(spent), reason: 'a row built again');

        clock.now = clock.now.add(const Duration(minutes: 2));
        await checker.exists('Ubuntu', '/home/me/a');
        expect(existsCalls(host), hasLength(2), reason: 'past the TTL');
      },
    );

    test('a new stamp — the window came back — asks again, but never twice '
        'inside the floor', () async {
      final host = windowsHost(
        folders: {
          'Ubuntu': {'/home/me/a'},
        },
      );
      final clock = MovableClock(testTime);
      final checker = WslPathExistence(host: host, now: clock.nowUtc);

      await checker.exists('Ubuntu', '/home/me/a', stamp: 0);
      clock.now = clock.now.add(const Duration(seconds: 5));
      await checker.exists('Ubuntu', '/home/me/a', stamp: 1);
      await checker.exists('Ubuntu', '/home/me/a', stamp: 2);
      expect(existsCalls(host), hasLength(1), reason: 'refocused in a flurry');

      clock.now = clock.now.add(const Duration(seconds: 40));
      await checker.exists('Ubuntu', '/home/me/a', stamp: 3);
      expect(existsCalls(host), hasLength(2));
    });

    test('a distribution that is not running is never started: not checked, '
        'which is not missing', () async {
      final host = windowsHost(
        folders: {
          'Ubuntu': {'/home/me/a'},
        },
        running: const {},
      );
      final clock = MovableClock(testTime);
      final checker = WslPathExistence(host: host, now: clock.nowUtc);

      expect(await checker.exists('Ubuntu', '/home/me/a'), isNull);
      expect(await checker.exists('Ubuntu', '/home/me/gone'), isNull);
      expect(existsCalls(host), isEmpty, reason: '--exec would start it');
      expect(
        host.requests.map((request) => request.arguments),
        everyElement(['-l', '--running', '-q']),
      );

      // Not asked about per row build either, and asked again soon: it may
      // have been started since.
      final spent = host.requests.length;
      await checker.exists('Ubuntu', '/home/me/a');
      expect(host.requests, hasLength(spent));
      clock.now = clock.now.add(const Duration(minutes: 2));
      await checker.exists('Ubuntu', '/home/me/a');
      expect(host.requests, hasLength(spent + 1));
    });

    test(
      'an answer that is not one, or no wsl.exe at all, is not checked',
      () async {
        final garbled = WslPathExistence(
          host: windowsHost(
            folders: {'Ubuntu': {}},
            garbage: 'wsl: something went wrong\n',
          ),
          now: MovableClock(testTime).nowUtc,
        );
        expect(await garbled.exists('Ubuntu', '/home/me/a'), isNull);

        final absent = WslPathExistence(
          host: FakeCommandRunner(throwError: CommandException('no wsl')),
          now: MovableClock(testTime).nowUtc,
        );
        expect(await absent.exists('Ubuntu', '/home/me/a'), isNull);
      },
    );

    test('forgetting a path asks again at once — an explicit rescan', () async {
      final host = windowsHost(
        folders: {
          'Ubuntu': {'/home/me/a'},
        },
      );
      final checker = WslPathExistence(
        host: host,
        now: MovableClock(testTime).nowUtc,
      );

      await checker.exists('Ubuntu', '/home/me/a');
      checker.forget('Ubuntu', '/home/me/a');
      await checker.exists('Ubuntu', '/home/me/a');
      expect(existsCalls(host), hasLength(2));
    });
  });

  group('projectPathMissingProvider', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.memory();
      final environments = ExecutionEnvironmentDao(db);
      environments.upsert(windowsEnv());
      environments.upsert(wslEnv());
      environments.upsert(sshEnvFixture());
    });
    tearDown(() => db.close());

    ProviderContainer mount(FakeCommandRunner host) {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          hostCommandRunnerProvider.overrideWithValue(host),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Project wsl(String id, String path) =>
        project(id: id, environmentId: 'wsl:Ubuntu', path: path);

    Future<bool> missing(ProviderContainer container, Project project) {
      container.listen(projectPathMissingProvider(project), (_, _) {});
      return container.read(projectPathMissingProvider(project).future);
    }

    test('a hundred WSL rows built together are one call, and only a folder '
        'that answered "no" is missing', () async {
      final host = windowsHost(
        folders: {
          'Ubuntu': {for (var i = 0; i < 100; i += 2) '/home/me/p$i'},
        },
      );
      final container = mount(host);
      final projects = [
        for (var i = 0; i < 100; i++) wsl('p$i', '/home/me/p$i'),
      ];

      final answers = await Future.wait([
        for (final project in projects) missing(container, project),
      ]);

      expect(answers, [for (var i = 0; i < 100; i++) i.isOdd]);
      expect(existsCalls(host), hasLength(1));
      expect(host.requests, hasLength(2));
    });

    test('a stopped distribution flags nothing and is not started', () async {
      final host = windowsHost(folders: {'Ubuntu': {}}, running: const {});
      final container = mount(host);

      expect(await missing(container, wsl('p1', '/home/me/gone')), isFalse);
      expect(existsCalls(host), isEmpty);
    });

    test('the window coming back asks again, in one call', () async {
      final folders = {'/home/me/a', '/home/me/b'};
      final host = windowsHost(folders: {'Ubuntu': folders});
      final clock = MovableClock(testTime);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(clock),
          hostCommandRunnerProvider.overrideWithValue(host),
        ],
      );
      addTearDown(container.dispose);
      final a = wsl('a', '/home/me/a');
      final b = wsl('b', '/home/me/b');
      expect(
        await Future.wait([missing(container, a), missing(container, b)]),
        [false, false],
      );
      expect(existsCalls(host), hasLength(1));

      folders.remove('/home/me/b');
      clock.now = clock.now.add(const Duration(minutes: 1));
      container.read(windowFocusedProvider.notifier).set(false);
      container.read(windowFocusedProvider.notifier).set(true);
      await container.pump();

      expect(
        await container.read(projectPathMissingProvider(b).future),
        isTrue,
      );
      expect(
        await container.read(projectPathMissingProvider(a).future),
        isFalse,
      );
      expect(existsCalls(host), hasLength(2));
    });

    test('dart:io is asked about no directory at all for a WSL row — it was '
        'asked about the translated share path, once per row', () async {
      final host = windowsHost(
        folders: {
          'Ubuntu': {'/home/me/p0'},
        },
      );
      final container = mount(host);

      final statted = <String>[];
      await IOOverrides.runZoned(
        () async {
          for (var i = 0; i < 5; i++) {
            await missing(container, wsl('p$i', '/home/me/p$i'));
          }
        },
        createDirectory: (path) {
          statted.add(path);
          return Directory.systemTemp;
        },
      );

      expect(statted, isEmpty);
    });

    test('an SSH project is never asked, by anything', () async {
      final host = windowsHost(folders: {'Ubuntu': {}});
      final container = mount(host);

      final remote = project(
        id: 's1',
        environmentId: 'ssh:h1',
        path: '/srv/app',
      );
      expect(await missing(container, remote), isFalse);
      expect(host.requests, isEmpty);
    });

    test('a share filed under this machine is not statted either', () async {
      final host = windowsHost(folders: {'Ubuntu': {}});
      final container = mount(host);

      final share = project(
        id: 'u1',
        path: r'\\wsl.localhost\Ubuntu\home\me\gone',
      );
      expect(await missing(container, share), isFalse);
      expect(host.requests, isEmpty);
    });
  });
}
