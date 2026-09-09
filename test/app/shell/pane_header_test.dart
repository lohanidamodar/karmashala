import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/pane_scaffold.dart';
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/data/file_listing_service.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala/src/features/github/presentation/github_view.dart';
import 'package:karmashala/src/features/notes/presentation/notes_view.dart';
import 'package:karmashala/src/features/notifications/presentation/attention_inbox_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// One header, six surfaces.
///
/// The audit found the three that had drifted — GitHub, Files and Changes drew
/// their own padding, no ground colour and a mixed-case title at two different
/// type roles, so switching between them in the same 360px column moved the
/// divider and changed the lettering. What is asserted here is the thing a
/// reader actually sees: **the same height and the same ground everywhere**,
/// measured off the rendered frame rather than read off the source.
void main() {
  /// The pane's own width in the side panel, near its 240px floor.
  const paneWidth = 320.0;

  /// Header bar plus the hairline it owns.
  const headerHeight = Chrome.tabStrip + 1;

  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: paneWidth, child: child),
          const Expanded(child: SizedBox.shrink()),
        ],
      ),
    ),
  );

  /// The header's own box: the first [Container] under the [PaneHeader], which
  /// is the coloured bar itself rather than anything an action brought with it.
  Finder bar(Finder header) => find
      .descendant(of: header, matching: find.byType(Container))
      .first;

  void expectHouseHeader(WidgetTester tester, String surface, {Finder? header}) {
    final found = header ?? find.byType(PaneHeader);
    expect(found, findsOneWidget, reason: '$surface draws a PaneHeader');
    expect(
      tester.getSize(found).height,
      headerHeight,
      reason: '$surface: the header is $headerHeight tall like every other',
    );
    final ground = tester.widget<Container>(bar(found)).color;
    expect(
      ground,
      AppTheme.light().colorScheme.surfaceContainerLow,
      reason: '$surface: the header sits on surfaceContainerLow',
    );
    expect(
      tester.getSize(bar(found)).height,
      Chrome.tabStrip,
      reason: '$surface: the bar itself is exactly one tab-strip row',
    );
  }

  // ------------------------------------------------------------------
  // The five feature surfaces, each in the pane it actually lives in.
  // ------------------------------------------------------------------

  testWidgets('PaneScaffold — the canonical shape', (tester) async {
    await tester.pumpWidget(
      host(
        const PaneScaffold(
          title: 'Explorer',
          icon: AppIcons.folder,
          body: SizedBox.shrink(),
        ),
      ),
    );
    expectHouseHeader(tester, 'PaneScaffold');
    expect(find.text('EXPLORER'), findsOneWidget);
  });

  test('the header is dumb, and const-constructible', () {
    // Six surfaces build this. A shared widget that reached for a provider on
    // their behalf would widen all six subscription sets at once — the bug the
    // status bar's own comment records ("a process exiting anywhere used to
    // repaint this whole row"). It takes values and nothing else, and it is
    // `const` so a caller that can hold one still pays nothing to rebuild it.
    const header = PaneHeader(icon: AppIcons.folder, title: 'Files');
    expect(header, isA<StatelessWidget>());
    expect(
      header,
      isNot(isA<ConsumerWidget>()),
      reason: 'PaneHeader must not read providers for its callers',
    );
    const placeholder = PanePlaceholder(message: 'Nothing.');
    expect(placeholder, isNot(isA<ConsumerWidget>()));
  });

  testWidgets('GitHub — was 38px of padding with no ground', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          githubPullRequestsProvider.overrideWith((ref) async => const []),
          githubIssuesProvider.overrideWith((ref) async => const []),
        ],
        child: host(const GitHubView()),
      ),
    );
    await tester.pumpAndSettle();
    expectHouseHeader(tester, 'GitHub');
    expect(find.text('GITHUB'), findsOneWidget);
  });

  testWidgets('Files — was 36px of padding with no ground', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedRepoWindowsRootProvider.overrideWithValue(r'C:\src\app'),
          revealInFileManagerProvider.overrideWithValue(
            RevealInFileManager(
              host: FakeCommandRunner(),
              translator: const PathTranslator(),
              environmentFor: (id) => null,
              fileManagerOverride: HostFileManager.windowsExplorer,
            ),
          ),
          directoryListingProvider.overrideWith(
            (ref, dir) async => const <DirEntry>[],
          ),
        ],
        child: host(const FileExplorerView()),
      ),
    );
    await tester.pumpAndSettle();
    expectHouseHeader(tester, 'Files');
    expect(find.text('FILES'), findsOneWidget);
  });

  testWidgets('Changes — was 26px of padding with no ground', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryChangesProvider.overrideWith(
            (ref) async => const <FileChange>[],
          ),
          recentCommitsProvider.overrideWith((ref) async => const <GitCommit>[]),
          repositoryDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
        ],
        child: host(const ChangesView(repositoryName: 'app')),
      ),
    );
    await tester.pumpAndSettle();
    expectHouseHeader(tester, 'Changes');
    expect(find.text('CHANGES'), findsOneWidget);
  });

  group('database-backed surfaces', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.memory();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
    });
    tearDown(() => db.close());

    Widget scoped(Widget child) {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      return UncontrolledProviderScope(
        container: container,
        child: host(child),
      );
    }

    testWidgets('Notes', (tester) async {
      await tester.pumpWidget(scoped(const NotesView()));
      await tester.pumpAndSettle();
      expectHouseHeader(tester, 'Notes');
      expect(find.text('NOTES'), findsOneWidget);
    });

    testWidgets('Inbox', (tester) async {
      await tester.pumpWidget(scoped(const AttentionInboxView()));
      await tester.pumpAndSettle();
      expectHouseHeader(tester, 'Inbox');
      expect(find.text('INBOX'), findsOneWidget);
    });
  });

  testWidgets('the side panel draws the same header for a surface that has '
      'none of its own', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(SidePanelSurface.media.label));
    await tester.pumpAndSettle();

    // Media does not draw its own header, so this is `_SidePanelHeader` — the
    // sixth site, measured through the real shell rather than in isolation.
    expectHouseHeader(
      tester,
      'the side panel',
      header: find.ancestor(
        of: find.text('MEDIA'),
        matching: find.byType(PaneHeader),
      ),
    );
  });

  // ------------------------------------------------------------------
  // The empty state, with and without its new slots.
  // ------------------------------------------------------------------

  testWidgets('PanePlaceholder draws the message alone by default', (
    tester,
  ) async {
    await tester.pumpWidget(host(const PanePlaceholder(message: 'Nothing.')));

    expect(find.text('Nothing.'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PanePlaceholder),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
    final style = tester.widget<Text>(find.text('Nothing.')).style;
    expect(
      style?.color,
      AppTheme.light().colorScheme.onSurfaceVariant,
      reason: 'an empty state is muted — the GitHub one was not, and it was '
          'the only full-contrast empty state in the app',
    );
  });

  testWidgets('PanePlaceholder draws an icon at the hero size', (tester) async {
    await tester.pumpWidget(
      host(
        const PanePlaceholder(
          message: 'Nothing needs you.',
          icon: AppIcons.checkCircle,
        ),
      ),
    );

    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byType(PanePlaceholder),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.size, Chrome.iconHero);
    expect(icon.color, AppTheme.light().colorScheme.onSurfaceVariant);
  });

  testWidgets('PanePlaceholder colours the glyph only when asked', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        PanePlaceholder(
          message: 'Nothing needs you.',
          icon: AppIcons.checkCircle,
          iconColor: SemanticColors.forBrightness(Brightness.light).idle,
        ),
      ),
    );

    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byType(PanePlaceholder),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.color, SemanticColors.forBrightness(Brightness.light).idle);
  });

  testWidgets('PanePlaceholder shows a way out when there is one', (
    tester,
  ) async {
    var pressed = 0;
    await tester.pumpWidget(
      host(
        PanePlaceholder(
          message: 'No repository yet.',
          icon: AppIcons.folder,
          action: FilledButton(
            onPressed: () => pressed++,
            child: const Text('Add one'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Add one'));
    expect(pressed, 1);
  });

  // ------------------------------------------------------------------
  // The minimum window, at the text sizes the settings screen offers.
  // ------------------------------------------------------------------

  testWidgets('the header survives the window matrix in a narrow pane', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: () => MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 240,
              child: PaneScaffold(
                title: 'A rather long pane title',
                icon: AppIcons.folder,
                actions: [
                  IconButton(
                    tooltip: 'Refresh',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(AppIcons.arrowsClockwise),
                    onPressed: () {},
                  ),
                ],
                body: const PanePlaceholder(
                  message: 'Nothing here yet.',
                  icon: AppIcons.folder,
                ),
              ),
            ),
          ),
        ),
      ),
      because: 'the side panel is as narrow as 240px, and the header row is a '
          'fixed 30px that text scaling does not grow',
    );
  });

  testWidgets('the header holds its shape from 125% to 200% text', (
    tester,
  ) async {
    // The settings screen offers 125%; Windows\' own "make text bigger" goes
    // further, and macOS and Linux have their own. `Chrome.tabStrip` is a
    // fixed row that the scaler does not grow, so this is where it would clip.
    await expectSurvivesWindowMatrix(
      tester,
      matrix: const [
        WindowCell('720x560 @ 1.25x text', Size(720, 560), textScale: 1.25),
        WindowCell('720x560 @ 1.5x text', Size(720, 560), textScale: 1.5),
        WindowCell('720x560 @ 2x text', Size(720, 560), textScale: 2.0),
      ],
      build: () => MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 240,
              child: PaneScaffold(
                title: 'Changes',
                icon: AppIcons.gitDiff,
                actions: [
                  IconButton(
                    tooltip: 'Refresh',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(AppIcons.arrowsClockwise),
                    onPressed: () {},
                  ),
                ],
                body: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
      because: 'the header row is a fixed 30px and the eyebrow inside it is '
          'not',
    );
  });

  testWidgets('the three rebuilt surfaces survive the window matrix', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: () => ProviderScope(
        overrides: [
          githubPullRequestsProvider.overrideWith((ref) async => const []),
          githubIssuesProvider.overrideWith((ref) async => const []),
          selectedRepoWindowsRootProvider.overrideWithValue(r'C:\src\app'),
          revealInFileManagerProvider.overrideWithValue(
            RevealInFileManager(
              host: FakeCommandRunner(),
              translator: const PathTranslator(),
              environmentFor: (id) => null,
              fileManagerOverride: HostFileManager.windowsExplorer,
            ),
          ),
          directoryListingProvider.overrideWith(
            (ref, dir) async => const <DirEntry>[],
          ),
          repositoryChangesProvider.overrideWith(
            (ref) async => const <FileChange>[],
          ),
          recentCommitsProvider.overrideWith((ref) async => const <GitCommit>[]),
          repositoryDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 240, child: GitHubView()),
                SizedBox(width: 240, child: FileExplorerView()),
                Expanded(child: ChangesView(repositoryName: 'app')),
              ],
            ),
          ),
        ),
      ),
      because: 'all three now draw the fixed-height house header',
    );
  });
}
