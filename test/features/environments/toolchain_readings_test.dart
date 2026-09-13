import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/application/toolchain_readings.dart';
import 'package:karmashala/src/features/environments/domain/toolchain.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What a machine can build with, and the three answers that are not "no".**
///
/// The catalogue this replaced said what a Flutter project is built with and
/// measured nothing. The whole value of measuring is in keeping apart the
/// states a single boolean would flatten: it is there, it is not there, and
/// **nobody could ask** — which §19 says must never be reported as absence.
void main() {
  ProviderContainer containerWith(FakeCommandRunner runner) {
    final container = ProviderContainer(
      overrides: [
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

  test('a tool that answers is read at the version it printed', () async {
    final container = containerWith(
      FakeCommandRunner(
        responder: (request) => CommandResult(
          exitCode: 0,
          stdout: request.executable == 'node' ? 'v22.11.0\n' : 'something\n',
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
    // `java -version` has done this forever.
    final container = containerWith(
      FakeCommandRunner(
        responder: (_) => const CommandResult(
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

  test('a non-zero exit is missing; a machine that cannot be asked is not', () async {
    final refused = containerWith(
      FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 9009,
          stdout: '',
          stderr: "'flutter' is not recognized",
        ),
      ),
    );
    final unreachable = containerWith(
      FakeCommandRunner(throwError: CommandException('no shell there')),
    );

    final answered = await refused
        .read(toolchainReadingsProvider.notifier)
        .readAll(windowsEnv());
    final silent = await unreachable
        .read(toolchainReadingsProvider.notifier)
        .readAll(windowsEnv());

    expect(answered[Toolchain.flutterSdk]!.status, ToolchainStatus.missing);
    expect(
      silent[Toolchain.flutterSdk]!.status,
      ToolchainStatus.unknown,
      reason: 'a machine that could not be asked has not said the tool is '
          'absent, and reporting that would be a claim nobody measured',
    );
  });

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

    expect(
      runner.requests.map((r) => r.executable),
      contains('xcodebuild'),
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
