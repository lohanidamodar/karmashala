import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/data/file_listing_service.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_dao.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

const _long =
    'An exceptionally long project name that will never fit a narrow pane';

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

void main() {
  AppDatabase seeded() {
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
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
        ),
      );
    }
    return db;
  }

  Widget explorer(double width) {
    final db = seeded();
    addTearDown(db.close);
    return ProviderScope(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
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
      child: _column(width, const ExplorerPanel()),
    );
  }

  Future<void> openProject(WidgetTester tester) async {
    await tester.tap(find.text(_long));
    await tester.pumpAndSettle();
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
