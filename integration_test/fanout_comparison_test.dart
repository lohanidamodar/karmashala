import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_installation.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/fanout/application/comparison_providers.dart';
import 'package:karmashala/src/features/fanout/application/fanout_service.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_list.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/repositories/domain/repository.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/scrollback_autosave.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_codec.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// A fan-out comparison end to end, against **real agent CLIs, real Git
/// worktrees and a real SQLite file** — then a restart, a merge and a discard,
/// with the record read back each time.
///
/// The unit suite proves the bookkeeping. What it cannot prove is that the
/// worktrees git actually made are the ones the record names, that the merge
/// commit the record stores is the one git actually wrote, or that the record
/// still reads once the directories it describes have been deleted from disk.
/// That is what this does.
///
/// Skipped when the two agents are not installed, so the suite stays green on a
/// machine without them.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('cg_fanout_'));
  tearDown(() {
    try {
      work.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Where [executable] really is on this host: PATH first, then the two
  /// per-user install locations Windows agents actually land in, neither of
  /// which is guaranteed to be on a test runner's PATH.
  String? whereIs(String executable) {
    try {
      final result = Process.runSync('where.exe', [executable]);
      if (result.exitCode == 0) {
        final first = (result.stdout as String)
            .split(RegExp(r'[\r\n]+'))
            .where((line) => line.trim().isNotEmpty);
        if (first.isNotEmpty) return first.first.trim();
      }
    } catch (_) {}
    final home = Platform.environment['USERPROFILE'];
    if (home == null) return null;
    for (final candidate in [
      p.join(home, '.local', 'bin', '$executable.exe'),
      p.join(
        home,
        'AppData',
        'Local',
        'Microsoft',
        'WinGet',
        'Links',
        '$executable.exe',
      ),
      p.join(home, 'AppData', 'Roaming', 'npm', '$executable.cmd'),
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Whether `git` answers at all. Every step below shells out to it, and it
  /// was the one prerequisite this file never checked: the agent CLIs were
  /// guarded and then `git init` threw straight out of the test.
  bool hasGit() {
    try {
      return Process.runSync('git', ['--version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  ProcessResult git(String cwd, List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: cwd);
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
    }
    return result;
  }

  AppDatabase openDb() =>
      AppDatabase(sqlite3.open(p.join(work.path, 'db.sqlite')));

  ProviderContainer containerOver(AppDatabase db) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // A real periodic timer outlives the test and trips the pending-timer
      // check.
      scrollbackAutosaveFactoryProvider.overrideWithValue(
        ({required onTick}) => ScrollbackAutosave(
          onTick: onTick,
          schedule: (_, _) => Object(),
          cancel: (_) {},
        ),
      ),
    ],
  );

  /// Pumps until [finder] matches. `pumpAndSettle` cannot do this here: the
  /// page waits on a real `git` process, and while that runs no frame is
  /// scheduled, so settling returns instantly on "Reading…".
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    Duration within = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 120));
      if (finder.evaluate().isNotEmpty) return;
    }
    expect(finder, findsWidgets);
  }

  /// The same idea for state that is not on screen: pumps until [ready] holds,
  /// answering false if it never does. Everything this file used to sleep for
  /// has an observable, and this is how it is watched.
  Future<bool> waitUntil(
    WidgetTester tester,
    bool Function() ready, {
    Duration within = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      if (ready()) return true;
      await tester.pump(const Duration(milliseconds: 120));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return ready();
  }

  testWidgets('a comparison survives a restart, a merge and a discard', (
    tester,
  ) async {
    final claude = whereIs('claude');
    final codex = whereIs('codex');
    if (claude == null || codex == null) {
      markTestSkipped('claude and codex are not both on PATH.');
      return;
    }
    if (!hasGit()) {
      markTestSkipped('git is not on PATH, and every step below needs it.');
      return;
    }

    // --- A real repository -------------------------------------------------
    final repoDir = Directory(p.join(work.path, 'demo'))..createSync();
    final repoPath = repoDir.path;
    git(repoPath, ['init', '-q', '-b', 'main']);
    git(repoPath, ['config', 'user.name', 'cg']);
    git(repoPath, ['config', 'user.email', 'cg@example.com']);
    File(p.join(repoPath, 'README.md')).writeAsStringSync('demo\n');
    git(repoPath, ['add', '-A']);
    git(repoPath, ['commit', '-qm', 'initial']);

    final db = openDb();
    final now = DateTime.now().toUtc();
    final repoLocation = EnvironmentPath(
      environmentId: 'windows',
      path: repoPath,
    );
    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: 'windows',
        kind: EnvironmentKind.windowsNative,
        name: 'Windows',
        createdAt: now,
      ),
    );
    ProjectDao(db).insert(
      Project(
        id: 'p1',
        name: 'fanout-e2e',
        root: EnvironmentPath(environmentId: 'windows', path: work.path),
        createdAt: now,
      ),
    );
    final repository = Repository(
      id: 'r1',
      projectId: 'p1',
      name: 'demo',
      path: repoLocation,
      createdAt: now,
    );
    RepositoryDao(db).insert(repository);

    final claudeInstall = AgentInstallation(
      id: 'i-claude',
      agentId: AgentIds.claudeCode,
      executable: EnvironmentPath(environmentId: 'windows', path: claude),
      createdAt: now,
    );
    final codexInstall = AgentInstallation(
      id: 'i-codex',
      agentId: AgentIds.codex,
      executable: EnvironmentPath(environmentId: 'windows', path: codex),
      createdAt: now,
    );
    AgentInstallationDao(db)
      ..insert(claudeInstall)
      ..insert(codexInstall);

    var container = containerOver(db);

    // --- Launch: two real CLIs, two real worktrees --------------------------
    final launched = await container
        .read(fanOutServiceProvider)
        .launch(
          repository: repository,
          installations: [claudeInstall, codexInstall],
          prompt: 'Reply with the single word ready. Change nothing.',
        );

    expect(launched.started, hasLength(2), reason: '${launched.failures}');
    final comparisonId = launched.comparison.id;

    // Git made the directories the record names.
    for (final result in launched.started) {
      final worktree = result.session.worktree!.path;
      expect(
        Directory(worktree).existsSync(),
        isTrue,
        reason: 'a real worktree at $worktree',
      );
    }
    final branches =
        git(repoPath, ['branch', '--list', 'session/*']).stdout as String;
    expect(
      branches
          .split(RegExp(r'[\r\n]+'))
          .where((line) => line.contains('session/')),
      hasLength(2),
      reason: 'one session branch per agent',
    );

    // The CLIs have to actually be running before they can be stopped, and
    // nothing may be removed while a pane is live — which is the next step. Both
    // waits watch the state that decides it rather than guessing at six seconds
    // and two: a pane per session with its terminal producing output, and then
    // every one of those panes no longer live.
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    List<String> panes() => [
      for (final result in launched.started)
        ?SessionDao(db).getById(result.session.id)?.paneId,
    ];

    expect(
      await waitUntil(tester, () {
        final ids = panes();
        return ids.length == launched.started.length &&
            ids.every((pane) {
              final instance = terminals.instanceFor(pane);
              return instance != null &&
                  encodeScrollback(instance.terminal).trim().isNotEmpty;
            });
      }),
      isTrue,
      reason: 'the agent panes never produced any output',
    );

    final started = panes();
    for (final pane in started) {
      terminals.endSession(pane);
    }
    expect(
      await waitUntil(
        tester,
        () => started.every(
          (pane) =>
              container
                  .read(terminalSessionsControllerProvider)
                  .livenessOf(pane) !=
              PaneLiveness.live,
        ),
      ),
      isTrue,
      reason: 'a pane was still live, and nothing may be removed while one is',
    );

    // --- Real work in each worktree, so there is something to compare -------
    for (var i = 0; i < launched.started.length; i++) {
      final worktree = launched.started[i].session.worktree!.path;
      git(worktree, ['config', 'user.name', 'cg']);
      git(worktree, ['config', 'user.email', 'cg@example.com']);
      File(
        p.join(worktree, 'ANSWER.md'),
      ).writeAsStringSync('${launched.started[i].agentId}\n' * (i + 1));
      git(worktree, ['add', '-A']);
      git(worktree, [
        'commit',
        '-qm',
        'answer from ${launched.started[i].agentId}',
      ]);
      // And one uncommitted line, so the diff stat has lines to count.
      File(
        p.join(worktree, 'ANSWER.md'),
      ).writeAsStringSync('${launched.started[i].agentId}\nstill working\n');
    }

    final service = container.read(fanOutServiceProvider);
    for (final result in launched.started) {
      final diff = await service.diff(result);
      expect(diff, contains('ANSWER.md'));
    }

    var stored = container.read(comparisonProvider(comparisonId))!;
    expect(stored.candidates, hasLength(2));
    for (final candidate in stored.candidates) {
      debugPrint(
        'E2E launched ${candidate.agentId} on ${candidate.branch} '
        'at ${candidate.worktree?.path} -> ${candidate.diff?.summary}',
      );
    }
    for (final candidate in stored.candidates) {
      expect(candidate.diff, isNotNull);
      expect(candidate.diff!.filesChanged, greaterThan(0));
      expect(
        candidate.diff!.commits,
        1,
        reason: 'one real commit ahead of main',
      );
    }

    // --- Restart ------------------------------------------------------------
    container.dispose();
    db.close();
    final reopened = openDb();
    container = containerOver(reopened);
    addTearDown(() {
      container.dispose();
      reopened.close();
    });

    stored = container.read(comparisonsProvider).single;
    expect(stored.id, comparisonId);
    expect(stored.prompt, 'Reply with the single word ready. Change nothing.');
    expect(stored.candidates.map((c) => c.agentId), [
      AgentIds.claudeCode,
      AgentIds.codex,
    ]);
    expect(stored.outcome, ComparisonOutcome.pending);

    final rebuilt = container.read(fanOutServiceProvider).resultsFor(stored);
    expect(rebuilt, hasLength(2), reason: 'the handles come back');
    debugPrint(
      'E2E after restart: ${stored.candidates.length} candidates, '
      'outcome ${stored.outcome.name}, '
      '${rebuilt.length} live handles rebuilt',
    );

    // --- The real view, over the real record --------------------------------
    // Driven through the widgets rather than the service, because "a
    // comparison is a place you return to" is a claim about the page.
    String? opened;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ComparisonList(onOpen: (id) => opened = id, onNew: null),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fan-out comparisons'), findsOneWidget);
    final row = find.textContaining('Reply with the single word ready');
    expect(row, findsOneWidget, reason: 'the comparison is in the list');
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(opened, comparisonId);

    // --- Merge the winner, from the page ------------------------------------
    final winner = rebuilt.first;
    // A merge refuses a dirty worktree; commit the second line first.
    git(winner.session.worktree!.path, ['add', '-A']);
    git(winner.session.worktree!.path, ['commit', '-qm', 'more']);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ComparisonView(comparisonId: comparisonId, onBack: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(AgentIds.claudeCode), findsOneWidget);
    expect(find.text(AgentIds.codex), findsOneWidget);

    // Read the loser's diff from the page — the winner's tree was just
    // committed, so it is the one that still has something uncommitted to show.
    expect(
      find.widgetWithText(TextButton, 'Read the diff'),
      findsNWidgets(2),
      reason: 'both worktrees are still there',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Read the diff').last);
    await pumpUntil(tester, find.textContaining('ANSWER.md'));
    expect(
      find.textContaining('ANSWER.md'),
      findsWidgets,
      reason: 'the real diff of a real worktree, on the page',
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Winner').first);
    await tester.pumpAndSettle();
    expect(find.text('Winner: ${AgentIds.claudeCode}'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Merge').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Merge winner'));
    for (var i = 0; i < 250; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      if (container.read(comparisonProvider(comparisonId))!.outcome ==
          ComparisonOutcome.merged) {
        break;
      }
    }
    debugPrint(
      'E2E after merge tap: outcome='
      '${container.read(comparisonProvider(comparisonId))!.outcome.name} '
      'repo=${Directory(repoPath).listSync().map((e) => p.basename(e.path)).toList()}',
    );

    expect(
      File(p.join(repoPath, 'ANSWER.md')).existsSync(),
      isTrue,
      reason: 'the winner\'s file is really in the repository now',
    );
    stored = container.read(comparisonProvider(comparisonId))!;
    expect(stored.outcome, ComparisonOutcome.merged);
    expect(stored.winner!.agentId, AgentIds.claudeCode);
    final head = (git(repoPath, ['rev-parse', 'HEAD']).stdout as String).trim();
    expect(
      stored.mergedCommit,
      head,
      reason: 'the recorded commit is the one git wrote',
    );
    debugPrint('E2E merged ${stored.winner!.agentId} as $head');

    // --- Discard the loser, and confirm its uncommitted work ----------------
    // The loser still has an uncommitted line, so the service refuses it and
    // the page must ask about that specific agent — Loop 48's per-session
    // confirmation, driven for real.
    final loser = rebuilt.last;
    final loserPath = loser.session.worktree!.path;
    expect(Directory(loserPath).existsSync(), isTrue);

    await tester.tap(find.text('Discard losing worktrees'));
    await pumpUntil(tester, find.text('These worktrees hold uncommitted work'));
    expect(
      find.text('These worktrees hold uncommitted work'),
      findsOneWidget,
      reason: 'it refuses rather than asking forgiveness',
    );
    expect(find.textContaining('ANSWER.md'), findsWidgets);
    expect(Directory(loserPath).existsSync(), isTrue, reason: 'nothing yet');

    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete 1'));
    for (var i = 0; i < 200 && Directory(loserPath).existsSync(); i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(
      Directory(loserPath).existsSync(),
      isFalse,
      reason: 'the directory is really gone from disk',
    );

    // --- And it still reads, after another restart --------------------------
    container.dispose();
    reopened.close();
    final again = openDb();
    final third = containerOver(again);
    addTearDown(() {
      third.dispose();
      again.close();
    });

    final finalRecord = third.read(comparisonsProvider).single;
    expect(finalRecord.outcome, ComparisonOutcome.merged);
    expect(finalRecord.mergedCommit, head);
    expect(finalRecord.winner!.agentId, AgentIds.claudeCode);
    final finalLoser = finalRecord.candidates.last;
    expect(finalLoser.agentId, AgentIds.codex);
    expect(finalLoser.worktreeRemoved, isTrue);
    expect(finalLoser.hasLiveWorktree, isFalse);
    expect(
      finalLoser.diff,
      isNotNull,
      reason: 'the record of a worktree that no longer exists',
    );
    expect(finalLoser.diff!.commits, greaterThan(0));
    // The branch is deliberately kept, so the work is recoverable.
    final kept = git(repoPath, ['branch', '--list', finalLoser.branch!]).stdout;
    expect('$kept'.trim(), isNotEmpty);
    debugPrint(
      'E2E after discard + restart: ${finalLoser.agentId} '
      'worktreeRemoved=${finalLoser.worktreeRemoved} '
      'dirGone=${!Directory(loserPath).existsSync()} '
      'stat="${finalLoser.diff!.summary}" branch kept=${'$kept'.trim()}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
