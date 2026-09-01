import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/process/path_translator.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/project_card.dart';
import 'package:karmashala/src/features/explorer/presentation/session_card.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/repositories/domain/discovered_repository.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_lineage.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala/src/features/repositories/application/repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The Explorer drawn as a tree: **Project → Session**, and deliberately
/// nothing between them.
///
/// The fixture is still the owner's own workspace — a hub folder that is itself
/// a git repository and holds a dozen clones — and the question these tests
/// exist to keep answered is still *which sub-directory is that agent working
/// in*. What changed is where it is answered. Loop 58 answered it with a row
/// per checkout; a `project_rescan` then recorded 69 of them and the panel
/// charged six git subprocesses each to draw thirteen visible rows, on WSL
/// paths over 9p, again on every workspace mutation — the freeze the owner
/// reported, measured in `checkout_scale_cost_test.dart`. The repository,
/// worktree and "not scanned yet" rows are gone with it, and the answer now
/// lives on the session's own card, as the sub-path it works in.
///
/// So what is covered here is the panel as it now is: every clone's sessions
/// listed under the one project header, each still saying where it is; lineage;
/// the menus and the keyboard's path to them; and the layout at the widths the
/// pane is actually dragged between.
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
          checkoutPresenceProbeProvider.overrideWithValue(
            FakeCheckoutPresenceProbe(),
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
    testWidgets('every clone\'s sessions list under the one project header', (
      tester,
    ) async {
      // The inversion of what this file used to assert. Three clones used to be
      // three rows, and the sessions hung off them; now the clones are not rows
      // at all — the hub, `app` and `lib` are nowhere in the pane — and all
      // three sessions sit directly under the one header. The user still tells
      // them apart, because the fact that identifies the work travelled with
      // the session onto its own card.
      addSession('s1', repositoryId: 'r1', title: 'On the hub');
      addSession('s2', repositoryId: 'r2', title: 'On app');
      addSession('s3', repositoryId: 'r3', title: 'On lib');
      await pump(tester);

      expect(find.byType(ProjectCard), findsOneWidget);
      expect(find.byType(SessionCard), findsNWidgets(3));
      expect(find.text('hub'), findsNothing);
      expect(find.text('app'), findsNothing);
      expect(find.text('lib'), findsNothing);

      expect(find.text('On the hub'), findsOneWidget);
      expect(find.text('On app'), findsOneWidget);
      expect(find.text('On lib'), findsOneWidget);

      // The owner's question, answered on the card itself: this agent is
      // working in `projects/app`, not merely "somewhere in Hub".
      expect(find.textContaining('projects/app'), findsOneWidget);
      expect(find.textContaining('projects/lib'), findsOneWidget);
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

    testWidgets('a session in a folder no scan recorded still says where', (
      tester,
    ) async {
      // Loop 50 §8.4's real case, which used to be drawn as a "not scanned yet"
      // row between the repository and the session: a checkout made outside the
      // repository's own environment, which Windows git will not list and
      // discovery never recorded. There is no row for it any more, and there
      // does not need to be — the session knows its own directory, so the card
      // still names the place rather than the nearest thing we happened to have
      // a row for.
      addSession(
        's1',
        repositoryId: 'r2',
        title: 'In an unknown checkout',
        worktree: at(r'C:\hub\projects\app\vendor\pinned'),
      );
      await pump(tester);

      expect(find.text('In an unknown checkout'), findsOneWidget);
      expect(
        find.textContaining('projects/app/vendor/pinned'),
        findsOneWidget,
        reason: 'the whole sub-path, not the recorded repository above it',
      );
    });
  });

  group('cost', () {
    // The curve — what a project costs as the number of *recorded* checkouts
    // grows — is measured at three scales in `checkout_scale_cost_test.dart`.
    // What is left here is the invariant that file does not exercise, because
    // it holds one session fixed and varies the checkouts: many sessions in one
    // working tree.
    testWidgets('twenty sessions in one repository share one git status', (
      tester,
    ) async {
      // The rule Loop 50 established, and the reason the delivery providers are
      // keyed by the checkout rather than by the session: however many cards
      // describe one working tree, it is asked once.
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
        reason: 'one working tree, one `git status` — twenty cards share it',
      );
    });
  });

  group('worktrees', () {
    testWidgets('a session in a worktree names the worktree, not its repo', (
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
      // Its sub-path is the worktree, not the repository it belongs to — and
      // the glyph that says "this has a checkout of its own" is on that card
      // alone, so the two sessions cannot be confused for each other.
      expect(find.textContaining('wt-side'), findsOneWidget);
      expect(find.byTooltip('Runs in its own worktree'), findsOneWidget);
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
    /// The desktop gesture. The overflow button on a pointer surface is only
    /// drawn under the pointer or the keyboard (see `explorer_row_test.dart`),
    /// and a right-click is what it duplicates — so the menu's *contents* are
    /// asserted through the gesture that always works.
    Future<void> openMenu(WidgetTester tester, Finder row) async {
      await tester.tap(row, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

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

    testWidgets('the project card offers reveal and copy path', (tester) async {
      // The folder verbs used to sit on the repository row; the project header
      // is the only row that names a directory now, so it is where they are.
      await pump(tester, expand: false);
      await openMenu(tester, find.byType(ProjectCard));

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
      await pump(tester, expand: false);
      await openMenu(tester, find.byType(ProjectCard));

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

      await openMenu(
        tester,
        find.ancestor(
          of: find.text('Remote'),
          matching: find.byType(ProjectCard),
        ),
      );

      expect(find.text('Copy path'), findsOneWidget);
      expect(find.text('Open in File Explorer'), findsNothing);
    });

    testWidgets('the project menu can rescan for repositories', (tester) async {
      await pump(tester, expand: false);
      await openMenu(tester, find.byType(ProjectCard));
      expect(find.text('Rescan for repositories'), findsOneWidget);
    });

    testWidgets('and running it scans and says what it found', (tester) async {
      // `ProjectService.rediscover` had never had a caller until the tree grew
      // this entry. The tree row that used to advertise it — a folder drawn as
      // "not scanned yet" — is gone, so the project menu is now the only way a
      // repository created after the import reaches the workspace, and it has
      // to report what it did.
      discovery.result = [
        DiscoveredRepository(name: 'hub', path: at(r'C:\hub')),
        DiscoveredRepository(name: 'app', path: at(r'C:\hub\projects\app')),
        DiscoveredRepository(name: 'lib', path: at(r'C:\hub\projects\lib')),
        DiscoveredRepository(
          name: 'pinned',
          path: at(r'C:\hub\projects\app\vendor\pinned'),
        ),
      ];
      await pump(tester, expand: false);
      await openMenu(tester, find.byType(ProjectCard));

      await tester.tap(find.text('Rescan for repositories'));
      await tester.pumpAndSettle();

      expect(discovery.calls, isNotEmpty);
      // Three of the four were already recorded, so one is news.
      expect(find.text('Found 1 repository.'), findsOneWidget);
    });

    testWidgets('Shift+F10 opens a row menu with no pointer at all', (
      tester,
    ) async {
      // The keyboard's own path to the same menu, in the panel rather than in a
      // hosted row, and now on the only row kind the tree has below the header:
      // hiding the overflow button until it is wanted is only honest while this
      // works.
      addSession('s1', repositoryId: 'r1', title: 'Reachable');
      await pump(tester);
      expect(find.text('Rename'), findsNothing);
      Focus.of(tester.element(find.text('Reachable'))).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
    });
  });

  group('the pane reads as one column', () {
    testWidgets('the search field is inset to the row tiles\' own edges', (
      tester,
    ) async {
      await pump(tester);
      // The tile is the outermost decorated box in a row; see
      // `explorer_row_test.dart`.
      final tile = tester.getRect(
        find
            .descendant(
              of: find.byType(ProjectCard),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final field = tester.getRect(find.byType(TextField));

      expect(field.left, tile.left);
      expect(field.right, tile.right);
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

    testWidgets('a session card keeps its change count at the default width', (
      tester,
    ) async {
      // 304px is what the Explorer opens at. A single width gate above it once
      // left every row with nothing at all on its right — no branch, no count —
      // which only showed up when the app was actually run. The rows that gate
      // belonged to are gone, but the card inherited their right-hand fact, and
      // the default width is still the one nobody looks at.
      addSession('s1', repositoryId: 'r2', title: 'Counted');
      await pump(tester, size: const Size(304, 900));

      expect(tester.takeException(), isNull);
      expect(find.text('3 changed'), findsOneWidget);
    });

    testWidgets('and the branch joins the sub-path when the pane is wider', (
      tester,
    ) async {
      // Line three is one run of text rather than a set of separately-gated
      // facts, so what widens with the pane is how much of it survives the
      // ellipsis, not which facts are built. This is the width at which both
      // halves of the answer — where the work is, and on what branch — are
      // there to be read.
      addSession('s1', repositoryId: 'r2', title: 'Wide');
      await pump(tester, size: const Size(460, 900));

      expect(tester.takeException(), isNull);
      expect(find.textContaining('projects/app  ·  main'), findsOneWidget);
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

    testWidgets('a long title and a deep sub-path truncate rather than '
        'overflowing', (tester) async {
      // Both of the card's long strings at once, at the narrowest the pane
      // clamps to: the title, which is the only thing identifying the session,
      // and the sub-path of a clone buried five folders down, which is the
      // string a hub project makes long.
      RepositoryDao(db).insert(
        repository(
          id: 'r4',
          name: 'clone',
          path: r'C:\hub\projects\very\deeply\nested\clone',
        ),
      );
      addSession(
        's1',
        repositoryId: 'r4',
        title: 'a-session-title-far-longer-than-any-pane-is-wide',
      );
      await pump(tester, size: const Size(200, 900));

      expect(tester.takeException(), isNull);
      expect(
        find.text('a-session-title-far-longer-than-any-pane-is-wide'),
        findsOneWidget,
      );
      expect(
        find.textContaining('projects/very/deeply/nested/clone'),
        findsOneWidget,
      );
    });
  });
}

/// Three changed files and a branch, for whatever directory is asked about.
CommandResult _defaultGit(CommandRequest request) {
  final args = request.arguments;
  final dir = args.length > 1 ? args[1] : '';
  if (args.contains('status')) {
    // `--porcelain=v1 --branch` puts git's `## <branch>` header first, and
    // since Loop 67 that header is where every row reads its branch from.
    final header = args.contains('--branch')
        ? '## ${dir.contains('wt-side') ? 'feature/side' : 'main'}\n'
        : '';
    return CommandResult(
      exitCode: 0,
      stdout: '$header M lib/a.dart\n?? lib/b.dart\n M lib/c.dart\n',
      stderr: '',
    );
  }
  if (args.contains('--abbrev-ref')) {
    return const CommandResult(exitCode: 0, stdout: 'main\n', stderr: '');
  }
  return const CommandResult(exitCode: 0, stdout: '', stderr: '');
}
