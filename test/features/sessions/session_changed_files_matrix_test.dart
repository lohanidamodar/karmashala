import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/session_changed_files_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_changed_files_dialog.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_session/delivery.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// The changed-files dialog at the minimum window and at large text: the
/// change word beside each path is read, not squeezed into a fixed column.
void main() {
  final report = SessionChangedFilesReport(
    outcome: SessionChangedFilesOutcome.fromAgentRecord,
    agentName: 'Codex CLI',
    checkedAt: testTime,
    files: const [
      SessionChangedFile(path: '/app/lib/a.dart', kind: FileEditKind.created),
      SessionChangedFile(path: '/app/lib/b.dart', kind: FileEditKind.modified),
      SessionChangedFile(path: '/app/lib/c.dart', kind: FileEditKind.deleted),
    ],
  );

  Widget app() => ProviderScope(
    overrides: [
      clockProvider.overrideWithValue(FixedClock(testTime)),
      sessionChangedFilesProvider('s1').overrideWith((ref) => report),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => SessionChangedFilesDialog.show(context, 's1'),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('SessionChangedFilesDialog survives the window matrix', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(tester, build: app, warmUp: open);
  });

  testWidgets('every change word stays on one line at large text', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      matrix: const [minimumWindow, minimumWindowLargeText],
      checkFocus: false,
      checkSemantics: false,
      build: app,
      warmUp: (tester) async {
        await open(tester);
        for (final word in ['Created', 'Modified', 'Deleted']) {
          final box = tester.renderObject<RenderBox>(find.text(word));
          expect(
            box.size.width,
            greaterThanOrEqualTo(box.getMaxIntrinsicWidth(double.infinity)),
            reason: '"$word" is broken across lines',
          );
        }
      },
    );
  });
}
