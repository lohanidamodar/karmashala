import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/application/wsl_path_existence.dart';
import 'package:karmashala/src/features/remote/application/remote_binding_support.dart';
import 'package:karmashala/src/features/repositories/application/host_checkout_presence_probe.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_store/database.dart';
import 'package:riverpod/riverpod.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **The other two places that statted a WSL folder over `\\wsl.localhost`
/// ask `wsl.exe` instead** (docs/windows-antivirus.md): a rescan's "is this
/// checkout gone", and the companion's "is this session's folder missing".
void main() {
  FakeCommandRunner windowsHost(Set<String> folders, {bool running = true}) =>
      FakeCommandRunner(
        responder: (request) {
          final arguments = request.arguments;
          if (arguments.contains('--running')) {
            return CommandResult(
              exitCode: running ? 0 : 1,
              stdout: running ? 'Ubuntu\r\n' : '',
              stderr: '',
            );
          }
          final paths = arguments.sublist(
            arguments.indexOf('karmashala-exists') + 1,
          );
          final digits = [
            for (final path in paths) folders.contains(path) ? '1' : '0',
          ].join();
          return CommandResult(
            exitCode: 0,
            stdout: '$kWslExistsMarker$digits\n',
            stderr: '',
          );
        },
      );

  int execs(FakeCommandRunner host) => host.requests
      .where((request) => request.arguments.contains('--exec'))
      .length;

  EnvironmentPath wslPath(String path) =>
      EnvironmentPath(environmentId: 'wsl:Ubuntu', path: path);

  /// Runs [body] and answers every path `dart:io` was asked to stat.
  Future<List<String>> directoriesAsked(Future<void> Function() body) async {
    final asked = <String>[];
    await IOOverrides.runZoned(
      body,
      createDirectory: (path) {
        asked.add(path);
        return Directory.systemTemp;
      },
    );
    return asked;
  }

  group('a rescan asking whether a WSL checkout is gone', () {
    test('asks wsl.exe once for every checkout asked together, stats nothing, '
        'and says present or absent', () async {
      final host = windowsHost({'/home/me/app', '/home/me/app/wt-1'});
      final probe = HostCheckoutPresenceProbe(
        wsl: WslPathExistence(host: host, now: FixedClock(testTime).nowUtc),
      );

      late List<CheckoutPresence> answers;
      final asked = await directoriesAsked(() async {
        answers = await Future.wait([
          for (final path in [
            '/home/me/app',
            '/home/me/app/wt-1',
            '/home/me/app/wt-gone',
          ])
            probe.presenceOf(
              wslPath(path),
              environment: wslEnv(),
              windows: windowsEnv(),
            ),
        ]);
      });

      expect(answers, [
        CheckoutPresence.present,
        CheckoutPresence.present,
        CheckoutPresence.absent,
      ]);
      expect(execs(host), 1);
      expect(asked, isEmpty);
    });

    test('a stopped distribution is unknown — which retires nothing — and is '
        'not started', () async {
      final host = windowsHost(const {}, running: false);
      final probe = HostCheckoutPresenceProbe(
        wsl: WslPathExistence(host: host, now: FixedClock(testTime).nowUtc),
      );

      expect(
        await probe.presenceOf(
          wslPath('/home/me/app'),
          environment: wslEnv(),
          windows: windowsEnv(),
        ),
        CheckoutPresence.unknown,
      );
      expect(execs(host), 0);
    });

    test('an answer that was kept is not proof: it asks again', () async {
      final folders = {'/home/me/app'};
      final host = windowsHost(folders);
      final paths = WslPathExistence(
        host: host,
        now: FixedClock(testTime).nowUtc,
      );
      final probe = HostCheckoutPresenceProbe(wsl: paths);
      expect(await paths.exists('Ubuntu', '/home/me/app'), isTrue);

      folders.clear();
      expect(
        await probe.presenceOf(
          wslPath('/home/me/app'),
          environment: wslEnv(),
          windows: windowsEnv(),
        ),
        CheckoutPresence.absent,
      );
    });

    test('a folder on this machine is asked as it always was', () async {
      final tmp = Directory.systemTemp.createTempSync('kpresence_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final host = windowsHost(const {});
      final probe = HostCheckoutPresenceProbe(
        wsl: WslPathExistence(host: host, now: FixedClock(testTime).nowUtc),
      );

      expect(
        await probe.presenceOf(
          EnvironmentPath(environmentId: 'windows', path: tmp.path),
          environment: windowsEnv(),
          windows: windowsEnv(),
        ),
        CheckoutPresence.present,
      );
      expect(host.requests, isEmpty);
    });
  });

  group('the companion asking whether a WSL folder is missing', () {
    test('stats nothing: it answers what is known, asks for the rest, and the '
        'next list has it', () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ExecutionEnvironmentDao(db).upsert(wslEnv());
      final host = windowsHost({'/home/me/here'});
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          hostCommandRunnerProvider.overrideWithValue(host),
        ],
      );
      addTearDown(container.dispose);
      final missing = container.read(remoteFolderMissingProvider);

      late List<bool> first;
      final asked = await directoriesAsked(() async {
        first = [
          for (var i = 0; i < 3; i++) missing(wslPath('/home/me/gone')),
          missing(wslPath('/home/me/here')),
        ];
        await pumpEventQueue();
      });

      expect(first, everyElement(isFalse), reason: 'not checked is not gone');
      expect(asked, isEmpty);
      expect(execs(host), 1, reason: 'a whole list is one call');
      expect(missing(wslPath('/home/me/gone')), isTrue);
      expect(missing(wslPath('/home/me/here')), isFalse);
    });
  });
}
