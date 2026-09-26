import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/diff_tab_actions.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/git/presentation/diff_tab_view.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// **Reading a change happens in a tab; the sidebar only says what changed.**
///
/// The Changes panel used to expand each file to its diff inside a 300px
/// column, with a dialog for anyone who wanted room. What this pins is the
/// replacement: a row opens a workbench tab, one tab per file, and the tab
/// keeps showing the file it was opened on.
const _file = 'lib/src/app/shell/side_panel.dart';

/// Staged, so a diff with no base answers nothing: the row's `+1 −1` and the
/// tab's contents have to come from the same measurement (git 2.55.0).
const _stagedFile = 'lib/staged.dart';

/// git quotes this one, and the sidebar, the pane id and the pathspec all have
/// to end up with the name a human typed.
const _quotedFile = 'lib/héllo.dart';

/// Two files whose basenames are identical: the row shows the name and the
/// folder, and the folder is the only thing telling them apart.
const _twinA = 'lib/a/twin.dart';
const _twinB = 'lib/b/twin.dart';

const _diff =
    '@@ -1,3 +1,3 @@\n final a = 1;\n-final b = 2;\n+final b = 3;\n final c = 4;\n';

/// `git status --porcelain=v1` and `git diff --numstat HEAD`, spelled the way
/// git 2.55.0 spells them — the quoted path included, since undoing that is
/// half of what this file pins.
const _status =
    ' M lib/src/app/shell/side_panel.dart\n'
    'M  lib/staged.dart\n'
    ' M "lib/h\\303\\251llo.dart"\n'
    ' M lib/a/twin.dart\n'
    ' M lib/b/twin.dart\n';
const _numstat =
    '1\t1\tlib/src/app/shell/side_panel.dart\n'
    '1\t1\tlib/staged.dart\n'
    '1\t1\t"lib/h\\303\\251llo.dart"\n';

/// git as this test's repository answers. **Only a diff that named a base sees
/// the index**, which is the whole of the staged case.
CommandResult _git(CommandRequest request) {
  const nothing = CommandResult(exitCode: 0, stdout: '', stderr: '');
  final args = request.arguments.skip(2).toList();
  if (args.first == 'status') {
    return const CommandResult(exitCode: 0, stdout: _status, stderr: '');
  }
  if (args.contains('--numstat')) {
    return const CommandResult(exitCode: 0, stdout: _numstat, stderr: '');
  }
  if (args.first != 'diff' || !args.contains('--')) return nothing;
  if (args.last == _stagedFile && !args.contains('HEAD')) return nothing;
  return const CommandResult(exitCode: 0, stdout: _diff, stderr: '');
}

