import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint_title.dart';
import 'package:karmashala/src/features/checkpoints/presentation/checkpoints_view.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/checkpoint_tools.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
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
    String? label,
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
    label: label,
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
    test('a turn is titled by what it was asked, both sides of it', () {
      const prompt = 'Fix the login redirect loop';
      expect(
        checkpointTitle(
          checkpoint(reason: CheckpointReason.turnStart, prompt: prompt),
        ),
        'Before: Fix the login redirect loop',
      );
      expect(
        checkpointTitle(checkpoint(prompt: prompt)),
        'After: Fix the login redirect loop',
      );
    });

    test('a prompt becomes one short line, not a paste', () {
      String title(String prompt) =>
          checkpointTitle(checkpoint(prompt: prompt));
      // Fenced code is skipped, markdown noise stripped, and an unbroken run
      // long enough to be a key or a blob never reaches the title.
      expect(
        title(
          '```\nStackTrace at main.dart:12\n```\n'
          '## Fix the crash when sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef '
          'is set\nand run the tests\n\nLogs follow: a b c',
        ),
        'After: Fix the crash when … is set and run the tests',
      );
      final long = title('word ' * 40);
      expect(long.length, lessThanOrEqualTo('After: '.length + 72));
      expect(long, endsWith('word…'));
      expect(title('   \n```\nonly code\n```'), 'After: a.dart, b.dart');
    });

    test('with no prompt: the files after a turn, the number before one', () {
      expect(checkpointTitle(checkpoint()), 'After: a.dart, b.dart');
      expect(
        checkpointTitle(
          checkpoint(files: const ['lib/a.dart', 'b.dart', 'c.dart', 'd.dart']),
        ),
        'After: a.dart, b.dart and 2 more',
      );
      // A before-turn row's files changed *before* the turn: not its title.
      expect(
        checkpointTitle(checkpoint(reason: CheckpointReason.turnStart)),
        'Before turn 3',
      );
      expect(checkpointTitle(checkpoint(files: const [])), 'After turn 3');
      expect(
        checkpointTitle(checkpoint(turn: null, files: const [])),
        'Turn #7',
      );
    });

    test('an unverified before-turn keeps its warning under any title', () {
      // Old rows carry the whole old title as their label; new ones the same.
      final marked = checkpoint(
        reason: CheckpointReason.turnStart,
        prompt: 'Change the app',
        label: lateTurnStartLabel(3),
      );
      expect(
        checkpointTitle(marked),
        'Before: Change the app — may already include its first edit',
      );
      expect(
        checkpointTitle(
          checkpoint(reason: CheckpointReason.turnStart, label: 'anything'),
        ),
        'Before turn 3 — may already include its first edit',
      );
      // A long prompt is clipped; the warning is not.
      expect(
        checkpointTitle(
          checkpoint(
            reason: CheckpointReason.turnStart,
            prompt: 'word ' * 40,
            label: lateTurnStartLabel(3),
          ),
        ),
        endsWith('… — may already include its first edit'),
      );
      // Only a before-turn row is ever marked: a label elsewhere is a name.
      expect(
        checkpointTitle(
          checkpoint(reason: CheckpointReason.manual, label: 'Before deploy'),
        ),
        'Before deploy',
      );
    });

    test('the summary carries turn, files, lines, repository and age', () {
      final c = checkpoint(
        lineStats: const {
          'a.dart': FileDiffStat(added: 10, removed: 2),
          'b.dart': FileDiffStat(added: 1, removed: 0),
        },
      );
      expect(checkpointSummary(c, now), 'Turn 3 · 2 files · +11 −2 · 2h ago');
      expect(
        checkpointSummary(c, now, showRepository: true),
        'Turn 3 · 2 files · +11 −2 · app · 2h ago',
      );
      // When the title is already the number, the summary does not repeat it.
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
        const ClaudeCodeAdapter().rewind,
        const AgentRewindPoints(
          agentId: AgentIds.claudeCode,
          checkpoints: 4,
          withFileEdits: 2,
        ),
      )!;
      expect(claude, contains('4 rewind points'));
      expect(claude, contains('2 with file edits'));
      expect(claude, contains('Esc twice or run /rewind'));
      expect(
        agentRewindNote(const CodexAdapter().rewind, null),
        contains('no undo'),
      );
      expect(agentRewindNote(const AntigravityAdapter().rewind, null), isNull);
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

      expect(find.text('Before: Fix the login redirect'), findsOneWidget);
      expect(find.text('After: Fix the login redirect'), findsOneWidget);
      // The prompt is the title now, so it is not repeated beneath it.
      expect(find.textContaining('login redirect'), findsNWidgets(2));
      expect(
        find.text('Turn 3 · 2 files · +5 −1 · lib · 2h ago'),
        findsOneWidget,
      );
      // A Claude Code session: its own undo is named beside ours.
      expect(find.textContaining('/rewind'), findsOneWidget);
    });

    test(
      'checkpoint_list gives an agent the panel\'s title, warning and all',
      () async {
        CheckpointDao(db).insert(
          checkpoint(
            reason: CheckpointReason.turnStart,
            prompt: 'Change the app',
            label: lateTurnStartLabel(3),
          ),
        );
        final listed =
            await CheckpointControlTools(
                  container,
                ).call('checkpoint_list', {'sessionId': 's1'})
                as List;
        final entry = listed.single as Map;
        expect(
          entry['title'],
          'Before: Change the app — may already include its first edit',
        );
        expect(entry['turn'], 3);
      },
    );

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
