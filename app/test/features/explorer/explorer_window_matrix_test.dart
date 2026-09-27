import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:flutter/material.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_scope_bar.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';
import 'package:karmashala_files/values.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../../support/window_matrix.dart';
import '../file_explorer/explorer_fixture.dart';
import '../terminal/fake_instance.dart';

const _long =
    'An exceptionally long project name that will never fit a narrow pane';

/// One session waiting, so the project's second line has its whole state to
/// fit: running and needs-you, beside a deep path and a long branch.
class _Inbox extends AttentionInboxController {
  @override
  AttentionInbox build() => AttentionInbox(
    items: [
      InboxItem(
        session: const WatchedSession(
          key: AgentSessionKey('claude-code', 's1'),
          label: 'Waiting',
          openId: 's1',
          imported: false,
        ),
        kind: InboxItemKind.finished,
        at: testTime,
      ),
    ],
  );
}

/// A branch longer than its share of any line.
CommandResult _git(CommandRequest request) => CommandResult(
  exitCode: 0,
  stdout: request.arguments.contains('status')
      ? porcelainV2(
          branch: 'feature/a-branch-name-longer-than-its-share-of-the-line',
          ahead: 12,
          modified: ['lib/a.dart', 'lib/b.dart'],
        )
      : '',
  stderr: '',
);

/// The Explorer where the shell puts it: a column [width] wide on the left.
Widget _column(double width, Widget surface) => MaterialApp(
  theme: AppTheme.light(),
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: LayoutBuilder(
      builder: (context, c) => Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: c.maxHeight - 52,
          child: Material(child: surface),
        ),
      ),
    ),
  ),
);

const _longHost = 'a-build-box-with-a-long-host-name';

