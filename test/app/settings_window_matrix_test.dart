import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_theme_controller.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_store/database.dart';

import '../support/fake_command_runner.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';
import '../support/window_matrix.dart';

/// The settings surfaces — pages, their cards and the dialogs they open — with
/// user data of realistic length: host names, distro names, project names and
/// paths are whatever the user typed, and the shared matrix files seed short
/// ones.

/// Nothing here may shell out.
// ignore: strict_top_level_inference
noProcessOverrides() => [
  commandRunnerFactoryProvider.overrideWithValue(
    FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
  ),
  hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
];

Widget app(ProviderContainer container, Widget home) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home, debugShowCheckedModeBanner: false),
    );

/// The narrowest window that still draws settings in two columns: it failed
/// where 720x560, which stacks, did not.
const narrowestTwoColumn = WindowCell('760x560', Size(760, 560));
const narrowestTwoColumnLargeText = WindowCell(
  '760x560 @ 1.3x',
  Size(760, 560),
  textScale: 1.3,
);

const settingsMatrix = [
  ...windowMatrix,
  desktopLargeText,
  narrowestTwoColumn,
  narrowestTwoColumnLargeText,
];

void main() {
  testWidgets('Environments section with a long SSH host name', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(
        wslEnv(
          id: 'wsl:Ubuntu-22.04-with-a-long-name',
          distro: 'Ubuntu-22.04-with-a-long-name',
        ),
      );
    SshHostDao(db).upsert(
      SshHost(
        id: 'h1',
        name: 'build-box-in-the-basement-with-a-long-name',
        host: 'build-server-01.internal.corp.example.popupbits.com',
        port: 2222,
        username: 'dlohani-service-account',
        authMethod: SshAuthMethod.password,
        createdAt: testTime,
      ),
    );
    // A project on the host draws the count pill beside the name.
    ExecutionEnvironmentDao(
      db,
    ).upsert(sshEnvFixture(name: 'build-box-in-the-basement-with-a-long-name'));
    ProjectDao(
      db,
    ).insert(project(environmentId: 'ssh:h1', path: '/home/dlohani/src/demo'));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        discoveredTerminalThemesProvider.overrideWithValue(const []),
      ],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(
        container,
        const SettingsScreen(initialSection: SettingsSectionId.environments),
      ),
      matrix: settingsMatrix,
      because:
          'host names, WSL distro names and paths are user data of any length',
    );
  });
}
