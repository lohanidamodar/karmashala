import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/application/environment_discovery_provider.dart';
import 'package:karmashala/src/features/environments/application/environments_controller.dart';
import 'package:karmashala/src/features/environments/data/environment_discovery_service.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/environments/domain/local_environment.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  _labelFallbackTests();

  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    final runner = FakeCommandRunner(
      responder: (_) =>
          const CommandResult(exitCode: 0, stdout: 'Ubuntu\n', stderr: ''),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        hostCommandRunnerProvider.overrideWithValue(runner),
        // These cases are about WSL, which only exists on Windows. Said out
        // loud so the suite tests the same thing wherever it runs, rather than
        // discovering nothing on a Mac and reporting that as a failure.
        environmentDiscoveryServiceProvider.overrideWithValue(
          EnvironmentDiscoveryService(
            host: runner,
            clock: FixedClock(testTime),
            hostIsWindows: true,
          ),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  test('starts with no environments', () {
    expect(container.read(environmentsControllerProvider), isEmpty);
  });

  test(
    'discoverAndPersist stores the host and its WSL distributions',
    () async {
      final result = await container
          .read(environmentsControllerProvider.notifier)
          .discoverAndPersist();

      expect(result.map((e) => e.id), ['windows', 'wsl:Ubuntu']);
      // State and persistence both reflect the discovery.
      expect(container.read(environmentsControllerProvider).map((e) => e.id), [
        'windows',
        'wsl:Ubuntu',
      ]);
    },
  );

  test('re-running discovery is idempotent (upsert by id)', () async {
    final notifier = container.read(environmentsControllerProvider.notifier);
    await notifier.discoverAndPersist();
    await notifier.discoverAndPersist();
    expect(container.read(environmentsControllerProvider).length, 2);
  });
}

void _labelFallbackTests() {
  test(
    'an environment the list has not loaded yet is still named after the host, '
    'not after its database key',
    () {
      // The local host's id is the literal `windows` on every platform (an
      // opaque key nobody should read), and every locally discovered agent
      // installation points at it. Before discovery finishes there is nothing
      // in the list to match, and the settings and fan-out screens labelled a
      // Mac's Claude and Codex installs "windows".
      final container = ProviderContainer(
        overrides: [environmentsControllerProvider.overrideWith(_NoEnvironments.new)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(environmentLabelForIdProvider(localHostEnvironmentId)),
        localHostEnvironmentName,
      );
      expect(
        container.read(environmentLabelForIdProvider(localHostEnvironmentId)),
        isNot('windows'),
        reason: 'on a Mac or a Linux box the raw key is a wrong answer',
      );
    },
  );

  test('an unknown environment still falls back to its id', () {
    // Only the local host can be answered without the list; anything else is
    // better identified by its key than by an empty line.
    final container = ProviderContainer(
      overrides: [environmentsControllerProvider.overrideWith(_NoEnvironments.new)],
    );
    addTearDown(container.dispose);

    expect(
      container.read(environmentLabelForIdProvider('ssh-build-box')),
      'ssh-build-box',
    );
  });
}

class _NoEnvironments extends EnvironmentsController {
  @override
  List<ExecutionEnvironment> build() => const [];
}
