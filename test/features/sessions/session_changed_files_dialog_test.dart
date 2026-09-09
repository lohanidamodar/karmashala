import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/sessions/application/session_changed_files_providers.dart';
import 'package:karmashala/src/features/sessions/domain/session_changed_files.dart';
import 'package:karmashala/src/features/sessions/presentation/session_changed_files_dialog.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The changed-files dialog in each of its states.
///
/// One rule throughout: a session that changed nothing, a record that
/// could not be read and an agent that keeps no record must never look the same
/// on screen, and no reading may appear without its age (§19).
void main() {
  Widget app(SessionChangedFilesReport report) => ProviderScope(
    overrides: [
      clockProvider.overrideWithValue(
        FixedClock(testTime.add(const Duration(minutes: 3))),
      ),
      sessionChangedFilesProvider('s1').overrideWith((ref) => report),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
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

  Future<void> open(
    WidgetTester tester,
    SessionChangedFilesReport report,
  ) async {
    await tester.pumpWidget(app(report));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a list from the agent names the agent and the files', (
    tester,
  ) async {
    await open(
      tester,
      SessionChangedFilesReport(
        outcome: SessionChangedFilesOutcome.fromAgentRecord,
        agentName: 'Codex CLI',
        checkedAt: testTime,
        files: const [
          SessionChangedFile(
            path: '/home/me/app/lib/a.dart',
            hostPath: r'\\wsl.localhost\Ubuntu\home\me\app\lib\a.dart',
            kind: FileEditKind.created,
          ),
          SessionChangedFile(
            path: '/home/me/app/lib/b.dart',
            kind: FileEditKind.deleted,
          ),
        ],
      ),
    );

    expect(find.text('Files changed'), findsOneWidget);
    expect(
      find.textContaining('2 files, from Codex CLI’s own record'),
      findsOneWidget,
    );
    expect(find.text('Created'), findsOneWidget);
    expect(find.text('Deleted'), findsOneWidget);
    expect(
      find.text(r'\\wsl.localhost\Ubuntu\home\me\app\lib\a.dart'),
      findsOneWidget,
      reason: 'the host spelling is the one the user can act on',
    );
    expect(
      find.text('/home/me/app/lib/b.dart'),
      findsOneWidget,
      reason:
          'a path that cannot be expressed here is shown as the record wrote '
          'it, never silently dropped',
    );
  });

  testWidgets('every reading shows its age and says nothing re-reads itself', (
    tester,
  ) async {
    await open(
      tester,
      SessionChangedFilesReport(
        outcome: SessionChangedFilesOutcome.agentRecordNamesNoFile,
        agentName: 'Codex CLI',
        checkedAt: testTime,
      ),
    );

    expect(find.textContaining('Read 3m ago'), findsOneWidget);
    expect(find.textContaining('Nothing here is re-read on its own'), findsOneWidget);
  });

  // The three below are separate tests on purpose: `pumpWidget` updates the
  // element tree in place, so a second `show` in one test lands behind the
  // first dialog's modal barrier and asserts nothing.
  testWidgets('a record that names no file says exactly that', (tester) async {
    await open(
      tester,
      SessionChangedFilesReport(
        outcome: SessionChangedFilesOutcome.agentRecordNamesNoFile,
        agentName: 'Codex CLI',
        checkedAt: testTime,
      ),
    );

    expect(
      find.text('Codex CLI\u2019s record of this session names no changed file.'),
      findsOneWidget,
    );
  });

  testWidgets('a record that could not be read says why, and never "nothing"', (
    tester,
  ) async {
    await open(
      tester,
      SessionChangedFilesReport(
        outcome: SessionChangedFilesOutcome.nothingCanAnswer,
        gap: SessionRecordGap.recordUnreadable,
        detail: 'thread not loaded',
        agentName: 'Codex CLI',
        checkedAt: testTime,
      ),
    );

    expect(
      find.textContaining('could not be read (thread not loaded)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('no checkpoint to fall back on'),
      findsOneWidget,
    );
    expect(find.textContaining('names no changed file'), findsNothing);
  });

  testWidgets('an agent that keeps no record says that instead', (tester) async {
    await open(
      tester,
      SessionChangedFilesReport(
        outcome: SessionChangedFilesOutcome.nothingCanAnswer,
        gap: SessionRecordGap.agentKeepsNoRecord,
        agentName: 'Antigravity',
        checkedAt: testTime,
      ),
    );

    expect(
      find.textContaining('Antigravity keeps no record of what it changed'),
      findsOneWidget,
    );
    expect(find.textContaining('could not be read'), findsNothing);
  });

  testWidgets('a git answer carries the caveat about its baseline', (
    tester,
  ) async {
    await open(
      tester,
      SessionChangedFilesReport(
        outcome: SessionChangedFilesOutcome.fromCheckpoints,
        gap: SessionRecordGap.agentKeepsNoRecord,
        agentName: 'Antigravity',
        checkedAt: testTime,
        files: const [
          SessionChangedFile(path: 'lib/a.dart', kind: FileEditKind.modified),
        ],
      ),
    );

    expect(find.text('1 file, from this session’s checkpoints.'), findsOneWidget);
    expect(
      find.textContaining('already uncommitted when this session’s first turn ended'),
      findsOneWidget,
    );
  });

  testWidgets('Re-read is the only way it reads again', (tester) async {
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clockProvider.overrideWithValue(FixedClock(testTime)),
          sessionChangedFilesProvider('s1').overrideWith((ref) {
            reads++;
            return SessionChangedFilesReport(
              outcome: SessionChangedFilesOutcome.agentRecordNamesNoFile,
              agentName: 'Codex CLI',
              checkedAt: testTime,
            );
          }),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => SessionChangedFilesDialog.show(context, 's1'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(reads, 1);

    // Several frames, and no timer anywhere: the reading is taken when the
    // surface opens and when the user asks, never on a tick (§19).
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(reads, 1);

    await tester.tap(find.text('Re-read'));
    await tester.pumpAndSettle();
    expect(reads, 2);
  });
}
