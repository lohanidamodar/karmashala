import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_service.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/presentation/checkpoints_view.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/data/git_files.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// [GitFiles] with no disk behind it, keeping the patch that was written.
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

/// **The two verbs the MCP tools had and the panel did not.**
///
/// `checkpoint_capture` and `checkpoint_restore`'s `paths:` were reachable by
/// an agent and by nobody else. Both now have a control, and both go through
/// the same service and recorder the tools call — never around them.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakeCommandRunner runner;
  late _MemoryGitFiles files;
  late List<String> trees;
  late int ids;

  CommandResult respond(CommandRequest request) {
    final args = request.arguments;
    if (args.contains('--absolute-git-dir') ||
        args.contains('--git-common-dir')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'C:/src/demo/app/.git',
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
        stdout: 'M\tlib/a.dart\nM\tlib/b.dart\n',
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
            '-before a\n'
            '+after a\n'
            'diff --git a/lib/b.dart b/lib/b.dart\n'
            'index 333..444 100644\n'
            '--- a/lib/b.dart\n'
            '+++ b/lib/b.dart\n'
            '@@ -1 +1 @@\n'
            '-before b\n'
            '+after b\n',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1'));
    trees = ['tree1'];
    ids = 0;
    runner = FakeCommandRunner(responder: respond);
    files = _MemoryGitFiles();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        checkpointsPanelSessionIdProvider.overrideWithValue('s1'),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        checkpointServiceProvider.overrideWithValue(
          CheckpointService(
            runnerFactory: FakeCommandRunnerFactory(fallback: runner),
            environmentDao: ExecutionEnvironmentDao(db),
            dao: CheckpointDao(db),
            clock: FixedClock(testTime),
            newId: () => 'ckpt${++ids}',
            files: files,
          ),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  List<List<String>> gitCalls() => [for (final r in runner.requests) r.arguments];

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

  group('Capture now', () {
    testWidgets('records the working tree through the recorder', (
      tester,
    ) async {
      await pumpPanel(tester);
      expect(find.textContaining('No checkpoints yet'), findsOneWidget);

      await tester.tap(find.byTooltip('Capture the working tree now'));
      await settle(tester);

      expect(CheckpointDao(db).forSession('s1'), hasLength(1));
      expect(find.textContaining('Captured checkpoint 1'), findsOneWidget);
      // The list is behind the revision the recorder bumps, so it refreshes
      // without anything polling.
      expect(find.textContaining('Checkpoint #1'), findsOneWidget);
    });

    testWidgets('a tree that has not moved says both reasons it might not '
        'have been captured', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byTooltip('Capture the working tree now'));
      await settle(tester);
      await clearSnackBar(tester);
      await tester.tap(find.byTooltip('Capture the working tree now'));
      await settle(tester);

      expect(CheckpointDao(db).forSession('s1'), hasLength(1));
      expect(find.textContaining(kNothingToCapture), findsOneWidget);
    });
  });

  group('per-path restore', () {
    testWidgets('touches only the file it was asked for', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byTooltip('Capture the working tree now'));
      await settle(tester);
      await clearSnackBar(tester);
      // Nothing has moved since, so the restore is not refused and no dialog
      // stands between the tap and the patch.
      await tester.tap(find.textContaining('Checkpoint #1'));
      await settle(tester);

      expect(find.text('lib/a.dart'), findsOneWidget);
      expect(find.text('lib/b.dart'), findsOneWidget);
      // The tree has moved on since the checkpoint, so there is something to
      // put back.
      trees = ['tree2'];

      await tester.tap(find.byTooltip('Restore this file only').first);
      await settle(tester);
      // The refusal is expected — the tree moved — and confirming it is the
      // same per-path restore.
      if (find.text('Restore anyway').evaluate().isNotEmpty) {
        await tester.tap(find.text('Restore anyway'));
        await settle(tester);
      }

      final patch = files.written['C:/src/demo/app/.git/karmashala/apply.patch'];
      expect(patch, contains('lib/a.dart'));
      expect(
        patch,
        isNot(contains('lib/b.dart')),
        reason: 'a per-path restore must not write a file it was not given',
      );
      final apply = gitCalls().firstWhere((c) => c.contains('apply'));
      expect(apply, contains('-R'));
      expect(apply, isNot(contains('--cached')));
      // And it says it restored one file, not every file that differs.
      expect(find.textContaining('Restored 1 file.'), findsOneWidget);
    });
  });
}
