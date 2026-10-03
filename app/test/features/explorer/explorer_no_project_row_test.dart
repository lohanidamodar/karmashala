import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **Sessions without a project, on one row**: every machine's Scratch is
/// drawn as a single No project row, never a Scratch project of its own, and
/// opening it shows each machine's sessions under that machine's name.
void main() {
  late TestMachine db;

  setUp(() {
    db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    server.projectRows
      ..insert(project())
      ..insert(
        project(
          id: 's-win',
          name: 'Scratch',
          path: r'C:\Users\me\karmashala\scratch',
          kind: Project.scratchKind,
        ),
      )
      ..insert(
        project(
          id: 's-wsl',
          name: 'Scratch',
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/karmashala/scratch',
          kind: Project.scratchKind,
        ),
      );
    server.repositoryRows
      ..insert(repository())
      ..insert(
        repository(
          id: 'r-win',
          projectId: 's-win',
          name: '2026-10-03-tidy-a1b2c3',
          path: r'C:\Users\me\karmashala\scratch\2026-10-03-tidy-a1b2c3',
        ),
      )
      ..insert(
        repository(
          id: 'r-wsl',
          projectId: 's-wsl',
          name: '2026-10-03-notes-d4e5f6',
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/karmashala/scratch/2026-10-03-notes-d4e5f6',
        ),
      );
    server.installationRows
      ..insert(agentInstallation())
      ..insert(
        agentInstallation(
          id: 'a-wsl',
          environmentId: 'wsl:Ubuntu',
          path: '/usr/bin/claude',
        ),
      );
    server.sessionRows
      ..insert(
        session(id: 'w1', repositoryId: 'r-win', title: 'Tidy the downloads'),
      )
      ..insert(
        session(
          id: 'u1',
          repositoryId: 'r-wsl',
          agentInstallationId: 'a-wsl',
          title: 'Write the notes',
        ),
      );
  });

  testWidgets('every machine\'s Scratch is one No project row, holding each '
      'machine\'s sessions under its name', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await db.server.override(),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          autoImportRunnerProvider.overrideWithValue(
            (_) async => const ImportSummary(),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No project'), findsOneWidget);
    expect(find.text('Scratch'), findsNothing);
    expect(find.text('Demo'), findsOneWidget);
    expect(find.text('Tidy the downloads'), findsNothing);

    await tester.tap(find.text('No project'));
    await tester.pumpAndSettle();

    expect(find.text('Tidy the downloads'), findsOneWidget);
    expect(find.text('Write the notes'), findsOneWidget);
    expect(find.text('Windows'), findsWidgets);
    expect(find.text('Ubuntu'), findsWidgets);
    expect(
      tester.getTopLeft(find.text('Tidy the downloads')).dy,
      lessThan(tester.getTopLeft(find.text('Write the notes')).dy),
    );
  });
}
