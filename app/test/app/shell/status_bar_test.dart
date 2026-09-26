import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/app/shell/status_bar.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_tab.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/agents/usage_fixtures.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// The window's status bar as a user meets it: what each item says, what it
/// opens, and what gives way first when the window narrows.
void main() {
  const repoName = 'karmashala-app-desktop-shell';

  /// A git that answers a branch two files dirty and one commit unpushed.
  FakeCommandRunner git() => FakeCommandRunner(
    responder: (request) {
      final args = request.arguments;
      if (args.contains('status')) {
        return CommandResult(
          exitCode: 0,
          stdout: porcelainV2(
            branch: 'feature/cards',
            upstream: 'origin/feature/cards',
            ahead: 1,
            behind: 0,
            modified: ['lib/a.dart', 'lib/b.dart'],
          ),
          stderr: '',
        );
      }
      if (args.contains('--abbrev-ref')) {
        return const CommandResult(
          exitCode: 0,
          stdout: 'feature/cards\n',
          stderr: '',
        );
      }
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    },
  );

  ProviderContainer barContainer({
    int attention = 0,
    bool onWsl = false,
    AgentActivityStatus? agent,
  }) {
    final db = seedUsageDatabase();
    addTearDown(db.close);
    if (onWsl) ExecutionEnvironmentDao(db).upsert(wslEnv());
    RepositoryDao(db).insert(
      repository(
        id: 'r2',
        name: repoName,
        environmentId: onWsl ? 'wsl:Ubuntu' : 'windows',
        path: onWsl ? '/home/me/src/shell' : r'C:\s',
      ),
    );
    final runner = git();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
        hostCommandRunnerProvider.overrideWithValue(runner),
        attentionCountProvider.overrideWithValue(attention),
        if (agent != null)
          paneAgentActivityProvider.overrideWith((ref, paneId) => agent),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r2');
    return container;
  }

  Widget bar(ProviderContainer container, {bool reducedMotion = false}) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reducedMotion),
            child: child!,
          ),
          home: const Scaffold(
            body: Column(children: [Spacer(), ShellStatusBar()]),
          ),
        ),
      );

  Future<void> pumpAt(
    WidgetTester tester,
    ProviderContainer container,
    Size size, {
    double textScale = 1,
    bool reducedMotion = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(bar(container, reducedMotion: reducedMotion));
    await tester.pumpAndSettle();
  }

  Future<void> quiesce(WidgetTester tester, ProviderContainer container) async {
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
  }

  void openTabs(ProviderContainer container, int count) {
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    for (var i = 0; i < count; i++) {
      terminals.openTab(TerminalProfile.powerShell);
    }
  }

  /// Closes the first tab with history on screen, so it is kept running.
  void detachFirstTab(ProviderContainer container) {
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tab = container.read(terminalSessionsControllerProvider).tabs.first;
    giveShellHistory(terminals.instanceFor(tab.focusedPaneId)!);
    terminals.closeTab(tab.id);
  }

  Finder inBar(Finder finder) =>
      find.descendant(of: find.byType(ShellStatusBar), matching: finder);

  Finder tooltipContaining(String text) => inBar(
    find.byWidgetPredicate(
      (w) =>
          w is Tooltip &&
          ((w.message ?? w.richMessage?.toPlainText()) ?? '').contains(text),
    ),
  );

  String tooltipOf(WidgetTester tester, Finder finder) {
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: finder, matching: find.byType(Tooltip)).first,
    );
    return tooltip.message ?? tooltip.richMessage!.toPlainText();
  }

  group('each item', () {
    testWidgets('carries a glyph and a word at a desktop width', (
      tester,
    ) async {
      final container = barContainer(attention: 2);
      openTabs(container, 2);
      await pumpAt(tester, container, const Size(1440, 900));

      expect(inBar(find.byIcon(AppIcons.terminal)), findsWidgets);
      expect(inBar(find.text('Windows')), findsOneWidget);
      expect(inBar(find.byIcon(AppIcons.bookBookmark)), findsOneWidget);
      expect(inBar(find.text(repoName)), findsOneWidget);
      expect(inBar(find.byIcon(AppIcons.gitBranch)), findsOneWidget);
      expect(inBar(find.text('feature/cards')), findsOneWidget);
      expect(inBar(find.text('2 need you')), findsOneWidget);
      expect(inBar(find.text('2 tabs')), findsOneWidget);
      expect(inBar(find.text('Changes')), findsOneWidget);
      expect(
        inBar(find.byIcon(AppIcons.dotsThree)),
        findsNothing,
        reason: 'nothing overflows at 1440',
      );
      await quiesce(tester, container);
    });

    testWidgets('names its action in its tooltip', (tester) async {
      final container = barContainer(attention: 1);
      await pumpAt(tester, container, const Size(1440, 900));

      expect(
        tooltipOf(tester, inBar(find.text('feature/cards'))),
        allOf(contains('feature/cards'), contains('open Changes')),
      );
      expect(
        tooltipOf(tester, inBar(find.text(repoName))),
        allOf(contains(repoName), contains('open the Repository panel')),
      );
      expect(
        tooltipOf(tester, inBar(find.text('Windows'))),
        contains('open Environments settings'),
      );
      expect(
        tooltipOf(tester, inBar(find.text('1 needs you'))),
        contains('open the Inbox'),
      );
      expect(
        tooltipOf(tester, inBar(find.text('Changes'))),
        contains('close the side panel'),
      );
      await quiesce(tester, container);
    });

    testWidgets('the branch says how dirty and how far ahead it is', (
      tester,
    ) async {
      final container = barContainer();
      await pumpAt(tester, container, const Size(1440, 900));

      expect(inBar(find.byIcon(AppIcons.pencilSimple)), findsOneWidget);
      expect(inBar(find.byIcon(AppIcons.arrowUp)), findsOneWidget);
      expect(
        tooltipOf(tester, inBar(find.text('feature/cards'))),
        allOf(contains('2 changed files'), contains('1 commit not pushed')),
      );
      await quiesce(tester, container);
    });

    testWidgets('a WSL checkout names its distribution', (tester) async {
      final container = barContainer(onWsl: true);
      await pumpAt(tester, container, const Size(1440, 900));

      expect(inBar(find.byIcon(AppIcons.terminalWindow)), findsOneWidget);
      expect(inBar(find.text('Ubuntu')), findsOneWidget);
      await quiesce(tester, container);
    });
  });

  group('state is coloured by what it means', () {
    testWidgets('attention is drawn in the attention colour, not the accent', (
      tester,
    ) async {
      final container = barContainer(attention: 3);
      await pumpAt(tester, container, const Size(1440, 900));

      final context = tester.element(find.byType(ShellStatusBar));
      final attention = SemanticColors.of(context).attention;
      final label = tester.widget<Text>(inBar(find.text('3 need you')));
      final colour =
          label.style?.color ??
          DefaultTextStyle.of(
            tester.element(inBar(find.text('3 need you'))),
          ).style.color;
      expect(colour, attention);
      expect(colour, isNot(Theme.of(context).colorScheme.primary));
      await quiesce(tester, container);
    });

    testWidgets('a background session is a count, not the accent', (
      tester,
    ) async {
      final container = barContainer();
      openTabs(container, 2);
      await pumpAt(tester, container, const Size(1440, 900));
      detachFirstTab(container);
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(ShellStatusBar));
      final label = tester.widget<Text>(inBar(find.text('1 in background')));
      final colour =
          label.style?.color ??
          DefaultTextStyle.of(
            tester.element(inBar(find.text('1 in background'))),
          ).style.color;
      expect(colour, isNot(Theme.of(context).colorScheme.primary));
      await quiesce(tester, container);
    });
  });

  group('clicks open the surface an item describes', () {
    testWidgets('the branch opens Changes', (tester) async {
      final container = barContainer();
      container.read(sidePanelProvider.notifier).collapse();
      await pumpAt(tester, container, const Size(1440, 900));

      await tester.tap(inBar(find.text('feature/cards')));
      await tester.pumpAndSettle();
      expect(container.read(sidePanelProvider), SidePanelSurface.changes);
      await quiesce(tester, container);
    });

    testWidgets('the repository opens the Repository panel', (tester) async {
      final container = barContainer();
      await pumpAt(tester, container, const Size(1440, 900));

      await tester.tap(inBar(find.text(repoName)));
      await tester.pumpAndSettle();
      expect(container.read(sidePanelProvider), SidePanelSurface.repository);
      await quiesce(tester, container);
    });

    testWidgets('the environment opens Settings on Environments', (
      tester,
    ) async {
      final container = barContainer();
      await pumpAt(tester, container, const Size(1440, 900));

      await tester.tap(inBar(find.text('Windows')));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsTabSectionProvider)?.page,
        SettingsSectionId.environments,
      );
      await quiesce(tester, container);
    });

    testWidgets('attention opens the Inbox', (tester) async {
      final container = barContainer(attention: 2);
      await pumpAt(tester, container, const Size(1440, 900));

      await tester.tap(inBar(find.text('2 need you')));
      await tester.pumpAndSettle();
      expect(container.read(sidePanelProvider), SidePanelSurface.inbox);
      await quiesce(tester, container);
    });

    testWidgets('background sessions open their list', (tester) async {
      final container = barContainer();
      openTabs(container, 2);
      await pumpAt(tester, container, const Size(1440, 900));
      detachFirstTab(container);
      await tester.pumpAndSettle();

      await tester.tap(inBar(find.text('1 in background')));
      await tester.pumpAndSettle();
      expect(find.text('Background sessions'), findsOneWidget);
      await quiesce(tester, container);
    });

    testWidgets('the keyboard reaches an item and Enter runs it', (
      tester,
    ) async {
      final container = barContainer();
      container.read(sidePanelProvider.notifier).collapse();
      await pumpAt(tester, container, const Size(1440, 900));

      // Environment, repository, branch: the third stop.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(container.read(sidePanelProvider), SidePanelSurface.changes);
      await quiesce(tester, container);
    });

    testWidgets('with no room, a panel item says so instead of doing nothing', (
      tester,
    ) async {
      final container = barContainer();
      container.read(sidePanelRoomProvider.notifier).report(false);
      await pumpAt(tester, container, const Size(1440, 900));

      expect(
        tooltipOf(tester, inBar(find.text('feature/cards'))),
        contains(kSidePanelNoRoom),
      );
      await quiesce(tester, container);
    });
  });

  group('narrowing gives way in priority order', () {
    testWidgets('1440: everything in words', (tester) async {
      final container = barContainer(attention: 2);
      openTabs(container, 3);
      await pumpAt(tester, container, const Size(1440, 900));
      expect(inBar(find.text('3 tabs')), findsOneWidget);
      expect(inBar(find.text('Windows')), findsOneWidget);
      expect(inBar(find.byIcon(AppIcons.dotsThree)), findsNothing);
      await quiesce(tester, container);
    });

    testWidgets('1000: the tab count drops its noun first', (tester) async {
      final container = barContainer(attention: 2);
      openTabs(container, 3);
      await pumpAt(tester, container, const Size(900, 900));
      expect(inBar(find.text('3 tabs')), findsNothing);
      expect(inBar(find.text('3')), findsOneWidget);
      expect(inBar(find.text('Windows')), findsOneWidget);
      expect(inBar(find.text('2 need you')), findsOneWidget);
      await quiesce(tester, container);
    });

    testWidgets('720: tabs overflow, the environment is a glyph', (
      tester,
    ) async {
      final container = barContainer(attention: 2);
      openTabs(container, 3);
      await pumpAt(tester, container, const Size(720, 560));
      expect(inBar(find.byIcon(AppIcons.dotsThree)), findsOneWidget);
      expect(inBar(find.textContaining('tab')), findsNothing);
      expect(inBar(find.text('Windows')), findsNothing);
      expect(tooltipContaining('Windows'), findsOneWidget);
      expect(inBar(find.text(repoName)), findsOneWidget);
      expect(inBar(find.text('2 need you')), findsOneWidget);
      await quiesce(tester, container);
    });

    testWidgets('640 at 2x text: context moves into the overflow menu', (
      tester,
    ) async {
      final container = barContainer(attention: 5);
      openTabs(container, 3);
      await pumpAt(tester, container, const Size(640, 900), textScale: 2);

      expect(inBar(find.text(repoName)), findsNothing);
      expect(inBar(find.text('Windows')), findsNothing);
      expect(inBar(find.text('feature/cards')), findsOneWidget);
      expect(inBar(find.text('5')), findsOneWidget, reason: 'attention stays');

      await tester.tap(inBar(find.byIcon(AppIcons.dotsThree)));
      await tester.pumpAndSettle();
      final menu = find.byWidgetPredicate((w) => w is PopupMenuItem<int>);
      expect(
        find.descendant(of: menu, matching: find.text('Windows')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: menu, matching: find.text(repoName)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: menu, matching: find.text('3 tabs')),
        findsOneWidget,
      );

      // An overflowed item still does what it did on the bar.
      await tester.tap(
        find.descendant(of: menu, matching: find.text(repoName)),
      );
      await tester.pumpAndSettle();
      expect(container.read(sidePanelProvider), SidePanelSurface.repository);
      await quiesce(tester, container);
    });

    testWidgets('nothing overflows at the small cells', (tester) async {
      final container = barContainer(attention: 12, onWsl: true);
      openTabs(container, 3);
      await expectSurvivesWindowMatrix(
        tester,
        build: () => bar(container),
        matrix: const [
          ...windowMatrix,
          WindowCell('640x900 @ 2x text', Size(640, 900), textScale: 2),
          WindowCell('1000x700', Size(1000, 700)),
        ],
        because: 'the bar must shed items rather than stripe',
      );
      await quiesce(tester, container);
    });
  });

  group('agents', () {
    testWidgets('a working agent shows the status glyph and a count', (
      tester,
    ) async {
      final container = barContainer(agent: AgentActivityStatus.working);
      openTabs(container, 2);
      await pumpAt(
        tester,
        container,
        const Size(1440, 900),
        reducedMotion: true,
      );

      expect(inBar(find.byType(StatusGlyph)), findsOneWidget);
      expect(inBar(find.text('2 working')), findsOneWidget);
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: 'under reduced motion the spinner is still',
      );
      await quiesce(tester, container);
    });
  });

  testWidgets('detaching a tab redraws the tab and background items only', (
    tester,
  ) async {
    final container = barContainer();
    openTabs(container, 2);
    await pumpAt(tester, container, const Size(1440, 900));

    ShellStatusBar.debugItemBuildCount = 0;
    detachFirstTab(container);
    await tester.pumpAndSettle();

    expect(inBar(find.text('1 in background')), findsOneWidget);
    expect(
      ShellStatusBar.debugItemBuildCount,
      2,
      reason: 'the repository, branch and panel do not read the tab list',
    );
    await quiesce(tester, container);
  });
}
