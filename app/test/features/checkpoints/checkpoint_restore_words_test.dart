import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala/src/features/checkpoints/presentation/checkpoints_view.dart';
import 'package:karmashala_git/git.dart' show FileChange, FileChangeType;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

/// **The restore dialog says what the server refused, and what it cannot do.**
///
/// The words on screen are the ones the server's restore refused with —
/// produced by [checkpointRestoreRefusal], the function the service asserts
/// on (tested with it in `karmashala_checkpoints` and at the server) — carried
/// back whole, never a second sentence written here. Every one of them carries
/// [kRestoreLeavesTheConversation], because a checkpoint is a tree of files
/// and an agent's conversation is not one of them.
void main() {
  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\demo');
  late FakeDataServer server;

  Checkpoint checkpoint(int sequence) => Checkpoint(
    id: 'ckpt$sequence',
    sessionId: 's1',
    repository: repo,
    sequence: sequence,
    treeSha: 'tree$sequence',
    commitSha: 'commit$sequence',
    parentCommitSha: null,
    headSha: 'head1',
    reason: CheckpointReason.turn,
    createdAt: testTime,
  );

  setUp(() {
    server = FakeDataServer();
    server.checkpointRows.insert(checkpoint(1));
    // The agent has been working since, so the restore is refused until it
    // is confirmed; sequence 2 is the safety checkpoint the server took.
    server.checkpointWork.restoreWith = (request, target) => request.confirm
        ? CheckpointRestoreAnswer.restored(
            RestoreOutcome(
              restored: target,
              safetyCheckpoint: checkpoint(2),
              files: const [
                FileChange(
                  path: 'lib/a.dart',
                  type: FileChangeType.modified,
                  staged: false,
                  unstaged: true,
                ),
              ],
              alreadyThere: false,
            ),
          )
        : CheckpointRestoreAnswer.refused(
            CheckpointConflict(
              checkpointRestoreRefusal(
                treeMovedSinceLastCheckpoint: true,
                safetySequence: 2,
              )!,
              safetyCheckpoint: checkpoint(2),
            ),
          );
  });

  /// Bounded pumps, not `pumpAndSettle`: the row spins while the restore is in
  /// flight and a dialog is up over it, so nothing in this tree ever settles.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          checkpointsPanelSessionIdProvider.overrideWithValue('s1'),
          await server.override(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: CheckpointsView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a refused restore shows the server\'s own words', (
    tester,
  ) async {
    await pumpPanel(tester);

    await tester.tap(find.text('Restore').first);
    await settle(tester);

    expect(
      find.text(
        checkpointRestoreRefusal(
          treeMovedSinceLastCheckpoint: true,
          safetySequence: 2,
        )!,
      ),
      findsOneWidget,
    );
  });

  testWidgets('and a restore that goes through says it too', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.text('Restore').first);
    await settle(tester);
    await tester.tap(find.text('Restore anyway'));
    await settle(tester);

    // The conversation is not rewound whether or not anything was refused, so
    // the sentence is on the outcome as well as on the refusal.
    expect(find.textContaining(kRestoreLeavesTheConversation), findsOneWidget);
    expect(find.textContaining('Restored 1 file.'), findsOneWidget);
  });
}
