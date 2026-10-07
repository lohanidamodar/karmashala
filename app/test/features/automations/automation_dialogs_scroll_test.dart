import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_undo.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala/src/features/automations/presentation/automation_undo_dialog.dart';
import 'package:karmashala/src/features/automations/presentation/project_checks_section.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// A run that left more commits than fit on one screen.
class _ManyCommits extends AutomationUndo {
  const _ManyCommits(super.ref);

  @override
  Future<RunCommits> commitsOf(AutomationRun run) async => RunCommits(
    baseSha: 'b' * 40,
    published: 0,
    commits: [
      for (var i = 0; i < 90; i++)
        RunCommit(sha: '${i.toString().padLeft(7, '0')}abc', subject: 'c$i'),
    ],
  );
}

void main() {
  testWidgets('undoing a run with ninety commits scrolls', (tester) async {
    final run = AutomationRun(
      id: 'run1',
      automationId: 'auto1',
      scheduledFor: DateTime.utc(2026, 9, 9, 3),
      firedAt: DateTime.utc(2026, 9, 9, 3),
      state: AutomationRunState.finished,
      reason: 'done',
    );
    await expectSurvivesWindowMatrix(
      tester,
      because: 'the commits checkbox lists every short sha it would drop',
      build: () => ProviderScope(
        overrides: [automationUndoProvider.overrideWith(_ManyCommits.new)],
        child: MaterialApp(home: AutomationUndoDialog(run: run)),
      ),
      warmUp: (tester) async {
        expect(find.textContaining('and 82 more'), findsOneWidget);
        expect(find.byType(DesktopDialogTitle), findsOneWidget);
      },
    );
  });

  testWidgets('a check with a long command scrolls', (tester) async {
    final server = FakeDataServer();
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    final client = await server.connect();
    await expectSurvivesWindowMatrix(
      tester,
      because: 'the dialog echoes every argument it will store',
      build: () {
        final db = TestMachine();
        server.environmentRows.upsert(windowsEnv());
        server.runsOn(db);
        final container = ProviderContainer(
          overrides: [
            ...fakeTerminalOverrides(machine: db),
            dataClientProvider.overrideWithValue(client),
            clockProvider.overrideWithValue(
              FixedClock(DateTime.utc(2026, 9, 9, 9)),
            ),
          ],
        );
        addTearDown(container.dispose);
        return UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: ProjectChecksSection()),
            ),
          ),
        );
      },
      warmUp: (tester) async {
        await tester.ensureVisible(find.text('Add a check'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add a check'));
        await tester.pumpAndSettle();
        expect(find.byType(DesktopDialogTitle), findsOneWidget);
        await tester.enterText(
          find.byType(TextField).last,
          [
            'flutter test',
            for (var i = 0; i < 40; i++) '--plain-name=case_$i',
          ].join(' '),
        );
      },
    );
  });
}
