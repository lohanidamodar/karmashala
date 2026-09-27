import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_state.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **A project says which branch it is on without anyone having run git.**
///
/// The branch used to be *borrowed* only — shown while an open session card or
/// the Changes panel happened to be reading that checkout — so most rows had
/// none. The server reads the repository's own `HEAD` file (`git.head`; which
/// checkouts it can read that way is its to decide, `server/test/git/`): for
/// one repository, for a row that is built, and again only when something
/// that moves a branch has happened.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  /// What each checkout's `HEAD` names, as the server reads it.
  final heads = <String, String?>{};

  /// Every `HEAD` the app asked the server for, by path.
  List<String> reads() => [
    for (final request in server.gitWork.asked)
      if (request case GitHead(:final checkout)) checkout.directory!.path,
  ];

  /// Every request of the server's that runs git.
  List<String> gitRan() => [
    for (final kind in server.gitWork.kinds)
      if (kind != GitHead.name) kind,
  ];

  void seed() {
    server.environmentRows
      ..upsert(posixEnv())
      ..upsert(wslEnv())
      ..upsert(sshEnvFixture());
    server.sshHostRows.upsert(
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
    server.installationRows.insert(agentInstallation());
    void add(
      String id,
      String name,
      String path, {
      String environmentId = 'windows',
      List<String>? repositories,
    }) {
      server.projectRows.insert(
        project(id: id, name: name, path: path, environmentId: environmentId),
      );
      final paths = repositories ?? [path];
      for (var i = 0; i < paths.length; i++) {
        server.repositoryRows.insert(
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
    db.server.sessionRows.insert(
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
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    heads
      ..clear()
      ..addAll({
        '/w/app': 'main',
        '/w/app-polish': 'ui/polish',
        '/w/pinned': '9f21420',
      });
    server.gitWork.answer = (request) => switch (request) {
      GitHead(:final checkout) => heads[checkout.directory!.path],
      _ => FakeGitWork.unhandled,
    };
    server.gitWork.deliveries[Checkout(
      const EnvironmentPath(environmentId: 'windows', path: '/w/app'),
    )] = const SessionDelivery(
      branch: 'from-git',
      dirtyFiles: 1,
    );
  });

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
        ...fakeTerminalOverrides(machine: db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
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
    for (final path in reads())
      if (path == root) path,
  ];

  testWidgets('every project with one repository names its branch, and no '
      'git ran for it', (tester) async {
    await pump(tester);

    expect(onRow('app', 'main'), findsOneWidget);
    expect(onRow('polish', 'ui/polish'), findsOneWidget);
    expect(onRow('pinned', '9f21420'), findsOneWidget);
    expect(gitRan(), isEmpty, reason: 'git was asked for a branch');
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

  testWidgets('it is read once: a rebuild, a fold and a row coming back on '
      'screen read nothing', (tester) async {
    final container = await pump(tester);
    expect(headReads('/w/app'), ['/w/app']);
    server.gitWork.asked.clear();

    // The row leaves the tree, its provider is disposed, and it comes back.
    final search = container.read(explorerSearchQueryProvider.notifier);
    search.set('polish');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ProjectCard, 'app'), findsNothing);
    search.set('');
    await tester.pumpAndSettle();

    expect(onRow('app', 'main'), findsOneWidget);
    expect(reads(), isEmpty);
  });

  testWidgets('the window coming back to the front reads the rows on screen '
      'again, and shows a branch switched elsewhere', (tester) async {
    final container = await pump(tester);
    server.gitWork.asked.clear();
    heads['/w/app'] = 'hotfix';

    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pumpAndSettle();
    expect(reads(), isEmpty, reason: 'leaving reads nothing');
    container.read(windowFocusedProvider.notifier).set(true);
    await tester.pumpAndSettle();

    expect(onRow('app', 'hotfix'), findsOneWidget);
    expect(headReads('/w/app'), ['/w/app']);
    expect(headReads('/w/mono'), isEmpty);
    expect(gitRan(), isEmpty);
  });

  testWidgets('a turn ending in a project reads that project again, and no '
      'other', (tester) async {
    await pump(tester);
    server.gitWork.asked.clear();
    heads['/w/app'] = 'agent/fix';

    // The server tells every client where a turn ended.
    server.gitWork.touch(
      const EnvironmentPath(environmentId: 'windows', path: '/w/app'),
      cause: CheckoutTouchCause.turnEnded,
    );
    await tester.pumpAndSettle();

    expect(onRow('app', 'agent/fix'), findsOneWidget);
    expect(reads(), ['/w/app']);
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
    expect(gitRan(), contains(GitDelivery.name));
    expect(
      onRow('app', 'from-git'),
      findsOneWidget,
      reason: 'the borrowed reading knows more, so it is the one shown',
    );
    expect(onRow('app', 'main'), findsNothing);

    final before = cards();
    server.gitWork.asked.clear();
    final checkout = Checkout(
      const EnvironmentPath(environmentId: 'windows', path: '/w/app'),
    );
    container.read(checkoutReadingsProvider.notifier).arrived(checkout);
    await tester.pumpAndSettle();

    expect(reads(), ['/w/app']);
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
    expect(reads(), isEmpty);
  });
}
