import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/application/automation_undo.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala/src/features/automations/presentation/automation_undo_dialog.dart';

import '../../support/window_matrix.dart';

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
}
