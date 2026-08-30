import 'package:chitragupta/src/app/shell/reveal_in_file_manager.dart';
import 'package:chitragupta/src/app/theme/app_icons.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/process/path_translator.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:chitragupta/src/features/cli_detection/application/project_import_service.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/explorer/presentation/explorer_panel.dart';
import 'package:chitragupta/src/features/explorer/presentation/project_card.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/repositories/domain/discovered_repository.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_lineage.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/terminal/application/system_terminal_providers.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The Explorer drawn as a tree: **Project → Repository → Worktree → Session**.
///
/// The shape under test is the owner's own workspace — a hub folder that is
/// itself a git repository and holds a dozen clones. Before Loop 57 that was one
/// repository row with every session piled on it; the question these tests exist
/// to keep answered is *which sub-directory is that agent working in*.
void main() {
  late AppDatabase db;
  late FakeCommandRunner git;

  /// The host runner the reveal helper shells out on: its requests are the
  /// `explorer.exe <path>` calls a successful reveal makes.
  late FakeCommandRunner revealHost;
  late FakeRepositoryDiscoveryService discovery;

  /// The directory `git -C <dir> …` was pointed at.
  String dirOf(CommandRequest request) =>
      request.arguments.length > 1 ? request.arguments[1] : '';

  int statusCallsFor(String dir) => git.requests
      .where((r) => dirOf(r) == dir && r.arguments.contains('status'))
      .length;

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    RepositoryDao(db)
      ..insert(repository(id: 'r1', name: 'hub', path: r'C:\hub'))
      ..insert(repository(id: 'r2', name: 'app', path: r'C:\hub\projects\app'))
      ..insert(repository(id: 'r3', name: 'lib', path: r'C:\hub\projects\lib'));
    AgentInstallationDao(db).insert(agentInstallation());
    git = FakeCommandRunner(responder: _defaultGit);
    revealHost = FakeCommandRunner();
    discovery = FakeRepositoryDiscoveryService();
  });
  tearDown(() => db.close);

  void addSession(
    String id, {
    String repositoryId = 'r1',
    String title = 'Work',
    EnvironmentPath? worktree,
    String? parent,
    SessionLink? link,
    int minutes = 0,
  }) => SessionDao(db).insert(
    Session(
      id: id,
      repositoryId: repositoryId,
      agentInstallationId: 'a1',
      title: title,
      useWorktree: worktree != null,
      worktree: worktree,
      status: SessionStatus.running,
      createdAt: testTime.add(Duration(minutes: minutes)),
      externalSessionId: 'ext-$id',
      parentSessionId: parent,
      parentLink: link,
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(460, 900),
    bool expand = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
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
          // The real helper on a fake host: `canReveal` and the outcome then
          // behave exactly as they do in production, which is what A4's two
          // failures — a hidden entry and a reported error — turn on.
          revealInFileManagerProvider.overrideWithValue(
            RevealInFileManager(
              host: revealHost,
              translator: const PathTranslator(),
              environmentFor: (id) => ExecutionEnvironmentDao(db).getById(id),
              fileManagerOverride: HostFileManager.windowsExplorer,
            ),
          ),
          // A rescan must never walk the real filesystem from a widget test.
          repositoryDiscoveryServiceProvider.overrideWithValue(discovery),
        ],
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    if (expand) {
      await tester.tap(find.text('Hub'));
      await tester.pumpAndSettle();
    }
  }

  group('the hub case', () {
    testWidgets('each nested repository is its own row', (tester) async {
      await pump(tester);
      expect(find.text('hub'), findsOneWidget);
      expect(find.text('app'), findsOneWidget);
      expect(find.text('lib'), findsOneWidget);
      // And each says where it is, relative to the project.
      expect(find.text('projects/app'), findsOneWidget);
      expect(find.text('projects/lib'), findsOneWidget);
    });

    testWidgets('sessions land on their own repository, not in one pile', (
      tester,
    ) async {
      addSession('s1', repositoryId: 'r1', title: 'On the hub');
      addSession('s2', repositoryId: 'r2', title: 'On app');
      addSession('s3', repositoryId: 'r3', title: 'On lib');
      await pump(tester);

      expect(find.text('On the hub'), findsOneWidget);
      expect(find.text('On app'), findsOneWidget);
      expect(find.text('On lib'), findsOneWidget);

      // The owner's question, answered on the card itself: this agent is
      // working in `projects/app`, not merely "somewhere in Hub".
      expect(find.textContaining('projects/app'), findsWidgets);
    });

    testWidgets('a session at the project root shows no sub-path', (
      tester,
    ) async {
      // Nothing to say is said as nothing: a card that printed "." or the whole
      // absolute path would be noise on every row of a single-repo project.
      addSession('s1', repositoryId: 'r1', title: 'At the root');
      await pump(tester);

      final card = find.ancestor(
        of: find.text('At the root'),
        matching: find.byType(Column),
      );
      expect(card, findsWidgets);
      expect(find.textContaining('C:\\hub  ·'), findsNothing);
    });
  });

  group('cost', () {
    testWidgets('twenty sessions in one repository share one git status', (
      tester,
    ) async {
      // The rule Loop 50 established and Loop 57 re-keyed to survive worktree
      // rows: however many rows describe a working tree, it is asked once.
      for (var i = 0; i < 20; i++) {
        addSession('s$i', repositoryId: 'r2', title: 'Session $i', minutes: i);
      }
      // Tall enough that every card is really built: a viewport that culled
      // eighteen of them would pass this assertion without meaning it.
      await pump(tester, size: const Size(460, 2400));

      expect(find.text('Session 0'), findsOneWidget);
      expect(find.text('Session 19'), findsOneWidget);
      expect(
        statusCallsFor(r'C:\hub\projects\app'),
        1,
        reason: 'one working tree, one `git status` — row and cards share it',
      );
    });

    testWidgets('expanding a project lists worktrees once per repository', (
      tester,
    ) async {
      await pump(tester);
      final lists = git.requests
          .where((r) => r.arguments.contains('worktree'))
          .map(dirOf)
          .toList();
      expect(lists.toSet().length, lists.length, reason: 'no repeats');
      expect(lists.toSet(), {
        r'C:\hub',
        r'C:\hub\projects\app',
        r'C:\hub\projects\lib',
      });
    });

    testWidgets('a collapsed project asks git nothing', (tester) async {
      await pump(tester, expand: false);
      expect(
        git.requests.where((r) => r.arguments.contains('worktree')),
        isEmpty,
        reason: 'the tree is lazy: nothing is asked until a project is opened',
      );
    });
  });

  group('worktrees', () {
    setUp(() {
      git.responder = (request) {
        final dir = dirOf(request);
        if (request.arguments.contains('worktree') && dir == r'C:\hub') {
          return const CommandResult(
            exitCode: 0,
            stdout:
                'worktree C:/hub\nHEAD abc\nbranch refs/heads/main\n\n'
                'worktree C:/hub/wt-side\nHEAD def\n'
                'branch refs/heads/feature/side\n\n',
            stderr: '',
          );
        }
        if (request.arguments.contains('--abbrev-ref')) {
          return CommandResult(
            exitCode: 0,
            stdout: dir.contains('wt-side') ? 'feature/side\n' : 'main\n',
            stderr: '',
          );
        }
        return _defaultGit(request);
      };
    });

    testWidgets('a linked worktree is a row under its repository', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('wt-side'), findsOneWidget);
      expect(find.text('feature/side'), findsWidgets);
    });

    testWidgets('a session in a worktree is drawn on that worktree', (
      tester,
    ) async {
      addSession(
        's1',
        repositoryId: 'r1',
        title: 'Side work',
        worktree: at(r'C:\hub\wt-side'),
      );
      addSession('s2', repositoryId: 'r1', title: 'Main work');
      await pump(tester);

      expect(find.text('Side work'), findsOneWidget);
      // Its sub-path is the worktree, not the repository it belongs to.
      expect(find.textContaining('wt-side'), findsWidgets);
    });

    testWidgets(
      'a worktree with no repositories row of its own is still startable',
      (tester) async {
        // Loop 57 had to refuse this. `existingWorktree` pairs the owning
        // repository's id with the worktree's directory.
        await pump(tester);
        await tester.tap(find.byTooltip('New session in this worktree'));
        await tester.pumpAndSettle();

        final started = SessionDao(db).getAll();
        expect(started, hasLength(1));
        expect(started.single.worktree, at(r'C:/hub/wt-side'));
        expect(started.single.repositoryId, 'r1');
      },
    );

    testWidgets('git failing to list is said, and only once it has failed', (
      tester,
    ) async {
      git.responder = (request) => request.arguments.contains('worktree')
          ? const CommandResult(
              exitCode: 128,
              stdout: '',
              stderr: 'not a working tree',
            )
          : _defaultGit(request);
      addSession('s1', repositoryId: 'r1', title: 'Somewhere');
      await pump(tester);

      // "We could not ask" is a different fact from "there are none", and it is
      // said on the one row that is open — the two empty repositories stay shut
      // and say nothing at all.
      expect(
        find.textContaining('Worktrees could not be listed'),
        findsOneWidget,
      );
    });
  });

  group('a folder the scanner has not reached', () {
    testWidgets('is drawn between the repository and the session', (
      tester,
    ) async {
      // Loop 50 §8.4's real case: a checkout made outside the repository's own
      // environment, which Windows git will not list and discovery never
      // recorded. The session still nests where the work is.
      addSession(
        's1',
        repositoryId: 'r2',
        title: 'In an unknown checkout',
        worktree: at(r'C:\hub\projects\app\vendor\pinned'),
      );
      await pump(tester);

      expect(find.text('vendor/pinned'), findsOneWidget);
      expect(find.text('not scanned yet'), findsOneWidget);
      expect(find.text('In an unknown checkout'), findsOneWidget);
      expect(find.byTooltip('Rescan for repositories'), findsOneWidget);
    });

    testWidgets('the rescan turns it into a real repository row', (
      tester,
    ) async {
      // `ProjectService.rediscover` had never had a caller. This is the whole
      // reason the "not scanned yet" row is allowed to exist rather than being
      // persisted on sight: the scanner's job stays the scanner's.
      discovery.result = [
        DiscoveredRepository(name: 'hub', path: at(r'C:\hub')),
        DiscoveredRepository(name: 'app', path: at(r'C:\hub\projects\app')),
        DiscoveredRepository(name: 'lib', path: at(r'C:\hub\projects\lib')),
        DiscoveredRepository(
          name: 'pinned',
          path: at(r'C:\hub\projects\app\vendor\pinned'),
        ),
      ];
      addSession(
        's1',
        repositoryId: 'r2',
        title: 'Unrecorded',
        worktree: at(r'C:\hub\projects\app\vendor\pinned'),
      );
      await pump(tester);
      expect(find.text('not scanned yet'), findsOneWidget);

      await tester.tap(find.byTooltip('Rescan for repositories'));
      await tester.pumpAndSettle();

      expect(discovery.calls, isNotEmpty);
      expect(find.text('Found 1 repository.'), findsOneWidget);
      // It is a checkout now, not a folder we could only describe.
      expect(find.text('not scanned yet'), findsNothing);
      expect(find.text('pinned'), findsOneWidget);
      expect(find.text('Unrecorded'), findsOneWidget);
    });
  });

  group('lineage', () {
    testWidgets('a fork is drawn under the session it came from', (
      tester,
    ) async {
      addSession('parent', title: 'The original', minutes: 0);
      addSession(
        'child',
        title: 'The fork',
        parent: 'parent',
        link: SessionLink.fork,
        minutes: 5,
      );
      await pump(tester);

      expect(find.text('The original'), findsOneWidget);
      expect(find.text('The fork'), findsOneWidget);
      expect(find.byIcon(AppIcons.gitMerge), findsOneWidget);
      // Indented past its parent, which is what says it hangs off it.
      final parentX = tester.getTopLeft(find.text('The original')).dx;
      final childX = tester.getTopLeft(find.text('The fork')).dx;
      expect(childX, greaterThan(parentX));
    });

    testWidgets('a handoff carries its own glyph', (tester) async {
      addSession('parent', title: 'Before', minutes: 0);
      addSession(
        'child',
        title: 'After',
        parent: 'parent',
        link: SessionLink.handoff,
        minutes: 5,
      );
      await pump(tester);
      expect(find.byIcon(AppIcons.paperPlaneRight), findsOneWidget);
    });

    testWidgets('a chain that does not terminate says so', (tester) async {
      // Loop 54's rule: never drawn as a complete tree.
      addSession('a', title: 'Ring A', parent: 'b', link: SessionLink.fork);
      addSession('b', title: 'Ring B', parent: 'a', link: SessionLink.fork);
      await pump(tester);

      expect(
        find.textContaining('lineage cannot be established'),
        findsNWidgets(2),
      );
      // Both at the same depth: neither is drawn beneath the other.
      expect(
        tester.getTopLeft(find.text('Ring A')).dx,
        tester.getTopLeft(find.text('Ring B')).dx,
      );
    });
  });

  group('keyboard and menus', () {
    testWidgets('Enter on a focused project card expands it', (tester) async {
      addSession('s1', repositoryId: 'r1', title: 'Reachable');
      await pump(tester, expand: false);
      expect(find.text('Reachable'), findsNothing);

      Focus.of(tester.element(find.text('Hub'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Reachable'), findsOneWidget);
    });

    testWidgets('a repository row offers reveal and copy path', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Folder actions').first);
      await tester.pumpAndSettle();

      expect(find.text('Open in File Explorer'), findsOneWidget);
      expect(find.text('Copy path'), findsOneWidget);

      await tester.tap(find.text('Open in File Explorer'));
      await tester.pumpAndSettle();
      expect(revealHost.requests.single.executable, 'explorer.exe');
      expect(revealHost.requests.single.arguments.single, r'C:\hub');
    });

    testWidgets('a reveal that fails says so instead of going quiet', (
      tester,
    ) async {
      revealHost.throwError = CommandException('explorer.exe not found');
      await pump(tester);
      await tester.tap(find.byTooltip('Folder actions').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open in File Explorer'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.textContaining('Could not open the file manager'),
        findsOneWidget,
      );
    });

    testWidgets('an SSH row is not offered "Open in File Explorer"', (
      tester,
    ) async {
      // A path on a remote host has no host spelling at all, so the entry would
      // always fail — it must be absent, not present and inert.
      ExecutionEnvironmentDao(db).upsert(sshEnvFixture());
      ProjectDao(db).insert(
        project(
          id: 'p2',
          name: 'Remote',
          environmentId: 'ssh:h1',
          path: '/srv/work',
        ),
      );
      RepositoryDao(db).insert(
        repository(
          id: 'r4',
          projectId: 'p2',
          name: 'remote-app',
          environmentId: 'ssh:h1',
          path: '/srv/work/app',
        ),
      );
      await pump(tester, expand: false);

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Remote'),
            matching: find.byType(ProjectCard),
          ),
          matching: find.byTooltip('Project actions'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Copy path'), findsOneWidget);
      expect(find.text('Open in File Explorer'), findsNothing);
    });

    testWidgets('the project menu can rescan for repositories', (tester) async {
      await pump(tester, expand: false);
      await tester.tap(find.byTooltip('Project actions'));
      await tester.pumpAndSettle();
      expect(find.text('Rescan for repositories'), findsOneWidget);
    });
  });

  group('at the pane\'s own minimum width', () {
    testWidgets('nothing overflows and the aggregate is dropped', (
      tester,
    ) async {
      addSession('s1', repositoryId: 'r2', title: 'Narrow');
      await pump(tester, size: const Size(200, 900));

      expect(tester.takeException(), isNull);
      expect(find.text('Narrow'), findsOneWidget);
      expect(find.textContaining('1 session'), findsNothing);
    });

    testWidgets('a repository row keeps its change count at the default width', (
      tester,
    ) async {
      // 304px is what the Explorer opens at. A single width gate above it left
      // every repository row with nothing at all on its right — no branch, no
      // count — which only showed up when the app was actually run. With no
      // sessions in the fixture, the three counts here are the three rows'.
      await pump(tester, size: const Size(304, 900));

      expect(tester.takeException(), isNull);
      expect(find.text('3 changed'), findsNWidgets(3));
    });

    testWidgets('and gains the branch when the pane is dragged wider', (
      tester,
    ) async {
      await pump(tester, size: const Size(460, 900));
      expect(find.text('main'), findsNWidgets(3));
    });

    testWidgets('the header does not overflow between its two breakpoints', (
      tester,
    ) async {
      // 294px overflowed by 60: wide enough for the aggregate, not wide enough
      // for the aggregate *and* the badges *and* three buttons. The name is the
      // row's only flexible child, so the facts have to be dropped rather than
      // squeezed — and this is the width that proves it.
      addSession('s1', repositoryId: 'r1', title: 'Running');
      await pump(tester, size: const Size(294, 900));

      expect(tester.takeException(), isNull);
      expect(find.textContaining('1 session'), findsOneWidget);
      expect(find.byTooltip('1 session is running'), findsNothing);
    });

    testWidgets('a wide pane shows the running badge as well', (tester) async {
      addSession('s1', repositoryId: 'r1', title: 'Running');
      await pump(tester, size: const Size(520, 900));

      expect(tester.takeException(), isNull);
      expect(find.byTooltip('1 session is running'), findsOneWidget);
    });

    testWidgets('a long repository name truncates rather than overflowing', (
      tester,
    ) async {
      RepositoryDao(db).insert(
        repository(
          id: 'r4',
          name: 'a-repository-name-far-longer-than-any-pane-is-wide',
          path: r'C:\hub\projects\very\deeply\nested\clone',
        ),
      );
      addSession('s1', repositoryId: 'r4', title: 'Deep');
      await pump(tester, size: const Size(200, 900));

      expect(tester.takeException(), isNull);
      expect(
        find.text('a-repository-name-far-longer-than-any-pane-is-wide'),
        findsOneWidget,
      );
    });
  });
}

/// Three changed files and a branch, for whatever directory is asked about.
CommandResult _defaultGit(CommandRequest request) {
  final args = request.arguments;
  if (args.contains('status')) {
    return const CommandResult(
      exitCode: 0,
      stdout: ' M lib/a.dart\n?? lib/b.dart\n M lib/c.dart\n',
      stderr: '',
    );
  }
  if (args.contains('--abbrev-ref')) {
    return const CommandResult(exitCode: 0, stdout: 'main\n', stderr: '');
  }
  return const CommandResult(exitCode: 0, stdout: '', stderr: '');
}
