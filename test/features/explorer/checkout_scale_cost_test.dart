import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/session_card.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **What a project costs per recorded checkout**, at the size the owner's
/// workspace actually reached.
///
/// The report that prompted this: a `project_rescan` took one project from
/// **1** recorded checkout to **69** — a hub, a dozen sibling clones and ~25
/// `wt-*` worktrees — and the app began to hang. Every one of those 69 is a WSL
/// path reached from Windows over `\\wsl.localhost`, where a single stat costs
/// 1.19 ms against 0.07 ms for a local path, so a git process there is not a
/// rounding error. Correlation is not cause, so this file measures instead of
/// assuming.
///
/// Counted, not timed, for the reason `test/features/terminal/scale_curve_test.dart`
/// gives: absolute milliseconds on a shared machine are noise, and a count is
/// the deterministic half of the shape. Three points — 1, 10 and 69 — so a
/// regression reads as a slope. The unit is the **git subprocess**, because
/// that is what crossing the 9p boundary charges for.
///
/// **What it found, before the fix** (git subprocesses, by number of recorded
/// checkouts):
///
/// | checkouts | collapsed | expanded | rows drawn | per workspace mutation |
/// |---|---|---|---|---|
/// | 1  | 5   | 6   | 1  | 6   |
/// | 10 | 50  | 60  | 10 | 60  |
/// | 69 | 345 | 414 | 13 | 414 |
///
/// Exactly linear: **six git processes per recorded checkout**, 414 of them to
/// draw thirteen visible rows, and the whole 414 again on every workspace
/// mutation — a session starting, stopping or changing status. 345 of them ran
/// with the project *collapsed*, drawing nothing at all. Two causes, both now
/// fixed: `projectSummaryProvider` used `ref.watch` on an `autoDispose` family,
/// which **creates** rather than reads, and the tree ran one `git worktree
/// list` per repository row.
///
/// The invariant the assertions encode, and the rule `docs/ARCHITECTURE.md`
/// already holds the terminal to: work must be proportional to what is
/// **visible**, not to what is recorded. Since the Explorer now lists sessions
/// and not checkouts, that invariant is **flatness in the checkout count** —
/// the same cost at 69 checkouts as at 1, not merely a smaller slope.
void main() {
  /// The three points the curve is read at. One checkout is the "did we make
  /// the ordinary project worse" control; 69 is the owner's real number.
  const scale = [1, 10, 69];

  late AppDatabase db;
  late FakeCommandRunner git;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    AgentInstallationDao(db).insert(agentInstallation());
    git = FakeCommandRunner(responder: _git);
  });
  tearDown(() => db.close());

  /// [count] checkouts in one project: the hub itself, then sibling clones
  /// beside it — the shape a rescan of a workspace hub records. Each is an
  /// independent repository, which is the conservative case: folding worktrees
  /// under an owner removes *rows*, never the git that discovered them.
  ///
  /// One session on the hub, so the tree has something to place and the
  /// measurement is of checkouts rather than of an empty project.
  void seed(int count) {
    RepositoryDao(db).insert(repository(id: 'r0', name: 'hub', path: r'C:\hub'));
    for (var i = 1; i < count; i++) {
      RepositoryDao(db).insert(
        repository(id: 'r$i', name: 'clone$i', path: r'C:\hub\clone' '$i'),
      );
    }
    SessionDao(db).insert(
      Session(
        id: 'n0',
        repositoryId: 'r0',
        agentInstallationId: 'a1',
        title: 'Native 0',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        externalSessionId: 'native-ext-0',
      ),
    );
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required bool expand,
  }) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    if (expand) {
      await tester.tap(find.text('Hub'));
      await tester.pumpAndSettle();
    }
    return container;
  }

  /// Git subprocesses so far, split by subcommand — the breakdown says *which*
  /// fan-out is the expensive one, which a single total cannot.
  Map<String, int> gitCounts() {
    final counts = <String, int>{};
    for (final request in git.requests) {
      // Every call is `git -C <dir> …`; the subcommand is what identifies it.
      final args = request.arguments.skip(2).toList();
      if (args.isEmpty) continue;
      final key = args.length > 1 && (args.first == 'worktree' ||
              args.first == 'remote' ||
              args.first == 'rev-list' ||
              args.first == 'rev-parse')
          ? '${args[0]} ${args[1]}'
          : args.first;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  int totalGit() => git.requests.length;

  group('a collapsed project', () {
    // Filled by the cases below so the *shape* can be asserted across them
    // rather than inside any one of them.
    final gitByScale = <int, int>{};

    for (final count in scale) {
      testWidgets('$count checkouts', (tester) async {
        seed(count);
        await pump(tester, expand: false);
        final rows = tester.widgetList(find.byType(SessionCard)).length;
        gitByScale[count] = totalGit();
        // ignore: avoid_print
        print(
          'CHECKOUT-COST collapsed checkouts=$count '
          'git=${totalGit()} rows=$rows detail=${gitCounts()}',
        );
        // Nothing is expanded, so nothing is drawn — and nothing recorded may
        // be paid for.
        expect(rows, 0, reason: 'a collapsed project draws no session cards');
      });
    }

    testWidgets('costs no git per recorded checkout', (tester) async {
      // The three cases above ran first and filled the map.
      expect(gitByScale.keys.toSet(), scale.toSet());
      // ignore: avoid_print
      print('CHECKOUT-COST collapsed curve=$gitByScale');
      // The invariant: a header the user has not opened draws nothing, so it
      // must ask git nothing — at any number of recorded checkouts.
      expect(
        gitByScale.values.toSet(),
        {0},
        reason:
            'a collapsed project ran git ($gitByScale) — work proportional to '
            'what is recorded rather than to what is visible',
      );
    });
  });

  group('an expanded project', () {
    final gitByScale = <int, int>{};
    final rowsByScale = <int, int>{};

    for (final count in scale) {
      testWidgets('$count checkouts', (tester) async {
        seed(count);
        await pump(tester, expand: true);
        final rows = tester.widgetList(find.byType(SessionCard)).length;
        gitByScale[count] = totalGit();
        rowsByScale[count] = rows;
        // ignore: avoid_print
        print(
          'CHECKOUT-COST expanded checkouts=$count '
          'git=${totalGit()} rows=$rows detail=${gitCounts()}',
        );
      });
    }

    testWidgets('costs git per visible row, not per checkout', (tester) async {
      expect(gitByScale.keys.toSet(), scale.toSet());
      // ignore: avoid_print
      print(
        'CHECKOUT-COST expanded curve=$gitByScale rows=$rowsByScale',
      );
      // The project holds one session at every scale, so it draws one card at
      // every scale: rows follow sessions, not the repositories table.
      expect(
        rowsByScale.values.toSet(),
        {1},
        reason: 'the panel drew a row per recorded checkout ($rowsByScale)',
      );
      // Git is charged for the session card that is actually on screen — the
      // same handful of processes whether the project has 1 checkout or 69.
      expect(
        gitByScale.values.toSet(),
        {gitByScale[1]},
        reason:
            'expanding a project cost $gitByScale git processes — a fan-out '
            'proportional to what is recorded rather than to what is drawn',
      );
    });
  });

  group('one workspace mutation', () {
    final gitByScale = <int, int>{};

    for (final count in scale) {
      testWidgets('$count checkouts', (tester) async {
        seed(count);
        final container = await pump(tester, expand: true);
        // Warm: everything the first frame wanted has been asked for.
        final before = totalGit();
        container.read(sessionsRevisionProvider.notifier).bump();
        await tester.pumpAndSettle();
        gitByScale[count] = totalGit() - before;
        // ignore: avoid_print
        print(
          'CHECKOUT-COST mutation checkouts=$count '
          'git=${gitByScale[count]}',
        );
      });
    }

    testWidgets('re-reads only what is on screen', (tester) async {
      expect(gitByScale.keys.toSet(), scale.toSet());
      // ignore: avoid_print
      print('CHECKOUT-COST mutation curve=$gitByScale');
      // A session starting or ending bumps this revision, so it happens
      // constantly. If it costs a git pass over every recorded checkout,
      // ordinary use of the app is a subprocess storm — which is exactly what
      // the owner reported as a freeze.
      expect(
        gitByScale.values.toSet(),
        {gitByScale[1]},
        reason:
            'one workspace mutation cost $gitByScale git processes — '
            'proportional to what is recorded',
      );
    });
  });
}

/// Enough of a real git for every provider on the path to complete rather than
/// fold into "nothing to say" — an erroring fake would measure the error path.
CommandResult _git(CommandRequest request) {
  // Every call arrives as `git -C <dir> …`; the subcommand starts at index 2.
  final joined = request.arguments.skip(2).join(' ');
  if (joined.startsWith('worktree list')) {
    // The directory is the `-C` argument, not `workingDirectory`, which
    // `GitService` never sets.
    final path = request.arguments[1];
    return CommandResult(
      exitCode: 0,
      stdout: 'worktree ${path.replaceAll(r'\', '/')}\nbranch refs/heads/main\n',
      stderr: '',
    );
  }
  if (joined.startsWith('status')) {
    return const CommandResult(
      exitCode: 0,
      stdout: '## main...origin/main\n M lib/a.dart\n',
      stderr: '',
    );
  }
  if (joined.startsWith('remote get-url')) {
    return const CommandResult(
      exitCode: 0,
      stdout: 'https://github.com/acme/hub.git\n',
      stderr: '',
    );
  }
  if (joined.startsWith('rev-parse --abbrev-ref origin/HEAD')) {
    return const CommandResult(exitCode: 0, stdout: 'origin/main\n', stderr: '');
  }
  if (joined.startsWith('rev-list --left-right')) {
    return const CommandResult(exitCode: 0, stdout: '0\t2\n', stderr: '');
  }
  if (joined.startsWith('diff --numstat')) {
    return const CommandResult(
      exitCode: 0,
      stdout: '10\t2\tlib/a.dart\n',
      stderr: '',
    );
  }
  return const CommandResult(exitCode: 0, stdout: '', stderr: '');
}
