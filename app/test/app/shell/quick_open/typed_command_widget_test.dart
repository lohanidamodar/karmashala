import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/quick_open/typed_command_history.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_resume.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/new_session_memory.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala_git/repositories.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fake_data_server.dart';
import '../../../support/fixtures.dart';
import '../../../support/test_machine.dart';

/// Records the start instead of launching an agent: what is under test is that
/// the command reaches the Explorer's own start, with the right arguments.
class _RecordingExplorerActions extends ExplorerActions {
  _RecordingExplorerActions(super.ref);

  final starts = <({String repositoryId, String? installationId})>[];

  /// The opening message each start carried, in [starts]' order.
  final messages = <String?>[];

  @override
  Future<ExplorerResult> startSession({
    required Repository repository,
    EnvironmentPath? existingWorktree,
    AgentInstallation? installation,
    String? title,
    String? firstMessage,
  }) async {
    starts.add((repositoryId: repository.id, installationId: installation?.id));
    messages.add(firstMessage);
    return const ExplorerResult(ExplorerOutcome.started);
  }
}

/// Records a resume from the dashboard instead of resuming.
class _RecordingResumer extends OverviewResumer {
  _RecordingResumer(super.ref);

  final resumed = <(String, String?)>[];

  @override
  Future<ExplorerResult> resume(String sessionId, {String? message}) async {
    resumed.add((sessionId, message));
    return const ExplorerResult(ExplorerOutcome.resumed);
  }
}

