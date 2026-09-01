import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/application/environment_discovery_provider.dart';
import 'package:karmashala/src/features/environments/application/environments_controller.dart';
import 'package:karmashala/src/features/environments/data/environment_discovery_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
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