void main() {
  late FakeDataServer server;
  late DataClient data;

  /// The workspace rows every cell shares, and the one client they read.
  Future<void> serve() async {
    server = FakeDataServer();
    server.workspaceRows.insert(
      Workspace(
        id: 'w1',
        name: 'A context with a long name',
        createdAt: testTime,
      ),
    );
    server.projectRows.insert(
      project(id: 'p1', name: _long, path: r'C:\src\a\very\deep\path\p1'),
    );
    server.projectRows.insert(
      project(id: 'p2', name: 'Filed', path: r'C:\src\p2', workspaceId: 'w1'),
    );
    server.projectRows.insert(
      project(
        id: 'p3',
        name: 'Remote',
        path: '/srv/a/very/deep/path/p3',
        environmentId: 'ssh:h1',
        workspaceId: 'w1',
      ),
    );
    server.repositoryRows.insert(
      repository(
        id: 'r1',
        projectId: 'p1',
        path: r'C:\src\a\very\deep\path\p1',
      ),
    );
    data = await server.connect();
  }

  TestMachine seeded({bool third = false}) {
    final db = TestMachine();
    server.environmentRows.upsert(windowsEnv());
    // A third: the strip is at its widest, and has a WSL mark in it.
    if (third) server.environmentRows.upsert(wslEnv());
    // A second machine: the switcher joins the search row, and every project
    // names its machine on line two — both with a name too long to fit.
    server.sshHostRows.upsert(
      SshHost(
        id: 'h1',
        name: _longHost,
        host: 'build.example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
        createdAt: testTime,
      ),
    );
    server.environmentRows.upsert(sshEnvFixture(name: _longHost));
    server.runsOn(db);
    server.installationRows.insert(agentInstallation());
    for (var i = 0; i < 4; i++) {
      db.server.sessionRows.insert(
        session(
          id: 's$i',
          title: 'A session title long enough to need truncating, number $i',
          status: i == 0 ? SessionStatus.running : SessionStatus.completed,
        ),
      );
    }
    return db;
  }

  Widget explorer(double width, {bool working = false, bool third = false}) {
    final db = seeded(third: third);
    return ProviderScope(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        dataClientProvider.overrideWithValue(data),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(responder: _git),
          ),
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
        attentionInboxProvider.overrideWith(_Inbox.new),
        if (working)
          projectWorkingCountsProvider.overrideWithValue(const {'p1': 1}),
      ],
      child: _column(width, const ExplorerPanel()),
    );
  }

  Future<void> openProject(WidgetTester tester) async {
    await tester.tap(find.text(_long));
    await tester.pumpAndSettle();
    // The control: line two is there, with its state, to be squeezed.
    expect(find.byType(ProjectDetailLine), findsWidgets);
    expect(find.byType(ProjectStateBadge), findsNWidgets(2));
  }

  testWidgets('the Explorer at its 200px minimum, a project open', (
    tester,
  ) async {
    await serve();
    await expectSurvivesWindowMatrix(
      tester,
      build: () => explorer(200),
      warmUp: openProject,
      because: 'the shell lets the Explorer column shrink to 200px',
    );
  });

  testWidgets('the Explorer at a 240px side-panel width, a project open', (
    tester,
  ) async {
    await serve();
    await expectSurvivesWindowMatrix(
      tester,
      build: () => explorer(240),
      warmUp: openProject,
      because: 'a side panel is 240px at the minimum window',
    );
  });

  // The same column with everything the polish pass added on it at once: the
  // switcher saying "All", a project whose running mark is turning, and a row
  // the arrow keys have put the focus ring on — at 2x text as well.
  for (final width in [200.0, 240.0]) {
    testWidgets('the Explorer at ${width.toInt()}px with a session working '
        'and a row focused by the arrow keys, up to 2x text', (tester) async {
      await serve();
      await expectSurvivesWindowMatrix(
        tester,
        build: () => explorer(width, working: true),
        matrix: const [
          ...windowMatrix,
          WindowCell('720x560 @ 2x text', Size(720, 560), textScale: 2),
        ],
        warmUp: (tester) async {
          await openProject(tester);
          expect(find.byType(WorkingSpinner), findsOneWidget);
          Focus.of(tester.element(find.text(_long))).requestFocus();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          expect(
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<SessionCard>(),
            isNotNull,
            reason: 'the arrow key moved onto the first session',
          );
        },
      );
      // The spinner's clock is a real timer: stopped with the last spinner.
      await tester.pumpWidget(const SizedBox());
    });
  }

  // Three machines is the strip at its widest — four segments, one of them
  // named longer than the column — on a row of its own under the field,
  // glyphs alone when the segments are under the floor, up to 2x text.
  for (final width in [200.0, 240.0]) {
    testWidgets('the Explorer at ${width.toInt()}px with three machines, up '
        'to 2x text', (tester) async {
      await serve();
      await expectSurvivesWindowMatrix(
        tester,
        build: () => explorer(width, third: true),
        matrix: const [
          ...windowMatrix,
          WindowCell('720x560 @ 2x text', Size(720, 560), textScale: 2),
        ],
        warmUp: (tester) async {
          await openProject(tester);
          expect(find.byType(ExplorerEnvironmentStrip), findsOneWidget);
          expect(
            find.bySemanticsLabel(RegExp('^Environment: $_longHost\$')),
            findsOneWidget,
            reason: 'the long name is a segment, whole to a screen reader',
          );
          final strip = tester.getSize(find.byType(ExplorerEnvironmentStrip));
          expect(strip.width, lessThanOrEqualTo(width));
          expect(strip.height, Chrome.control);
        },
      );
    });
  }

  testWidgets('the Files panel at 240px with long names', (tester) async {
    const root = r'C:\src\app';
    await expectSurvivesWindowMatrix(
      tester,
      build: () => ProviderScope(
        // Every folder lists the same eight long names, so an opened one
        // draws them a level in.
        overrides: explorerOverrides(
          root,
          const {},
          list: (dir) => [
            for (var i = 0; i < 8; i++)
              FileEntry(
                name: 'a-file-with-a-name-far-too-long-for-the-panel-$i.dart',
                path: dir.copyWith(path: '${dir.path}\\entry-$i'),
                kind: i < 3 ? FileEntryKind.directory : FileEntryKind.file,
              ),
          ],
        ),
        child: _column(240, const FileExplorerView()),
      ),
      warmUp: (tester) async {
        await tester.tap(find.textContaining('panel-0.dart'));
        await tester.pumpAndSettle();
      },
    );
  });
}
