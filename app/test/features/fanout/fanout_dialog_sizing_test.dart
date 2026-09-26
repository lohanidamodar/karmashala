import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/fanout/presentation/fanout_dialog.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import 'comparison_fixtures.dart';

/// A 720x560 box on a 1440x900 screen: what the dialog is given, not what the
/// screen measures, is what it has to fit.
Widget givenMinimumWindow(Widget child) => Align(
  alignment: Alignment.topLeft,
  child: SizedBox(width: 720, height: 560, child: child),
);

void main() {
  Future<ProviderContainer> prepared() async {
    final server = FakeDataServer();
    final db = seedDatabase(server: server);
    server.installationRows
      ..insert(agentInstallation(id: 'a1', agentId: 'claudeCode'))
      ..insert(agentInstallation(id: 'a2', agentId: 'codex'));
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    return container;
  }

  Widget app(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      home: givenMinimumWindow(const FanOutDialog()),
    ),
  );

  testWidgets('the fan-out dialog sizes to its box, not the screen', (
    tester,
  ) async {
    final container = await prepared();
    await expectSurvivesWindowMatrix(
      tester,
      matrix: const [desktopWindow, desktopLargeText],
      build: () => app(container),
      because: 'MediaQuery said 1440x900 while the dialog had 720x560',
    );
  });

  testWidgets('and so does its setup form', (tester) async {
    final container = await prepared();
    await expectSurvivesWindowMatrix(
      tester,
      matrix: const [desktopWindow, desktopLargeText],
      build: () => app(container),
      warmUp: (tester) async {
        await tester.tap(find.text('New fan-out'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('claudeCode'));
        await tester.tap(find.text('codex'));
      },
      because: 'the prompt field and usage strip read the screen height',
    );
  });
}
