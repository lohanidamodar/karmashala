import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/application/agent_rewind_points.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint.dart';
import 'package:karmashala/src/features/checkpoints/presentation/checkpoints_view.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// What the Checkpoints panel says about a turn, and about having none.
void main() {
  final now = testTime.add(const Duration(hours: 2));
  const app = EnvironmentPath(environmentId: 'windows', path: '/src/app');
  const lib = EnvironmentPath(environmentId: 'windows', path: '/src/lib');

  Checkpoint checkpoint({
    CheckpointReason reason = CheckpointReason.turn,
    int? turn = 3,
    String? prompt,
    EnvironmentPath repository = app,
    Map<String, FileDiffStat> lineStats = const {},
    List<String> files = const ['a.dart', 'b.dart'],
    String id = 'c1',
  }) => Checkpoint(
    id: id,
    sessionId: 's1',
    repository: repository,
    sequence: 7,
    treeSha: 't',
    commitSha: 'c',
    parentCommitSha: null,
    headSha: null,
    reason: reason,
    createdAt: testTime,
    turn: turn,
    prompt: prompt,
    lineStats: lineStats,
    files: [
      for (final f in files)
        FileChange(
          path: f,
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
    ],
  );

  group('labels', () {
    test('a turn checkpoint names its turn and which side of it', () {
      expect(
        checkpointTitle(checkpoint(reason: CheckpointReason.turnStart)),
        'Before turn 3',
      );
      expect(checkpointTitle(checkpoint()), 'After turn 3');
      expect(checkpointTitle(checkpoint(turn: null)), 'Turn #7');
    });

    test('the summary carries files, lines, repository and age', () {
      final c = checkpoint(
        lineStats: const {
          'a.dart': FileDiffStat(added: 10, removed: 2),
          'b.dart': FileDiffStat(added: 1, removed: 0),
        },
      );
      expect(checkpointSummary(c, now), '2 files · +11 −2 · 2h ago');
      expect(
        checkpointSummary(c, now, showRepository: true),
        '2 files · +11 −2 · app · 2h ago',
      );
      expect(
        checkpointSummary(checkpoint(files: const []), now),
        '0 files · 2h ago',
      );
    });

    test('an empty panel says when checkpoints are taken, and why not', () {
      expect(checkpointsEmptyMessage(null), contains('as a turn starts'));
      expect(checkpointsEmptyMessage(null), contains('SSH host'));
      expect(
        checkpointsEmptyMessage(kAutomaticCheckpointsOff),
        startsWith('No checkpoints yet: automatic checkpoints are off'),
      );
    });
  });

  group('agent rewind', () {
    test('Claude Code rewind points are counted from snapshot keys', () {
      final points = parseClaudeRewindPoints([
        '{"type":"user","message":{"content":"not read"}}',
        '{"type":"file-history-snapshot","messageId":"m1","snapshot":'
            '{"messageId":"m1","trackedFileBackups":{},'
            '"timestamp":"2026-09-16T10:00:00Z"},"isSnapshotUpdate":false}',
        '{"type":"file-history-snapshot","messageId":"m2","snapshot":'
            '{"messageId":"m2","trackedFileBackups":{},'
            '"timestamp":"2026-09-16T10:05:00Z"},"isSnapshotUpdate":false}',
        '{"type":"file-history-snapshot","messageId":"m2","snapshot":'
            '{"messageId":"m2","trackedFileBackups":{"/src/a.dart":'
            '{"backupFileName":"abc@v1","version":1,'
            '"backupTime":"2026-09-16T10:06:00Z"}},'
            '"timestamp":"2026-09-16T10:06:00Z"},"isSnapshotUpdate":true}',
        'not json "file-history-snapshot"',
      ]);
      expect(points.checkpoints, 2);
      expect(points.withFileEdits, 1);
      expect(points.latest, DateTime.utc(2026, 9, 16, 10, 6));
    });

    test('the note points at the agent\'s own mechanism', () {
      final claude = agentRewindNote(
        AgentIds.claudeCode,
        const AgentRewindPoints(
          agentId: AgentIds.claudeCode,
          checkpoints: 4,
          withFileEdits: 2,
        ),
      )!;
      expect(claude, contains('4 rewind points'));
      expect(claude, contains('2 with file edits'));
      expect(claude, contains('Esc twice or run /rewind'));
      expect(agentRewindNote(AgentIds.codex, null), contains('no undo'));
      expect(agentRewindNote('antigravity', null), isNull);
    });
  });

  group('panel', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase.memory();
      ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
      SessionDao(db).insert(session());
      container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          checkpointsPanelSessionIdProvider.overrideWithValue('s1'),
          clockProvider.overrideWithValue(FixedClock(now)),
        ],
      );
    });
    tearDown(() {
      container.dispose();
      db.close();
    });

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
      await tester.pump();
    }

    testWidgets('rows show the turn, the prompt, lines and repository', (
      tester,
    ) async {
      final dao = CheckpointDao(db);
      dao.insert(
        checkpoint(
          reason: CheckpointReason.turnStart,
          prompt: 'Fix the\nlogin redirect',
          files: const [],
        ),
      );
      dao.insert(
        checkpoint(
          id: 'c2',
          prompt: 'Fix the\nlogin redirect',
          repository: lib,
          lineStats: const {'a.dart': FileDiffStat(added: 5, removed: 1)},
        ),
      );
      await pumpPanel(tester);

      expect(find.text('Before turn 3'), findsOneWidget);
      expect(find.text('After turn 3'), findsOneWidget);
      expect(find.text('“Fix the login redirect”'), findsNWidgets(2));
      expect(find.text('2 files · +5 −1 · lib · 2h ago'), findsOneWidget);
      // A Claude Code session: its own undo is named beside ours.
      expect(find.textContaining('/rewind'), findsOneWidget);
    });

    testWidgets('an empty panel gives the recorder\'s reason', (tester) async {
      container
          .read(checkpointSkipReasonsProvider.notifier)
          .set('s1', 'it has no repository to checkpoint');
      await pumpPanel(tester);
      expect(
        find.textContaining(
          'No checkpoints yet: it has no repository to checkpoint.',
        ),
        findsOneWidget,
      );
    });
  });
}
