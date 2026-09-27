@Tags(['cost'])
library;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_nodes.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_state.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_project_row.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **What a project's second line costs.** It shows more than the one-line row
/// did — path, branch, what is running — so this pins that it shows it for
/// free: no row is built that is not on screen, no git is run for it, a
/// session's tick redraws one project, and nothing the tree does not draw
/// recomputes the tree. Counted, never timed (`scale_harness.dart`).
const _projects = 1000;

/// Every repository is on `main`, and every read is kept: the branch on a
/// project's line is a file read, so what is counted is files.
class _EveryHead {
  final reads = <String>[];

  /// The server's answer to `git.head`, kept.
  Object? answer(GitWorkRequest<Object?> request) {
    if (request is! GitHead) return FakeGitWork.unhandled;
    reads.add(request.checkout.directory!.path);
    return 'main';
  }
}

void main() {
  late FakeCommandRunner git;
  late _EveryHead files;

  CountingMachine seed(FakeDataServer server) {
    final db = CountingMachine();
    server.runsOn(db);
    server.environmentRows.upsert(posixEnv());
    server.installationRows.insert(agentInstallation());
    for (var i = 0; i < _projects; i++) {
      // Padded: projects list by creation and then id, and these share a time.
      final p = '$i'.padLeft(4, '0');
      final path = '/Users/me/Documents/projects/client-$p/workspace-$p';
      server.projectRows.insert(
        project(id: 'p$p', name: 'Project $p', path: path),
      );
      server.repositoryRows.insert(
        repository(id: 'r$p', projectId: 'p$p', name: 'repo', path: path),
      );
      // Sessions on the first screenful only: the rest are there to be
      // scrolled past, not counted.
      if (i >= 12) continue;
      for (var s = 0; s < 2; s++) {
        db.server.sessionRows.insert(
          Session(
            id: 'p$p-s$s',
            repositoryId: 'r$p',
            agentInstallationId: 'a1',
            title: 'Session $s of project $p',
            useWorktree: false,
            status: SessionStatus.completed,
            createdAt: testTime.add(Duration(minutes: s)),
            externalSessionId: 'ext-$p-$s',
          ),
        );
      }
    }
    return db;
  }

  Future<
    ({ProviderContainer container, CountingMachine db, FakeDataServer server})
  >
  pump(
    WidgetTester tester,
  ) async {
    // Wide, because the test font is a square per glyph and the branch is
    // kept only beside a path that still fits.
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final server = FakeDataServer();
    final db = seed(server);
    files = _EveryHead();
    server.gitWork.answer = files.answer;
    git = FakeCommandRunner(
      responder: (request) {
        if (request.arguments.contains('status')) {
          return CommandResult(
            exitCode: 0,
            stdout: porcelainV2(branch: 'feature/line', modified: ['a.dart']),
            stderr: '',
          );
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
    );
    server.gitWork.runner = git;
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: ExplorerPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container: container, db: db, server: server);
  }

  Map<String, int> cards(WidgetTester tester) => {
    for (final card in tester.widgetList<ProjectCard>(find.byType(ProjectCard)))
      card.name: identityHashCode(card),
  };

  List<String> rebuilt(Map<String, int> before, Map<String, int> after) => [
    for (final entry in after.entries)
      if (before[entry.key] != entry.value) entry.key,
  ];

  testWidgets('a thousand projects build a screenful of second lines, and a '
      'fling builds no more', (tester) async {
    await pump(tester);

    int lines() => tester.widgetList(find.byType(ProjectDetailLine)).length;
    final atRest = lines();
    expect(atRest, greaterThan(5), reason: 'the line really is drawn');
    expect(atRest, lessThanOrEqualTo(60));
    expect(
      lines(),
      tester.widgetList(find.byType(ExplorerProjectRow)).length,
      reason: 'one line per project row, and none without a row',
    );

    await tester.fling(
      find.byType(ListView),
      const Offset(0, -600),
      6000,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('Project 0000'), findsNothing, reason: 'it did scroll');
    expect(lines(), lessThanOrEqualTo(60));
    expect(git.requests, isEmpty, reason: 'a project line ran git');
  });

  testWidgets('a thousand projects read a screenful of HEAD files, one each, '
      'and spawn nothing for a branch', (tester) async {
    await pump(tester);

    // Those on screen and those the list keeps built just off it.
    final built = tester
        .widgetList(find.byType(ExplorerProjectRow, skipOffstage: false))
        .length;
    expect(
      find.descendant(
        of: find.widgetWithText(ProjectCard, 'Project 0003'),
        matching: find.text('main'),
      ),
      findsOneWidget,
      reason: 'the branch really is drawn',
    );
    expect(files.reads.toSet(), hasLength(files.reads.length), reason: 'once');
    expect(files.reads, hasLength(built), reason: 'one file per row built');
    expect(files.reads.length, lessThanOrEqualTo(60));
    expect(git.requests, isEmpty, reason: 'a branch spawned a process');

    // A fling reads the rows it builds and no others; coming back reads none.
    await tester.fling(
      find.byType(ListView),
      const Offset(0, -600),
      6000,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    final afterFling = files.reads.length;
    expect(afterFling, lessThan(_projects ~/ 2));
    expect(files.reads.toSet(), hasLength(afterFling));
    await tester.fling(
      find.byType(ListView),
      const Offset(0, 600),
      6000,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Project 0000'),
      findsOneWidget,
      reason: 'back at the top',
    );
    expect(files.reads, hasLength(afterFling), reason: 'answered from cache');
    expect(git.requests, isEmpty);
  });

  testWidgets('a session\'s tick redraws its own project\'s row and no other', (
    tester,
  ) async {
    final harness = await pump(tester);
    final before = cards(tester);
    expect(before.keys, contains('Project 0003'));

    harness.db.server.sessionRows.updateStatus(
      'p0003-s0',
      SessionStatus.running,
    );
    harness.container
        .read(sessionsRevisionProvider.notifier)
        .changed(const SessionChange.statusChanged('p0003-s0'));
    await tester.pump();

    expect(rebuilt(before, cards(tester)), ['Project 0003']);
    expect(
      find.descendant(
        of: find.widgetWithText(ProjectCard, 'Project 0003'),
        matching: find.text('1 running'),
      ),
      findsOneWidget,
      reason: 'the control: the row that did rebuild drew the new state',
    );
    expect(git.requests, isEmpty);
  });

  testWidgets('a reading arriving for one project wakes that row alone, and '
      'the line borrows it rather than running git again', (tester) async {
    final harness = await pump(tester);
    var treeChanges = 0;
    harness.container.listen(explorerTreeProvider, (_, _) => treeChanges++);

    // Opening the project mounts its session cards, and *they* read git.
    harness.container
        .read(explorerExpandedProjectsProvider.notifier)
        .open('p0002');
    await tester.pumpAndSettle();
    expect(treeChanges, 1, reason: 'the fold itself');
    final asked = git.requests.length;
    expect(asked, greaterThan(0));
    expect(
      find.descendant(
        of: find.widgetWithText(ProjectCard, 'Project 0002'),
        matching: find.textContaining('feature/line'),
      ),
      findsOneWidget,
    );

    final before = cards(tester);
    harness.db.reset();
    files.reads.clear();
    // A second arrival: a turn ended there, and the server says so.
    harness.server.gitWork.touch(
      const EnvironmentPath(
        environmentId: 'windows',
        path: '/Users/me/Documents/projects/client-0002/workspace-0002',
      ),
      cause: CheckoutTouchCause.turnEnded,
    );
    await tester.pumpAndSettle();

    expect(treeChanges, 1, reason: 'a reading is not a change of shape');
    expect(files.reads.toSet(), {
      '/Users/me/Documents/projects/client-0002/workspace-0002',
    }, reason: 'the one HEAD the reading is about, and no other row\'s');
    expect(
      rebuilt(before, cards(tester)).where((name) => name != 'Project 0002'),
      isEmpty,
    );
  });

  testWidgets('an unrelated settings write recomputes no tree and redraws no '
      'project', (tester) async {
    final harness = await pump(tester);
    var treeChanges = 0;
    harness.container.listen(explorerTreeProvider, (_, _) => treeChanges++);
    final before = cards(tester);
    harness.db.reset();

    harness.container
        .read(settingsControllerProvider.notifier)
        .setCompactDensity(false);
    await tester.pump();

    expect(treeChanges, 0);
    expect(rebuilt(before, cards(tester)), isEmpty);
    expect(
      harness.db.reads.where((sql) => !sql.contains('app_metadata')),
      isEmpty,
    );
  });

  testWidgets('a path is cut once, not once per tree', (tester) async {
    final harness = await pump(tester);
    ProjectNode node() => harness.container
        .read(explorerTreeProvider)
        .nodes
        .whereType<ProjectNode>()
        .firstWhere((node) => node.project.id == 'p0005');

    final first = node();
    harness.container
        .read(explorerExpandedProjectsProvider.notifier)
        .toggle('p0001');
    await tester.pump();
    final second = node();

    expect(identical(first, second), isFalse, reason: 'the tree was rebuilt');
    expect(identical(first.pathCandidates, second.pathCandidates), isTrue);
    expect(second.pathCandidates.last, '…/workspace-0005');
  });
}