void main() {
  late FakeDataServer server;
  late DataClient client;
  late TestMachine db;
  late FakeCommandRunner git;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    client = await server.connect();
    server.installationRows.insert(agentInstallation());
  });

  ProviderContainer shellContainer() {
    git = FakeCommandRunner(responder: _git);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        dataClientProvider.overrideWithValue(client),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        repoWorktreesProvider.overrideWith((ref) async => const []),
        recentCommitsProvider.overrideWith((ref) async => const []),
        // Neither the listing, the counts nor `diffForTargetProvider` is
        // overridden: every one of them is what `ChangesService` asked git for,
        // which is where a staged file and a quoted path go wrong.
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<ProviderContainer> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = shellContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    // Bounded pumps, never `pumpAndSettle`: a terminal pane blinks its cursor
    // for ever, so nothing in this tree ever settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    // A checkout has to be selected before anything has changes to list.
    container
        .read(selectedRepositoryIdProvider.notifier)
        .select(repository().id);
    // `select` on the surface already showing *collapses* it — that is the
    // rail's gesture — so drive it from closed rather than through the toggle.
    container.read(sidePanelProvider.notifier).collapse();
    container.read(sidePanelProvider.notifier).select(SidePanelSurface.changes);
    await settle(tester);
    return container;
  }

  WidgetRef refOf(WidgetTester tester) =>
      tester.element(find.byType(WorkbenchView)) as WidgetRef;

  /// The sidebar's own row. Once its tab is open the chip says the same name.
  final sidebarRow = find.descendant(
    of: find.byType(ChangesView),
    matching: find.text('side_panel.dart'),
  );

  List<String> diffTabsIn(ProviderContainer container) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      if (tab.layout.panes.any(isDiffPane)) tab.id,
  ];

  testWidgets('the sidebar lists the file and shows no diff of its own', (
    tester,
  ) async {
    await launch(tester);

    expect(find.text('side_panel.dart'), findsOneWidget);
    expect(find.text('lib/src/app/shell'), findsOneWidget);
    // One per file git gave counts for; the two twins got none.
    expect(find.text('+1 −1'), findsNWidgets(3));
    expect(find.byType(DiffTabView), findsNothing);
    expect(find.text('+final b = 3;'), findsNothing);
  });

  testWidgets('clicking a row opens its diff in a tab, once', (tester) async {
    final container = await launch(tester);

    await tester.tap(sidebarRow);
    await settle(tester);

    expect(find.byType(DiffTabView), findsOneWidget);
    expect(find.text('+final b = 3;'), findsOneWidget);
    expect(diffTabsIn(container), hasLength(1));
    final tabId = diffTabsIn(container).single;
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      tabId,
    );

    // A second click is the same tab, not a second copy of the same diff.
    await tester.tap(sidebarRow);
    await settle(tester);
    expect(diffTabsIn(container), [tabId]);
  });

  testWidgets('the tab is named after the file, not the path', (tester) async {
    await launch(tester);
    refOf(tester).read(diffTabActionsProvider).open(_file);
    await settle(tester);

    // The sidebar row and the tab chip say the name; the pane header wears it
    // uppercased, like every other chrome eyebrow in the app.
    expect(find.text('side_panel.dart'), findsNWidgets(2));
    expect(find.text('SIDE_PANEL.DART'), findsOneWidget);
  });

  testWidgets('the tab keeps the checkout it was opened on', (tester) async {
    final container = await launch(tester);
    final opened = container.read(viewedCheckoutProvider);

    refOf(tester).read(diffTabActionsProvider).open(_file);
    await settle(tester);

    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .expand((tab) => tab.layout.panes)
        .firstWhere(isDiffPane);
    final target = diffTargetOf(paneId);
    expect(target, isNotNull);
    expect(target!.checkout, opened);
    expect(target.path, _file);
    // And it survives being written down, which is what restore reads back.
    expect(diffPaneIdFor(target), paneId);
  });

  /// Every `git diff` this test's app asked for, as the pathspec and whether it
  /// named a base.
  List<({String path, bool based})> diffsAsked() => [
    for (final request in git.requests)
      if (request.arguments.contains('--'))
        (
          path: request.arguments.last,
          based: request.arguments.contains('HEAD'),
        ),
  ];

  testWidgets('a staged file shows the change its row counted', (tester) async {
    await launch(tester);

    expect(find.text('staged.dart'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChangesView),
        matching: find.text('+1 −1'),
      ),
      findsNWidgets(3),
    );

    await tester.tap(find.text('staged.dart'));
    await settle(tester);

    // The row promised a change; the tab shows it, because the diff was taken
    // against HEAD. With no base git answers nothing for a staged file and the
    // pane said so about a file that is neither binary nor untracked.
    expect(find.text('+final b = 3;'), findsOneWidget);
    expect(find.textContaining('no textual diff'), findsNothing);
    final asked = diffsAsked().where((d) => d.path == _stagedFile);
    expect(asked, isNotEmpty);
    expect(asked.every((d) => d.based), isTrue);
  });

  testWidgets('a path git has to quote opens the file git meant', (
    tester,
  ) async {
    final container = await launch(tester);

    // The row wears the real name, not `h\303\251llo.dart"` with a stray quote.
    expect(find.text('héllo.dart'), findsOneWidget);

    await tester.tap(find.text('héllo.dart'));
    await settle(tester);

    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .expand((tab) => tab.layout.panes)
        .firstWhere(isDiffPane);
    expect(diffTargetOf(paneId)!.path, _quotedFile);
    expect(diffsAsked().map((d) => d.path), contains(_quotedFile));
    expect(find.text('+final b = 3;'), findsOneWidget);
  });

  testWidgets('two files with one basename are told apart by their folder', (
    tester,
  ) async {
    final container = await launch(tester);

    expect(find.text('twin.dart'), findsNWidgets(2));
    expect(find.text('lib/a'), findsOneWidget);
    expect(find.text('lib/b'), findsOneWidget);

    // Each opens its own tab, and each tab names its own file in full.
    refOf(tester).read(diffTabActionsProvider).open(_twinA);
    refOf(tester).read(diffTabActionsProvider).open(_twinB);
    await settle(tester);

    final targets = [
      for (final tab in container.read(terminalSessionsControllerProvider).tabs)
        for (final pane in tab.layout.panes)
          if (diffTargetOf(pane) case final target?) target.path,
    ];
    expect(targets, containsAll(const [_twinA, _twinB]));
  });

  testWidgets('the sidebar highlight is the tab on screen, and nothing else', (
    tester,
  ) async {
    final container = await launch(tester);

    /// The rows drawn as selected. Read off `Semantics.selected`, which is the
    /// same flag the highlight colour is drawn from.
    int highlighted() => tester
        .widgetList<Semantics>(
          find.descendant(
            of: find.byType(ChangesView),
            matching: find.byType(Semantics),
          ),
        )
        .where((row) => row.properties.selected ?? false)
        .length;

    expect(container.read(activeDiffFileProvider), isNull);
    expect(highlighted(), 0);

    final first = refOf(tester).read(diffTabActionsProvider).open(_file);
    await settle(tester);
    expect(container.read(activeDiffFileProvider), _file);
    expect(highlighted(), 1);

    refOf(tester).read(diffTabActionsProvider).open(_stagedFile);
    await settle(tester);
    expect(container.read(activeDiffFileProvider), _stagedFile);

    // Clicking the first tab's chip is what the stored selection never heard
    // about: the pane showed one file and the sidebar highlighted the other.
    container
        .read(terminalSessionsControllerProvider.notifier)
        .activateTab(first!);
    await settle(tester);
    expect(container.read(activeDiffFileProvider), _file);
    expect(highlighted(), 1);

    // Closing it hands the highlight to the tab that is now on screen, and
    // closing the last one leaves no row highlighted at all — where the stored
    // selection left the row lit for ever.
    final sessions = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    sessions.closeTab(first);
    await settle(tester);
    expect(container.read(activeDiffFileProvider), _stagedFile);

    for (final tab in diffTabsIn(container)) {
      sessions.closeTab(tab);
    }
    await settle(tester);
    expect(container.read(activeDiffFileProvider), isNull);
    expect(highlighted(), 0);
  });
}
