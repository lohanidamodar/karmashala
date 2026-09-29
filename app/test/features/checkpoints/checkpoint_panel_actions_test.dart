import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala/src/features/checkpoints/presentation/checkpoints_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **The two verbs the MCP tools have, in the panel.** Capture now and a
/// per-path restore go to the server's checkpoint recorder — the same doors
/// `checkpoint_capture` and `checkpoint_restore` use — and the panel never
/// runs git itself. What git does with them is tested at the server
/// (`server/test/checkpoints/`).
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late ProviderContainer container;

  Checkpoint captured(int sequence) => Checkpoint(
    id: 'ckpt$sequence',
    sessionId: 's1',
    repository: const EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\src\demo',
    ),
    sequence: sequence,
    treeSha: 'tree$sequence',
    commitSha: 'commit$sequence',
    parentCommitSha: null,
    headSha: 'head1',
    reason: CheckpointReason.manual,
    createdAt: testTime,
    files: const [
      FileChange(
        path: 'lib/a.dart',
        type: FileChangeType.modified,
        staged: false,
        unstaged: true,
      ),
      FileChange(
        path: 'lib/b.dart',
        type: FileChangeType.modified,
        staged: false,
        unstaged: true,
      ),
    ],
  );

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows.insert(session(id: 's1'));
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        await server.override(),
        panelSessionIdProvider.overrideWithValue('s1'),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
  });
  tearDown(() {
    container.dispose();
  });

  List<T> asked<T>() => server.checkpointWork.asked.whereType<T>().toList();

  /// Bounded pumps: a row spins while work is in flight, so nothing settles.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Let a snack bar time out, so the next assertion reads the next message
  /// rather than the one still on screen.
  Future<void> clearSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: CheckpointsView()),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> captureOne(WidgetTester tester) async {
    server.checkpointWork.nextCapture = captured(1);
    await tester.tap(find.byTooltip('Capture the working tree now'));
    await settle(tester);
    await clearSnackBar(tester);
  }

  group('Capture now', () {
    testWidgets('asks the server\'s recorder, as the user', (tester) async {
      await pumpPanel(tester);
      expect(find.textContaining('No checkpoints yet'), findsOneWidget);

      server.checkpointWork.nextCapture = captured(1);
      await tester.tap(find.byTooltip('Capture the working tree now'));
      await settle(tester);

      final capture = asked<CheckpointCapture>().single;
      expect(capture.sessionId, 's1');
      expect(capture.decidedBy, 'the user');
      expect(find.textContaining('Captured checkpoint 1'), findsOneWidget);
      // The list is kept by the change the server told, so it refreshes
      // without anything polling.
      expect(find.textContaining('Checkpoint #1'), findsOneWidget);
    });

    testWidgets('a tree that has not moved says both reasons it might not '
        'have been captured', (tester) async {
      await pumpPanel(tester);
      await captureOne(tester);
      await tester.tap(find.byTooltip('Capture the working tree now'));
      await settle(tester);

      expect(db.server.checkpointRows.forSession('s1'), hasLength(1));
      expect(find.textContaining(kNothingToCapture), findsOneWidget);
    });
  });

  group('per-path restore', () {
    testWidgets('asks for only the file it was given, and says so', (
      tester,
    ) async {
      await pumpPanel(tester);
      await captureOne(tester);
      await tester.tap(find.textContaining('Checkpoint #1'));
      await settle(tester);

      expect(find.text('lib/a.dart'), findsOneWidget);
      expect(find.text('lib/b.dart'), findsOneWidget);

      await tester.tap(find.byTooltip('Restore this file only').first);
      await settle(tester);

      final restore = asked<CheckpointRestore>().single;
      expect(restore.id, 'ckpt1');
      expect(restore.paths, ['lib/a.dart']);
      expect(restore.confirm, isFalse);
      // The server's answer names one file, and the panel says one.
      expect(find.textContaining('Restored 1 file.'), findsOneWidget);
    });

    testWidgets('a moved tree asks first, in the server\'s words, and '
        'confirming sends the same restore again', (tester) async {
      final refusal = checkpointRestoreRefusal(
        treeMovedSinceLastCheckpoint: true,
        safetySequence: 2,
      )!;
      server.checkpointWork.restoreWith = (request, checkpoint) =>
          request.confirm
          ? CheckpointRestoreAnswer.restored(
              RestoreOutcome(
                restored: checkpoint,
                safetyCheckpoint: captured(2),
                files: checkpoint.files.take(1).toList(),
                alreadyThere: false,
              ),
            )
          : CheckpointRestoreAnswer.refused(
              CheckpointConflict(refusal, safetyCheckpoint: captured(2)),
            );
      await pumpPanel(tester);
      await captureOne(tester);
      await tester.tap(find.textContaining('Checkpoint #1'));
      await settle(tester);
      await tester.tap(find.byTooltip('Restore this file only').first);
      await settle(tester);

      expect(find.text('Discard newer changes?'), findsOneWidget);
      expect(find.text(refusal), findsOneWidget);
      await tester.tap(find.text('Restore anyway'));
      await settle(tester);

      final restores = asked<CheckpointRestore>();
      expect([for (final r in restores) r.confirm], [false, true]);
      expect(restores.last.paths, ['lib/a.dart']);
      expect(
        find.textContaining('Undo it by restoring checkpoint 2.'),
        findsOneWidget,
      );
    });
  });

  group('the expanded diff', () {
    testWidgets('is asked for once, however often the panel rebuilds', (
      tester,
    ) async {
      server.checkpointWork.diffs['ckpt1'] =
          'diff --git a/lib/a.dart b/lib/a.dart\n'
          'index 111..222 100644\n'
          '--- a/lib/a.dart\n'
          '+++ b/lib/a.dart\n'
          '@@ -1 +1 @@\n'
          '-before a\n'
          '+after a\n';
      await pumpPanel(tester);
      await captureOne(tester);
      await tester.tap(find.textContaining('Checkpoint #1'));
      await settle(tester);

      expect(asked<CheckpointDiff>(), hasLength(1));
      expect(find.text('+after a'), findsOneWidget);

      for (var i = 0; i < 3; i++) {
        // ignore: invalid_use_of_protected_member
        tester.state(find.byType(CheckpointsView)).setState(() {});
        await settle(tester);
      }

      expect(asked<CheckpointDiff>(), hasLength(1));
    });
  });
}
