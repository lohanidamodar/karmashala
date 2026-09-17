import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/data/file_listing_service.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/inbox_item.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_dao.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
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
  AppDatabase seeded() {
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    // A second machine: the switcher joins the search row, and every project
    // names its machine on line two — both with a name too long to fit.
    SshHostDao(db).upsert(
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
    ExecutionEnvironmentDao(db).upsert(sshEnvFixture(name: _longHost));
    WorkspaceDao(db).insert(
      Workspace(
        id: 'w1',
        name: 'A context with a long name',
        createdAt: testTime,
      ),
    );
    ProjectDao(db).insert(
      project(id: 'p1', name: _long, path: r'C:\src\a\very\deep\path\p1'),
    );
    ProjectDao(db).insert(
      project(id: 'p2', name: 'Filed', path: r'C:\src\p2', workspaceId: 'w1'),
    );
    ProjectDao(db).insert(
      project(
        id: 'p3',
        name: 'Remote',
        path: '/srv/a/very/deep/path/p3',
        environmentId: 'ssh:h1',
        workspaceId: 'w1',
      ),
    );
    RepositoryDao(db).insert(
      repository(
        id: 'r1',
        projectId: 'p1',
        path: r'C:\src\a\very\deep\path\p1',
      ),
    );
    AgentInstallationDao(db).insert(agentInstallation());
    for (var i = 0; i < 4; i++) {
      SessionDao(db).insert(
        session(
          id: 's$i',
          title: 'A session title long enough to need truncating, number $i',
          status: i == 0 ? SessionStatus.running : SessionStatus.completed,
        ),
      );
    }
    return db;
  }

  Widget explorer(double width, {bool working = false}) {
    final db = seeded();
    addTearDown(db.close);
    return ProviderScope(
      overrides: [
        ...fakeTerminalOverrides(database: db),
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

  testWidgets('the Files panel at 240px with long names', (tester) async {
    const root = r'C:\src\app';
    await expectSurvivesWindowMatrix(
      tester,
      build: () => ProviderScope(
        overrides: [
          selectedRepoWindowsRootProvider.overrideWithValue(root),
          directoryListingProvider.overrideWith(
            (ref, dir) async => [
              for (var i = 0; i < 8; i++)
                DirEntry(
                  name: 'a-file-with-a-name-far-too-long-for-the-panel-$i.dart',
                  isDirectory: i < 3,
                  windowsPath: '$dir\\entry-$i',
                ),
            ],
          ),
          revealInFileManagerProvider.overrideWithValue(
            RevealInFileManager(
              host: FakeCommandRunner(),
              translator: const PathTranslator(),
              environmentFor: (_) => null,
              fileManagerOverride: HostFileManager.windowsExplorer,
            ),
          ),
        ],
        child: _column(240, const FileExplorerView()),
      ),
      warmUp: (tester) async {
        await tester.tap(find.textContaining('panel-0.dart'));
        await tester.pumpAndSettle();
      },
    );
  });
}