void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project(name: 'Karmashala'));
    server.repositoryRows.insert(repository(name: 'app'));
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows
      ..insert(session(id: 's1', title: 'Fix login redirect'))
      ..insert(session(id: 's2', title: 'Write the release notes'));
  });

  late _RecordingExplorerActions explorer;
  late _RecordingResumer resumer;

  Future<ProviderContainer> open(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    final data = await server.override();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        data,
        explorerActionsProvider.overrideWith(_RecordingExplorerActions.new),
        overviewResumerProvider.overrideWith(_RecordingResumer.new),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    // Read up front: a test that never starts anything must not see the last
    // test's recorder.
    explorer =
        container.read(explorerActionsProvider) as _RecordingExplorerActions;
    resumer = container.read(overviewResumerProvider) as _RecordingResumer;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  String boxText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('Tab completes one argument at a time, and Enter runs the '
      'resolved command through the Explorer start', (tester) async {
    final container = await open(tester);

    await type(tester, 'start ');
    expect(find.text('COMMAND'), findsOneWidget);
    expect(find.text('Karmashala'), findsWidgets);

    await press(tester, LogicalKeyboardKey.tab);
    expect(boxText(tester), 'start Karmashala ');
    // Complete enough to run: the preview leads, with the default agent.
    expect(
      find.textContaining('Start Claude Code in Karmashala'),
      findsOneWidget,
    );
    expect(find.text('Enter to run'), findsOneWidget);

    // Tab from the preview takes the first usable agent — typed by its whole
    // name, since Claude Code · Chat shares it.
    await press(tester, LogicalKeyboardKey.tab);
    expect(boxText(tester), 'start Karmashala claude-code ');

    await press(tester, LogicalKeyboardKey.enter);

    expect(explorer.starts, [(repositoryId: 'r1', installationId: 'a1')]);
    expect(find.byType(QuickOpen), findsNothing);
    // Fully resolved, so it can be run again from an empty box.
    expect(TypedCommandHistory(server.store).list(), [
      'start Karmashala claude-code',
    ]);
    expect(container.read(selectedProjectIdProvider), 'p1');
  });

  testWidgets('a refused command is listed with its reason and Enter does '
      'nothing', (tester) async {
    await open(tester);

    await type(tester, 'start Karmashala antigravity ');
    expect(
      find.textContaining('Start Antigravity in Karmashala'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Antigravity is not installed in'),
      findsOneWidget,
    );

    await press(tester, LogicalKeyboardKey.enter);

    expect(explorer.starts, isEmpty);
    expect(find.byType(QuickOpen), findsOneWidget);
    expect(TypedCommandHistory(server.store).list(), isEmpty);
  });

  testWidgets('an uninstalled agent is shown disabled, not hidden, and Tab '
      'skips it', (tester) async {
    await open(tester);

    await type(tester, 'start Karmashala anti');
    expect(find.text('antigravity'), findsOneWidget);
    // Antigravity and Antigravity · Chat both match, and neither is installed.
    expect(find.textContaining('not installed in'), findsNWidgets(2));

    await press(tester, LogicalKeyboardKey.tab);
    expect(boxText(tester), 'start Karmashala anti');
  });

  testWidgets('resume by session name resumes it on the dashboard, with no '
      'tab', (tester) async {
    final container = await open(tester);

    await type(tester, 'resume fix');
    await press(tester, LogicalKeyboardKey.tab);
    expect(boxText(tester), 'resume fix-login-redirect ');
    expect(
      find.textContaining('Resume "Fix login redirect" in the background'),
      findsOneWidget,
    );

    await press(tester, LogicalKeyboardKey.enter);

    expect(resumer.resumed, [('s1', null)]);
    expect(container.read(selectedSessionIdProvider), isNull);
    expect(find.byType(QuickOpen), findsNothing);
    expect(TypedCommandHistory(server.store).list(), [
      'resume fix-login-redirect',
    ]);
  });

  testWidgets('an empty box offers history first; Enter runs it again', (
    tester,
  ) async {
    TypedCommandHistory(server.store).record('resume write-the-release-notes');
    await open(tester);

    expect(find.text('RECENT COMMANDS'), findsOneWidget);
    expect(find.text('resume write-the-release-notes'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.enter);

    expect(resumer.resumed, [('s2', null)]);
    expect(find.byType(QuickOpen), findsNothing);
  });

  testWidgets('plain search is unchanged: no command section, same first '
      'result', (tester) async {
    final container = await open(tester);

    for (final query in ['login', 'open settings', 'start']) {
      await type(tester, query);
      expect(find.text('COMMAND'), findsNothing, reason: query);
      expect(find.text('RECENT COMMANDS'), findsNothing, reason: query);
    }
    expect(find.text('Open Settings'), findsNothing);
    await type(tester, 'open settings');
    expect(find.text('Open Settings'), findsOneWidget);

    await type(tester, 'login');
    await press(tester, LogicalKeyboardKey.enter);
    expect(container.read(selectedSessionIdProvider), 's1');
    expect(explorer.starts, isEmpty);
  });

  group('starting a session without the dialog', () {
    testWidgets('"new karma" then Enter starts it on the defaults', (
      tester,
    ) async {
      await open(tester);

      await type(tester, 'new karma');
      expect(find.text('New session in Karmashala'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.enter);

      expect(explorer.starts, [(repositoryId: 'r1', installationId: 'a1')]);
      expect(explorer.messages, [null]);
      expect(find.byType(QuickOpen), findsNothing);
      expect(find.byType(NewSessionDialog), findsNothing);
    });

    testWidgets('the default is the agent and form last started in the '
        'project, as the dialog opens on', (tester) async {
      server.installationRows.insert(
        agentInstallation(
          id: 'a2',
          agentId: AgentIds.codex,
          path: r'C:\npm\codex.cmd',
        ),
      );
      NewSessionMemory(
        server.store,
      ).remember(projectId: 'p1', installationId: 'a2');
      await open(tester);

      await type(tester, 'new karma');
      await press(tester, LogicalKeyboardKey.enter);

      expect(explorer.starts, [(repositoryId: 'r1', installationId: 'a2')]);
    });

    testWidgets('text after a colon is the opening message', (tester) async {
      await open(tester);

      await type(tester, 'new karma: fix the login bug');
      await press(tester, LogicalKeyboardKey.enter);

      expect(explorer.starts, [(repositoryId: 'r1', installationId: 'a1')]);
      expect(explorer.messages, ['fix the login bug']);
    });

    testWidgets('"New session…" opens the dialog with what was typed', (
      tester,
    ) async {
      await open(tester);

      await type(tester, 'new karma: fix it');
      await tester.tap(find.text('New session…').first);
      await tester.pumpAndSettle();

      expect(explorer.starts, isEmpty);
      expect(find.byType(NewSessionDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NewSessionDialog),
          matching: find.text('fix it'),
        ),
        findsOneWidget,
      );
    });

    test('Ctrl+Shift+L opens quick open ready for a new session', () {
      expect(
        shellChordLabel<OpenQuickOpenIntent>(where: (i) => i.query == 'new '),
        'Ctrl+Shift+L',
      );
    });
  });
}
