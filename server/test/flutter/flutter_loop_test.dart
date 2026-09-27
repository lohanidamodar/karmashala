import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_devices/karmashala_devices.dart'
    show kDeviceClaimLapse;
import 'package:karmashala_host/src/devices/server_device_claims.dart';
import 'package:karmashala_host/src/flutter/flutter_loop.dart';
import 'package:test/test.dart';

import 'flutter_fixture.dart';

void main() {
  late FlutterFixture fixture;
  ServerFlutterLoop loop() => fixture.work.loop;

  setUp(() => fixture = FlutterFixture());
  tearDown(() => fixture.close());

  Future<void> rebuild(CommandResult Function(CommandRequest) responder) async {
    await fixture.close();
    fixture = FlutterFixture(responder: responder);
  }

  group('the preflight, before anything is spawned', () {
    test('an environment nothing records is refused in words', () async {
      final ready = await loop().readiness(
        const EnvironmentPath(environmentId: 'gone', path: '/x'),
        kind: FlutterCommandKind.pubGet,
      );
      expect(
        ready.preflight.problem,
        FlutterPreflightProblem.environmentUnresolved,
      );
      expect(ready.preflight.reason, contains('gone'));
      expect(ready.preflight.reason, contains('Pick the checkout'));
      expect(fixture.runner.requests, isEmpty);
    });

    test('an SSH checkout is refused in words, not attempted', () async {
      final ready = await loop().readiness(
        const EnvironmentPath(environmentId: 'box', path: '/srv/app'),
        kind: FlutterCommandKind.run,
      );
      expect(
        ready.preflight.problem,
        FlutterPreflightProblem.environmentUnresolved,
      );
      expect(ready.preflight.reason, contains('SSH machine'));
      expect(fixture.runner.requests, isEmpty);
    });

    test('the §17 refusal reaches the preflight whole', () async {
      await rebuild(
        (request) => request.arguments.any((a) => a.contains('command -v'))
            ? const CommandResult(
                exitCode: 0,
                stdout: '/mnt/c/Users/me/flutter/bin/flutter\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final ready = await loop().readiness(
        wslProject,
        kind: FlutterCommandKind.pubGet,
      );
      expect(ready.preflight.problem, FlutterPreflightProblem.noSdk);
      expect(ready.preflight.reason, contains('§17'));
    });

    test('a directory with no Flutter pubspec names the fix', () async {
      await rebuild(
        (request) => request.executable == 'find'
            ? const CommandResult(exitCode: 0, stdout: '', stderr: '')
            : healthy(request),
      );
      final ready = await loop().readiness(
        wslProject,
        kind: FlutterCommandKind.pubGet,
      );
      expect(
        ready.preflight.problem,
        FlutterPreflightProblem.notAFlutterProject,
      );
      expect(ready.preflight.reason, contains('list_checkouts'));
    });

    test('a package is refused for run and not for pub get', () async {
      await rebuild(
        (request) => request.executable == 'cat'
            ? const CommandResult(
                exitCode: 0,
                stdout: packagePubspec,
                stderr: '',
              )
            : healthy(request),
      );
      final forRun = await loop().readiness(
        wslProject,
        kind: FlutterCommandKind.run,
      );
      expect(forRun.preflight.problem, FlutterPreflightProblem.notRunnable);
      final forPubGet = await loop().readiness(
        wslProject,
        kind: FlutterCommandKind.pubGet,
      );
      expect(forPubGet.preflight.isClear, isTrue);
    });

    test('no package_config blocks a run and never pub get', () async {
      await rebuild(
        (request) => request.executable == 'test'
            ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
            : healthy(request),
      );
      final forRun = await loop().readiness(
        wslProject,
        kind: FlutterCommandKind.run,
      );
      expect(forRun.preflight.problem, FlutterPreflightProblem.noPackages);
      expect(forRun.preflight.reason, contains('pubGet'));
      final forPubGet = await loop().readiness(
        wslProject,
        kind: FlutterCommandKind.pubGet,
      );
      expect(forPubGet.preflight.isClear, isTrue);
    });

    test('a package check that could not be taken does not block', () async {
      await rebuild((request) {
        if (request.executable == 'test') {
          throw CommandException('the distribution went away mid-check');
        }
        return healthy(request);
      });
      final ready = await loop().readiness(
        wslProject,
        kind: FlutterCommandKind.run,
      );
      expect(ready.preflight.isClear, isTrue);
    });
  });

  group('pub get, as a hosted run', () {
    test('runs the located SDK in the distribution, and is told', () async {
      final outcome = await loop().pubGet(wslProject);
      expect(outcome.preflight.isClear, isTrue);
      final argv = fixture.pty.started.single.argv;
      expect(argv.first, 'wsl.exe');
      expect(
        argv,
        containsAllInOrder(['-d', 'Ubuntu', '--cd', '/home/me/app']),
      );
      expect(argv.sublist(argv.length - 3), [
        '/home/me/flutter/bin/flutter',
        'pub',
        'get',
      ]);
      final run = outcome.run!;
      expect(run.paneId, hostedRunPaneId('id-0'));
      expect(run.command, ['/home/me/flutter/bin/flutter', 'pub', 'get']);
      expect(loop().livenessOf(run.paneId), FlutterRunLiveness.running);
      final told = fixture.told.whereType<HostedRunChanged>().single.run;
      expect(told.title, 'pub get · demo');
      expect(told.family, HostedRunFamily.flutter);
      expect(
        fixture.registry.find(told.hostSessionId),
        isNotNull,
        reason: 'a pane attaching to the run finds the session',
      );
    });

    test('a second pub get while one is live is refused by name', () async {
      final first = await loop().pubGet(wslProject);
      final second = await loop().pubGet(wslProject);
      expect(second.run, isNull);
      expect(second.preflight.problem, FlutterPreflightProblem.alreadyRunning);
      expect(second.preflight.reason, contains(first.run!.paneId));
    });

    test(
      'an ended run reads finished, with its code and the end told',
      () async {
        final outcome = await loop().pubGet(wslProject);
        fixture.lastProcess.finish(0);
        await settle();
        final run = loop().byPane(outcome.run!.paneId)!;
        expect(run.exitCode, 0);
        expect(loop().livenessOf(run.paneId), FlutterRunLiveness.finished);
        final ended = fixture.told.whereType<HostedRunChanged>().last.run;
        expect(ended.isLive, isFalse);
        expect(ended.exitCode, 0);
      },
    );

    test('a run nobody started reads unknown, never finished', () {
      expect(loop().livenessOf('never'), FlutterRunLiveness.unknown);
    });
  });

  group('flutter run, and the auto-attach', () {
    const address = 'http://127.0.0.1:53119/tok=/';
    const wsAddress = 'ws://127.0.0.1:53119/tok=/ws';

    test('carries -d, the device and extra arguments last', () async {
      final outcome = await loop().run(
        project: wslProject,
        deviceId: 'emulator-5554',
        extraArguments: const ['--profile'],
      );
      expect(outcome.preflight.isClear, isTrue);
      final argv = fixture.pty.started.single.argv;
      expect(argv, containsAllInOrder(['run', '-d', 'emulator-5554']));
      expect(argv.last, '--profile');
      expect(outcome.run!.deviceId, 'emulator-5554');
    });

    test('the announced address attaches it, nobody calling attach', () async {
      fixture.reachable[wsAddress] = FakeVmService();
      final outcome = await loop().run(
        project: wslProject,
        deviceId: 'emulator-5554',
      );
      final paneId = outcome.run!.paneId;
      expect(loop().byPane(paneId)!.vmServiceUri, isNull);
      fixture.lastProcess.emit(
        utf8.encode(
          'Launching lib/main.dart on sdk gphone64 in debug mode...\r\n'
          'A Dart VM Service on sdk gphone64 is available at:\r\n'
          '$address\r\n',
        ),
      );
      await settle();
      final run = loop().byPane(paneId)!;
      expect(run.vmServiceUri, wsAddress);
      expect(run.appId, AttachedApp.idFor(Uri.parse(wsAddress)));
      expect(
        fixture.work.apps.registry.byId(run.appId!)!.reachability,
        AppReachability.attached,
      );
      expect(
        fixture.told.whereType<FlutterAppsChanged>().last.registry.attached,
        hasLength(1),
      );
    });

    test('the DevTools line alone attaches nothing', () async {
      fixture.reachable[wsAddress] = FakeVmService();
      final outcome = await loop().run(
        project: wslProject,
        deviceId: 'emulator-5554',
      );
      fixture.lastProcess.emit(
        utf8.encode(
          'The Flutter DevTools debugger and profiler is available at: '
          'http://127.0.0.1:9101?uri=$address\r\n',
        ),
      );
      await settle();
      expect(loop().byPane(outcome.run!.paneId)!.vmServiceUri, isNull);
    });

    test('an address nothing answers on is kept and reported', () async {
      final outcome = await loop().run(
        project: wslProject,
        deviceId: 'emulator-5554',
      );
      fixture.lastProcess.emit(
        utf8.encode('A Dart VM Service on X is available at: $address\r\n'),
      );
      await settle();
      final run = loop().byPane(outcome.run!.paneId)!;
      expect(run.vmServiceUri, wsAddress);
      expect(
        fixture.work.apps.registry.byId(run.appId!)!.reachability,
        AppReachability.unreachable,
      );
    });

    test('refresh reads the out-file the run wrote', () async {
      await fixture.close();
      fixture = FlutterFixture();
      // A local run spells the out-file on this machine's own disk.
      fixture.database.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES ('local', 'localPosix', 'This Mac', ?);",
        [fixtureNow.toIso8601String()],
      );
      final project = Directory('${fixture.root.path}/app')
        ..createSync(recursive: true);
      File('${project.path}/pubspec.yaml').writeAsStringSync(appPubspec);
      Directory('${project.path}/.dart_tool').createSync();
      File(
        '${project.path}/.dart_tool/package_config.json',
      ).writeAsStringSync('{}');
      final local = fixture.build(windows: false);
      fixture.reachable[wsAddress] = FakeVmService();
      final outcome = await local.loop.run(
        project: EnvironmentPath(environmentId: 'local', path: project.path),
        deviceId: 'emulator-5554',
      );
      expect(outcome.preflight.isClear, isTrue, reason: '${outcome.preflight}');
      final outFile = outcome.run!.vmServiceOutFile!;
      File(outFile)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(wsAddress);
      final refreshed = await local.loop.refresh(outcome.run!.paneId);
      expect(refreshed!.vmServiceUri, wsAddress);
      expect(refreshed.isAttached, isTrue);
      await local.close();
    });

    test('one run per device: the second is refused by name', () async {
      final first = await loop().run(
        project: wslProject,
        deviceId: 'emulator-5554',
      );
      final second = await loop().run(
        project: const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/other',
        ),
        deviceId: 'emulator-5554',
      );
      expect(second.run, isNull);
      expect(second.preflight.problem, FlutterPreflightProblem.alreadyRunning);
      expect(second.preflight.reason, contains(first.run!.paneId));
    });

    test("another session's claim refuses the launch in its words", () async {
      final held = await loop().run(
        project: wslProject,
        deviceId: 'emulator-5554',
        sessionId: 's1',
      );
      await loop().stop(held.run!.paneId);
      final blocked = await loop().run(
        project: wslProject,
        deviceId: 'emulator-5554',
        sessionId: 's2',
      );
      expect(blocked.run, isNull);
      expect(blocked.preflight.problem, FlutterPreflightProblem.deviceBusy);
      expect(blocked.preflight.reason, contains('s1'));
    });

    test('a desktop device on a server with no display is refused', () async {
      final outcome = await loop().run(project: wslProject, deviceId: 'linux');
      expect(outcome.run, isNull);
      expect(outcome.preflight.reason, contains('no display'));
      expect(fixture.pty.started, isEmpty);
    });

    test('a desktop device on a server with a desktop runs', () async {
      fixture.work = fixture.build(hostEnvironment: const {'DISPLAY': ':0'});
      final outcome = await loop().run(project: wslProject, deviceId: 'linux');
      expect(outcome.preflight.isClear, isTrue);
    });

    test('stop ends the process rather than detaching it', () async {
      final outcome = await loop().run(
        project: wslProject,
        deviceId: 'emulator-5554',
      );
      final stopped = await loop().stop(outcome.run!.paneId);
      expect(stopped!.endedAt, isNotNull);
      expect(fixture.lastProcess.signals, isNotEmpty);
      await settle();
      expect(
        loop().livenessOf(outcome.run!.paneId),
        FlutterRunLiveness.finished,
      );
      expect(
        fixture.registry.find(hostedRunSessionId(outcome.run!.paneId)),
        isNotNull,
        reason: 'the record stays for a pane to show how it ended',
      );
    });

    test('stopping a run nobody started is null, not a throw', () async {
      expect(await loop().stop('someone-elses'), isNull);
    });
  });

  test("a flutter run's claim lapses like any device claim", () {
    final clock = _Clock(fixtureNow);
    final claims = ServerDeviceClaims(
      database: fixture.database,
      tell: (_) {},
      clock: clock,
    );
    addTearDown(claims.close);
    expect(claims.claim(deviceId: 'd', sessionId: 's1', verb: 'run'), isNull);
    expect(
      claims.claim(deviceId: 'd', sessionId: 's2', verb: 'run'),
      isNotNull,
    );
    clock.now = clock.now.add(kDeviceClaimLapse);
    expect(claims.claim(deviceId: 'd', sessionId: 's2', verb: 'run'), isNull);
  });

  group('the same adb as the device tools', () {
    EnvironmentPath localProject() {
      fixture.database.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES ('local', 'localPosix', 'This Mac', ?);",
        [fixtureNow.toIso8601String()],
      );
      final project = Directory('${fixture.root.path}/app')
        ..createSync(recursive: true);
      File('${project.path}/pubspec.yaml').writeAsStringSync(appPubspec);
      Directory('${project.path}/.dart_tool').createSync();
      File(
        '${project.path}/.dart_tool/package_config.json',
      ).writeAsStringSync('{}');
      return EnvironmentPath(environmentId: 'local', path: project.path);
    }

    test("a run on this machine carries the server's ANDROID_HOME", () async {
      final project = localProject();
      final local = fixture.build(
        windows: false,
        androidSdkRoot: () async => '/chosen/sdk',
      );
      final outcome = await local.loop.run(
        project: project,
        deviceId: 'emulator-5554',
      );
      expect(outcome.preflight.isClear, isTrue, reason: '${outcome.preflight}');
      expect(
        fixture.pty.started.last.environment['ANDROID_HOME'],
        '/chosen/sdk',
      );
      await local.close();
    });

    test('a WSL run keeps its own SDK', () async {
      final wsl = fixture.build(androidSdkRoot: () async => '/chosen/sdk');
      final outcome = await wsl.loop.run(
        project: wslProject,
        deviceId: 'emulator-5554',
      );
      expect(outcome.preflight.isClear, isTrue, reason: '${outcome.preflight}');
      expect(
        fixture.pty.started.last.environment.containsKey('ANDROID_HOME'),
        isFalse,
      );
      await wsl.close();
    });
  });
}

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}
