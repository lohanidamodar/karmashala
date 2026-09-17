import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/checkout.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_state.dart';
import 'package:karmashala/src/features/explorer/application/project_head.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// A disk that is a map, and keeps what it was asked for. A branch name is
/// file reads and nothing else, so everything else throws.
class HeadFiles implements GitFiles {
  HeadFiles(this.contents);

  final Map<String, String> contents;
  final reads = <String>[];

  @override
  Future<String?> readString(String path) async {
    reads.add(path);
    return contents[path];
  }

  @override
  Future<bool> exists(String path) => throw UnsupportedError('exists $path');

  @override
  Future<PathEntry> typeOf(String path) async => PathEntry.none;

  @override
  Future<void> createDirectory(String path) =>
      throw UnsupportedError('mkdir $path');

  @override
  Future<void> writeString(String path, String contents) =>
      throw UnsupportedError('write $path');
}

/// **A project says which branch it is on without anyone having asked git.**
///
/// The branch used to be *borrowed* only — shown while an open session card or
/// the Changes panel happened to be reading that checkout — so most rows had
/// none. It is read from the repository's own `HEAD` file now: for one
/// repository, on this machine, for a row that is built, and again only when
/// something that moves a branch has happened.
void main() {
  late AppDatabase db;
  late HeadFiles files;
  late FakeCommandRunner git;

  void seed() {
    ExecutionEnvironmentDao(db)
      ..upsert(posixEnv())
      ..upsert(wslEnv())
      ..upsert(sshEnvFixture());
    SshHostDao(db).upsert(
      SshHost(
        id: 'h1',
        name: 'build-box',
        host: 'build.example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
        createdAt: testTime,
      ),
    );
    AgentInstallationDao(db).insert(agentInstallation());
    void add(
      String id,
      String name,
      String path, {
      String environmentId = 'windows',
      List<String>? repositories,
    }) {
      ProjectDao(db).insert(
        project(id: id, name: name, path: path, environmentId: environmentId),
      );
      final paths = repositories ?? [path];
      for (var i = 0; i < paths.length; i++) {
        RepositoryDao(db).insert(
          repository(
            id: 'r-$id-$i',
            projectId: id,
            name: 'repo$i',
            path: paths[i],
            environmentId: environmentId,
          ),
        );
      }
    }

    add('app', 'app', '/w/app');
    add('polish', 'polish', '/w/app-polish');
    add('pinned', 'pinned', '/w/pinned');
    add('notes', 'notes', '/w/notes');
    add('mono', 'mono', '/w/mono', repositories: ['/w/mono/a', '/w/mono/b']);
    add('distro', 'distro', '/home/me/distro', environmentId: 'wsl:Ubuntu');
    add('relay', 'relay', '/srv/relay', environmentId: 'ssh:h1');
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r-app-0',
        agentInstallationId: 'a1',
        title: 'Session',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: testTime,
        externalSessionId: 'ext-1',
      ),
    );
  }

  setUp(() {
    db = AppDatabase.memory();
    files = HeadFiles({
      '/w/app/.git/HEAD': 'ref: refs/heads/main\n',
      '/w/app-polish/.git': 'gitdir: /w/app/.git/worktrees/app-polish\n',
      '/w/app/.git/worktrees/app-polish/HEAD': 'ref: refs/heads/ui/polish\n',
      '/w/pinned/.git/HEAD': '9f21420b8c1d4e5f60718293a4b5c6d7e8f90123\n',
      '/w/mono/a/.git/HEAD': 'ref: refs/heads/a\n',
      '/w/mono/.git/HEAD': 'ref: refs/heads/root\n',
      '/home/me/distro/.git/HEAD': 'ref: refs/heads/never-read\n',
      '/srv/relay/.git/HEAD': 'ref: refs/heads/never-read\n',
    });
    git = FakeCommandRunner(
      responder: (request) => request.arguments.contains('status')
          ? CommandResult(
              exitCode: 0,
              stdout: porcelainV2(branch: 'from-git', modified: ['a.dart']),
              stderr: '',
            )
          : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
  });
  tearDown(() => db.close());

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool details = true,
    void Function()? alsoSeed,
  }) async {
    // Wide: the test font is a square per glyph, and the branch is kept only
    // beside a path that still fits.
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    seed();
    alsoSeed?.call();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db, gitFiles: files),
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
    if (!details) {
      container
          .read(settingsControllerProvider.notifier)
          .setExplorerProjectDetails(false);
    }
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
    return container;
  }

  Finder onRow(String project, String text) => find.descendant(
    of: find.widgetWithText(ProjectCard, project),
    matching: find.text(text),
  );

  List<String> headReads(String root) => [
    for (final path in files.reads)
      if (path == '$root/.git/HEAD' || path == '$root/.git') path,
  ];

  testWidgets('every local project with one repository names its branch, and '
      'no git ran for it', (tester) async {
    await pump(tester);

    expect(onRow('app', 'main'), findsOneWidget);
    expect(
      onRow('polish', 'ui/polish'),
      findsOneWidget,
      reason: 'a worktree\'s .git is a file naming its git directory',
    );
    expect(
      onRow('pinned', '9f21420'),
      findsOneWidget,
      reason: 'a detached HEAD is its short sha',
    );
    expect(git.requests, isEmpty, reason: 'a process was spawned for a branch');
  });

  testWidgets('a folder that is not a repository, and a project with several, '
      'name none', (tester) async {
    await pump(tester);

    final notes = tester.widget<ProjectCard>(
      find.widgetWithText(ProjectCard, 'notes'),
    );
    expect(notes.summary.branch, isNull);
    final mono = tester.widget<ProjectCard>(
      find.widgetWithText(ProjectCard, 'mono'),
    );
    expect(
      mono.summary.branch,
      isNull,
      reason: 'no one branch is the project\'s',
    );
    expect(headReads('/w/mono'), isEmpty);
  });

  testWidgets('a WSL or an SSH project is never read from disk', (
    tester,
  ) async {
    await pump(tester);

    expect(find.widgetWithText(ProjectCard, 'distro'), findsOneWidget);
    expect(find.widgetWithText(ProjectCard, 'relay'), findsOneWidget);
    expect(headReads('/home/me/distro'), isEmpty);
    expect(headReads('/srv/relay'), isEmpty);
    expect(find.text('never-read'), findsNothing);
  });

  testWidgets('a share is never read, whichever machine it is filed under', (
    tester,
  ) async {
    const share = r'\\wsl.localhost\Ubuntu\src\unc';
    files.contents['$share\\.git\\HEAD'] = 'ref: refs/heads/never-read\n';
    await pump(
      tester,
      alsoSeed: () {
        ProjectDao(db).insert(project(id: 'unc', name: 'unc', path: share));
        RepositoryDao(
          db,
        ).insert(repository(id: 'r-unc', projectId: 'unc', path: share));
      },
    );

    expect(find.widgetWithText(ProjectCard, 'unc'), findsOneWidget);
    expect(
      files.reads.where((path) => path.contains('wsl.localhost')),
      isEmpty,
    );
  });

  testWidgets('it is read once: a rebuild, a fold and a row coming back on '
      'screen read nothing', (tester) async {
    final container = await pump(tester);
    expect(headReads('/w/app'), ['/w/app/.git/HEAD']);
    files.reads.clear();

    // The row leaves the tree, its provider is disposed, and it comes back.
    final search = container.read(explorerSearchQueryProvider.notifier);
    search.set('polish');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ProjectCard, 'app'), findsNothing);
    search.set('');
    await tester.pumpAndSettle();

    expect(onRow('app', 'main'), findsOneWidget);
    expect(files.reads, isEmpty);
  });

  testWidgets('the window coming back to the front reads the rows on screen '
      'again, and shows a branch switched elsewhere', (tester) async {
    final container = await pump(tester);
    files.reads.clear();
    files.contents['/w/app/.git/HEAD'] = 'ref: refs/heads/hotfix\n';

    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pumpAndSettle();
    expect(files.reads, isEmpty, reason: 'leaving reads nothing');
    container.read(windowFocusedProvider.notifier).set(true);
    await tester.pumpAndSettle();

    expect(onRow('app', 'hotfix'), findsOneWidget);
    expect(headReads('/w/app'), ['/w/app/.git/HEAD']);
    expect(headReads('/w/mono'), isEmpty);
    expect(git.requests, isEmpty);
  });

  testWidgets('a turn ending in a project reads that project again, and no '
      'other', (tester) async {
    final container = await pump(tester);
    files.reads.clear();
    files.contents['/w/app/.git/HEAD'] = 'ref: refs/heads/agent/fix\n';

    final turns = container.read(projectTurnsEndedProvider.notifier);
    turns.state = {'app': 1};
    await tester.pumpAndSettle();

    expect(onRow('app', 'agent/fix'), findsOneWidget);
    expect(files.reads, ['/w/app/.git/HEAD']);
  });

  testWidgets('a reading of the checkout arriving wins, reads that HEAD again '
      'and wakes that row alone', (tester) async {
    final container = await pump(tester);
    Map<String, int> cards() => {
      for (final card in tester.widgetList<ProjectCard>(
        find.byType(ProjectCard),
      ))
        card.name: identityHashCode(card),
    };

    // Opening the project mounts its session card, and *that* reads git.
    container.read(explorerExpandedProjectsProvider.notifier).open('app');
    await tester.pumpAndSettle();
    expect(git.requests, isNotEmpty);
    expect(
      onRow('app', 'from-git'),
      findsOneWidget,
      reason: 'the borrowed reading knows more, so it is the one shown',
    );
    expect(onRow('app', 'main'), findsNothing);

    final before = cards();
    files.reads.clear();
    final checkout = Checkout(
      const EnvironmentPath(environmentId: 'windows', path: '/w/app'),
    );
    container.read(checkoutReadingsProvider.notifier).arrived(checkout);
    await tester.pumpAndSettle();

    expect(files.reads, ['/w/app/.git/HEAD']);
    final after = cards();
    expect(
      [
        for (final entry in after.entries)
          if (before[entry.key] != entry.value) entry.key,
      ].where((name) => name != 'app'),
      isEmpty,
    );
  });

  testWidgets('with project details off there is no branch to draw, and no '
      'file is read for one', (tester) async {
    await pump(tester, details: false);

    expect(find.widgetWithText(ProjectCard, 'app'), findsOneWidget);
    expect(files.reads, isEmpty);
  });
}
