import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_service.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/presentation/checkpoints_view.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/git/data/git_files.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// [GitFiles] with no disk behind it.
class _MemoryGitFiles implements GitFiles {
  final Map<String, String> written = {};

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<bool> exists(String path) async => written.containsKey(path);

  @override
  Future<PathEntry> typeOf(String path) async =>
      throw UnimplementedError('the checkpoint path never stats');

  @override
  Future<void> writeString(String path, String contents) async =>
      written[path] = contents;

  @override
  Future<String?> readString(String path) async => written[path];
}

/// **The restore dialog says what the service refused, and what it cannot do.**
///
/// Two properties, and the first is what keeps the second true. The words on
/// screen are produced by [checkpointRestoreRefusal] — the same function
/// `restore` asserts on — so a change to the rule rewrites the sentence, and a
/// sentence promising something the service will not do cannot be written. On
/// top of that every one of them carries [kRestoreLeavesTheConversation],
/// because a checkpoint is a tree of files and an agent's conversation is not
/// one of them.
void main() {
  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\demo');
  late AppDatabase db;
  late CheckpointDao dao;
  late CheckpointService service;
  late List<String> trees;
  late int ids;

  CommandResult respond(CommandRequest request) {
    final args = request.arguments;
    if (args.contains('--absolute-git-dir') ||
        args.contains('--git-common-dir')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'C:/src/demo/.git',
        stderr: '',
      );
    }
    if (args.contains('write-tree')) {
      return CommandResult(
        exitCode: 0,
        stdout: trees.length > 1 ? trees.removeAt(0) : trees.first,
        stderr: '',
      );
    }
    if (args.contains('commit-tree')) {
      return CommandResult(exitCode: 0, stdout: 'commit${++ids}', stderr: '');
    }
    if (args.contains('rev-parse') && args.contains('--verify')) {
      return const CommandResult(exitCode: 0, stdout: 'head1', stderr: '');
    }
    if (args.contains('--name-status')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'M\tlib/a.dart\n',
        stderr: '',
      );
    }
    if (args.contains('diff')) {
      return const CommandResult(
        exitCode: 0,
        stdout:
            'diff --git a/lib/a.dart b/lib/a.dart\n'
            'index 111..222 100644\n'
            '--- a/lib/a.dart\n'
            '+++ b/lib/a.dart\n'
            '@@ -1 +1 @@\n'
            '-before\n'
            '+after\n',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: 'windows',
        kind: EnvironmentKind.windowsNative,
        name: 'Windows',
        createdAt: testTime,
      ),
    );
    dao = CheckpointDao(db);
    trees = ['tree1'];
    ids = 0;
    service = CheckpointService(
      runnerFactory: FakeCommandRunnerFactory(
        fallback: FakeCommandRunner(responder: respond),
      ),
      environmentDao: ExecutionEnvironmentDao(db),
      dao: dao,
      clock: FixedClock(testTime),
      newId: () => 'ckpt${ids + 100}',
      files: _MemoryGitFiles(),
    );
  });
  tearDown(() => db.close());

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
          checkpointDaoProvider.overrideWithValue(dao),
          checkpointServiceProvider.overrideWithValue(service),
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

  test('a refusal is one function, and it names the half we cannot undo', () {
    expect(
      checkpointRestoreRefusal(
        treeMovedSinceLastCheckpoint: false,
        safetySequence: null,
      ),
      isNull,
      reason: 'a tree that has not moved is not refused',
    );
    final refusal = checkpointRestoreRefusal(
      treeMovedSinceLastCheckpoint: true,
      safetySequence: 7,
    );
    expect(refusal, contains('checkpoint 7'));
    expect(refusal, contains(kRestoreLeavesTheConversation));
  });

  test('the service refuses in exactly those words', () async {
    final target = (await service.capture(repo, sessionId: 's1'))!;
    trees = ['tree2'];

    Object? thrown;
    try {
      await service.restore(target);
    } catch (error) {
      thrown = error;
    }

    final conflict = thrown! as CheckpointConflict;
    expect(
      conflict.message,
      checkpointRestoreRefusal(
        treeMovedSinceLastCheckpoint: true,
        safetySequence: conflict.safetyCheckpoint!.sequence,
      ),
      reason: 'the refusal and the sentence must be one function',
    );
  });

  testWidgets('a refused restore shows the service\'s own words', (
    tester,
  ) async {
    await service.capture(repo, sessionId: 's1');
    // The agent has been working since, so the restore will be refused.
    trees = ['tree2'];
    await pumpPanel(tester);

    await tester.tap(find.text('Restore').first);
    await settle(tester);

    // Sequence 2 is the safety checkpoint the refusal took of the tree as it
    // is now — the service's number, not the dialog's guess.
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
    await service.capture(repo, sessionId: 's1');
    trees = ['tree2'];
    await pumpPanel(tester);

    await tester.tap(find.text('Restore').first);
    await settle(tester);
    await tester.tap(find.text('Restore anyway'));
    await settle(tester);

    // The conversation is not rewound whether or not anything was refused, so
    // the sentence is on the outcome as well as on the refusal.
    expect(
      find.textContaining(kRestoreLeavesTheConversation),
      findsOneWidget,
    );
  });
}
