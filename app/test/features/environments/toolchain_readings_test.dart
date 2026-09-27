import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/application/toolchain_readings.dart';
import 'package:karmashala/src/features/environments/domain/toolchain.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What a machine can build with, and the three answers that are not "no".**
///
/// The catalogue this replaced said what a Flutter project is built with and
/// measured nothing. The whole value of measuring is in keeping apart the
/// states a single boolean would flatten: it is there, it is not there, and
/// **nobody could ask** — which §19 says must never be reported as absence.
void main() {
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    server = FakeDataServer();
    data = await server.override();
  });

  ProviderContainer containerWith(FakeCommandRunner runner) {
    // The Flutter row is the server's reading (slice 3d).
    final container = ProviderContainer(
      overrides: [
        data,
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a machine nobody asked has said nothing, which is not "nothing"', () {
    final container = containerWith(FakeCommandRunner());
    final readings = container.read(toolchainReadingsProvider.notifier);

    expect(readings.hasLooked('windows'), isFalse);
    expect(readings.cached('windows'), isEmpty);
  });

  test('Flutter is the server\'s reading, never probed here', () async {
    // Slice 3d: the server's `FlutterSdkService` locates it (§17's
    // `flutter.bat` and the mount refusal are tested there).
    final runner = FakeCommandRunner();
    final container = containerWith(runner);

    final found = await container
        .read(toolchainReadingsProvider.notifier)
        .readAll(windowsEnv());

    expect(
      runner.requests.map((r) => r.arguments.join(' ')).join(' '),
      isNot(contains('flutter')),
    );
    expect(
      server.runs.asked.whereType<FlutterSdk>().single.environmentId,
      windowsEnv().id,
    );
    expect(found[Toolchain.flutterSdk]!.status, ToolchainStatus.present);
  });

  test('no server to ask is "could not ask", not "missing"', () async {
    final container = containerWith(FakeCommandRunner());
    server.runs.onFlutter = (_) =>
        throw const DataRefused.unavailable('no server');

    final found = await container
        .read(toolchainReadingsProvider.notifier)
        .readAll(wslEnv());

    expect(found[Toolchain.flutterSdk]!.status, ToolchainStatus.unknown);
  });

  test('a tool nothing can locate is missing, without being run', () async {
    final runner = FakeCommandRunner(
      responder: (request) => request.executable == 'where'
          ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
          : const CommandResult(exitCode: 0, stdout: 'v1\n', stderr: ''),
    );
    final container = containerWith(runner);

    final found = await container
        .read(toolchainReadingsProvider.notifier)
        .readAll(windowsEnv());

    expect(found[Toolchain.node]!.status, ToolchainStatus.missing);
    expect(
      runner.requests.map((r) => r.executable),
      isNot(contains('node')),
      reason: 'nothing on PATH is nothing to run',
    );
  });

  test('a tool that answers is read at the version it printed', () async {
    final container = containerWith(
      FakeCommandRunner(
        responder: (request) => CommandResult(
          exitCode: 0,
          stdout: request.executable == 'where'
              ? r'C:\tools\node.exe'
                    '\n'
              : request.executable == 'node'
              ? 'v22.11.0\n'
              : 'something\n',
          stderr: '',
        ),
      ),
    );

    final found = await container
        .read(toolchainReadingsProvider.notifier)
        .readAll(windowsEnv());

    expect(found[Toolchain.node]!.status, ToolchainStatus.present);
    expect(found[Toolchain.node]!.version, 'v22.11.0');
  });

  test('a tool that writes its version to stderr is still read', () async {
    // `java -version` has done this forever. The locate that precedes it still
    // answers on stdout, as `where` and `command -v` do.
    final container = containerWith(
      FakeCommandRunner(
        responder: (request) => request.executable == 'where'
            ? const CommandResult(
                exitCode: 0,
                stdout:
                    r'C:\jdk\bin\java.exe'
                    '\n',
                stderr: '',
              )
            : const CommandResult(
                exitCode: 0,
                stdout: '',
                stderr: 'openjdk version "21.0.4" 2024-07-16\n',
              ),
      ),
    );

    final found = await container
        .read(toolchainReadingsProvider.notifier)
        .readAll(windowsEnv());

    expect(found[Toolchain.jdk]!.status, ToolchainStatus.present);
    expect(found[Toolchain.jdk]!.version, contains('21.0.4'));
  });

  test(
    'a non-zero exit is missing; a machine that cannot be asked is not',
    () async {
      // The server's reading says which: nothing on PATH, or a machine it
      // could not reach.
      final refused = containerWith(FakeCommandRunner());
      final unreachable = containerWith(FakeCommandRunner());
      FlutterSdkReading refusal(FlutterSdkRefusal why) => FlutterSdkReading(
        environmentId: windowsEnv().id,
        readAt: testTime,
        refusal: why,
        reason: why.name,
      );

      server.runs.onFlutter = (_) => refusal(FlutterSdkRefusal.notFound);
      final answered = await refused
          .read(toolchainReadingsProvider.notifier)
          .readAll(windowsEnv());
      server.runs.onFlutter = (_) =>
          refusal(FlutterSdkRefusal.environmentUnreachable);
      final silent = await unreachable
          .read(toolchainReadingsProvider.notifier)
          .readAll(windowsEnv());

      expect(answered[Toolchain.flutterSdk]!.status, ToolchainStatus.missing);
      expect(
        silent[Toolchain.flutterSdk]!.status,
        ToolchainStatus.unknown,
        reason:
            'a machine that could not be asked has not said the tool is '
            'absent, and reporting that would be a claim nobody measured',
      );
    },
  );

  test('Xcode on Windows is ruled out without spawning anything', () async {
    final runner = FakeCommandRunner();
    final container = containerWith(runner);

    final found = await container
        .read(toolchainReadingsProvider.notifier)
        .readAll(windowsEnv());

    expect(found[Toolchain.xcode]!.status, ToolchainStatus.notApplicable);
    expect(
      runner.requests.map((r) => r.executable),
      isNot(contains('xcodebuild')),
      reason: 'the kind is enough to know, so no process is worth starting',
    );
  });

  test('a POSIX machine is asked about Xcode rather than assumed', () async {
    final runner = FakeCommandRunner();
    final container = containerWith(runner);

    await container
        .read(toolchainReadingsProvider.notifier)
        .readAll(posixEnv(id: 'mac'));

    // Named in the locate's arguments rather than spawned directly — a POSIX
    // lookup runs through the shell, so the executable is the shell.
    expect(
      runner.requests.map((r) => '${r.executable} ${r.arguments.join(' ')}'),
      anyElement(contains('xcodebuild')),
      reason: 'a localPosix may be a Mac or a Linux box; only it knows',
    );
  });

  test('a fresh reading is reused, and force measures again', () async {
    final runner = FakeCommandRunner();
    final container = containerWith(runner);
    final readings = container.read(toolchainReadingsProvider.notifier);

    await readings.readAll(windowsEnv());
    final first = runner.requests.length;
    await readings.readAll(windowsEnv());

    expect(runner.requests.length, first, reason: 'still fresh');

    await readings.readAll(windowsEnv(), force: true);
    expect(runner.requests.length, greaterThan(first));
  });
}
