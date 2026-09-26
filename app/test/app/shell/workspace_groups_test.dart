import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../support/workspace_mirror.dart';

/// Two groups, two sessions, and the assertion that carries the whole weight:
/// **the neighbour does not move.**
///
/// A group's chrome could be wired to "the session the window is about" and
/// every single-group test would still pass — which is why a single-group test
/// is not evidence. With two groups the bug is loud: both bars show the same
/// repository state, the same model and the same usage, following whichever
/// pane was clicked last. So each case here reads *both* bars, and the switch
/// case asserts what stayed still rather than what changed.
void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    data = await server.override();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(database: db),
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        // One branch name per session, so each bar's own reading is legible in
        // the rendered tree.
        sessionDeliveryProvider.overrideWith(
          (ref, id) async => SessionDelivery(branch: 'branch-$id'),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.terminalGrid,
              evidence: const [],
              waiting: AgentWaitKind.unrecorded,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);

  /// A tab of its own running session [id].
  String openSessionTab(String id, [TerminalProfile? profile]) {
    final tabId = terminals().openTab(profile ?? TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((tab) => tab.id == tabId)
        .layout
        .panes
        .single;
    final dao = mirroredServer(db).sessionRows;
    dao.insert(session(id: id, title: 'Session $id'));
    dao.updatePaneId(id, paneId);
    return tabId;
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Two groups: `left` holding [first] and [third], `right` holding [second].
  ({String left, String right}) splitAndMove(String moved) {
    final right = terminals().splitWorkspace(SplitAxis.horizontal)!;
    terminals().moveTabToGroup(moved, right);
    final left = container
        .read(terminalSessionsControllerProvider)
        .workspace!
        .groups
        .map((group) => group.id)
        .firstWhere((id) => id != right);
    return (left: left, right: right);
  }

  testWidgets('each group\'s status bar reads its own session', (tester) async {
    final a = openSessionTab('s1');
    final b = openSessionTab('s2');
    final groups = splitAndMove(b);
    terminals().activateTab(a);

    await pump(tester);

    expect(
      find.text('branch-s1'),
      findsOneWidget,
      reason: 'the left group\'s bar, and only it',
    );
    expect(
      find.text('branch-s2'),
      findsOneWidget,
      reason: 'the right group\'s bar reads the tab it is showing',
    );
    expect(groups.left, isNot(groups.right));
  });

  testWidgets('switching a tab in one group leaves the other bar alone', (
    tester,
  ) async {
    final a = openSessionTab('s1');
    final b = openSessionTab('s2');
    final c = openSessionTab('s3');
    splitAndMove(b);
    terminals().activateTab(a);
    await pump(tester);
    expect(find.text('branch-s1'), findsOneWidget);
    expect(find.text('branch-s2'), findsOneWidget);

    terminals().activateTab(c);
    await tester.pumpAndSettle();

    // The assertion that matters. "The left bar moved to s3" would pass against
    // one app-wide focused session too; "the right bar still says s2" is what
    // only a per-group reading can satisfy.
    expect(find.text('branch-s2'), findsOneWidget);
    expect(find.text('branch-s3'), findsOneWidget);
    expect(find.text('branch-s1'), findsNothing);
  });

  testWidgets('a strip shows its own group\'s tabs and no others', (
    tester,
  ) async {
    final a = openSessionTab('s1');
    final b = openSessionTab('s2');
    openSessionTab('s3');
    splitAndMove(b);
    terminals().activateTab(a);

    await pump(tester);

    // Two chips in the left strip and one in the right. A strip reading the
    // window's whole tab list would draw three in each, for six.
    expect(find.byType(TerminalTabChip), findsNWidgets(3));
  });

  testWidgets('only the focused group\'s tab says where typing goes', (
    tester,
  ) async {
    // Two shells, so the two chips are told apart by name rather than by the
    // order the tree happens to build them in.
    final a = openSessionTab('s1');
    final b = openSessionTab('s2', TerminalProfile.commandPrompt);
    final groups = splitAndMove(b);
    terminals().activateTab(a);

    await pump(tester);

    // `toList`, because `widgetList` is lazy: read again after the focus moves
    // it would describe the tree as it is *then*, and the comparison would be
    // a list against itself.
    List<TerminalTabChip> strips() => tester
        .widgetList<TerminalTabChip>(find.byType(TerminalTabChip))
        .toList();

    final before = strips();
    expect(before, hasLength(2));
    // Both groups show which tab they hold — a group whose tab looked
    // unselected would have a terminal and a status bar belonging to nothing.
    expect(before.every((chip) => chip.selected), isTrue);
    // Exactly one says where the keyboard is, and it is the focused group's.
    expect(before.where((chip) => chip.accented), hasLength(1));
    expect(
      before.firstWhere((chip) => chip.accented).title,
      terminals().titleForTab(a),
    );

    terminals().focusGroup(groups.right);
    await tester.pumpAndSettle();

    final after = strips();
    expect(after.every((chip) => chip.selected), isTrue);
    expect(after.where((chip) => chip.accented), hasLength(1));
    expect(
      after.firstWhere((chip) => chip.accented).title,
      terminals().titleForTab(b),
      reason: 'the accent followed the focus to the other group',
    );
  });

  testWidgets('each group shows its own face, and the neighbour keeps its', (
    tester,
  ) async {
    // A tab owns a session, a terminal view, a chat view and a status strip
    // together, so which face is up belongs to the group showing that tab.
    // Three agents side by side must be able to show three transcripts.
    final a = openSessionTab('s1');
    final b = openSessionTab('s2', TerminalProfile.commandPrompt);
    final groups = splitAndMove(b);
    terminals().activateTab(a);

    await pump(tester);
    expect(container.read(terminalVisibleInGroupProvider(groups.left)), isTrue);
    expect(
      container.read(terminalVisibleInGroupProvider(groups.right)),
      isTrue,
    );

    // The left group turns to its conversation.
    terminals().showFaceIn(groups.left, terminal: false);
    await tester.pumpAndSettle();

    expect(
      container.read(terminalVisibleInGroupProvider(groups.left)),
      isFalse,
    );
    // **The assertion that carries the weight.** "The left group changed" would
    // pass against one window-wide flag too; only a per-group face leaves the
    // neighbour where it was.
    expect(
      container.read(terminalVisibleInGroupProvider(groups.right)),
      isTrue,
      reason: 'the other group is still showing its terminal',
    );
    // And the right group is still drawing a terminal, not a transcript.
    expect(find.byType(TerminalPaneView), findsWidgets);

    // Turning the right one too leaves both on chat rather than swapping them.
    terminals().showFaceIn(groups.right, terminal: false);
    await tester.pumpAndSettle();
    expect(
      container.read(terminalVisibleInGroupProvider(groups.left)),
      isFalse,
    );
    expect(
      container.read(terminalVisibleInGroupProvider(groups.right)),
      isFalse,
    );
  });

  testWidgets('the focused group is what a face command with no tab means', (
    tester,
  ) async {
    final a = openSessionTab('s1');
    final b = openSessionTab('s2', TerminalProfile.commandPrompt);
    final groups = splitAndMove(b);
    terminals().activateTab(a);
    await pump(tester);

    // `` Ctrl+` `` and the palette's Terminal view both come through here.
    terminals().toggleFaceHere();
    await tester.pumpAndSettle();

    expect(
      container.read(terminalVisibleInGroupProvider(groups.left)),
      isFalse,
      reason: 'the focused group turned',
    );
    expect(
      container.read(terminalVisibleInGroupProvider(groups.right)),
      isTrue,
    );
  });

  testWidgets('the room a split clears offers the ways to fill it', (
    tester,
  ) async {
    openSessionTab('s1');
    terminals().splitWorkspace(SplitAxis.horizontal);

    await pump(tester);

    expect(find.text('Empty group'), findsOneWidget);
    expect(find.text('New terminal'), findsOneWidget);
    expect(find.text('Close group'), findsOneWidget);
    // The tab that is already open is somewhere it could come from.
    expect(find.text('Move a tab here…'), findsOneWidget);
  });

  testWidgets('every empty group has its own invitation and way out', (
    tester,
  ) async {
    openSessionTab('s1');
    final first = terminals().splitWorkspace(SplitAxis.horizontal)!;
    final second = terminals().splitWorkspace(SplitAxis.vertical)!;

    await pump(tester);

    expect(find.text('Empty group'), findsNWidgets(2));
    expect(find.text('New terminal'), findsNWidgets(2));
    expect(find.text('Move a tab here…'), findsNWidgets(2));
    expect(find.text('Close group'), findsNWidgets(2));

    // The button drawn in a group closes that group, not the focused one.
    expect(container.read(focusedWorkspaceGroupProvider), second);
    await tester.tap(find.text('Close group').first);
    await tester.pumpAndSettle();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.workspace!.groups.map((g) => g.id), isNot(contains(first)));
    expect(terminals().isEmptyGroup(second), isTrue);
    expect(find.text('Empty group'), findsOneWidget);
  });

  testWidgets('a terminal started from one empty group opens in that one', (
    tester,
  ) async {
    openSessionTab('s1');
    final first = terminals().splitWorkspace(SplitAxis.horizontal)!;
    final second = terminals().splitWorkspace(SplitAxis.vertical)!;
    await pump(tester);

    await tester.tap(find.text('New terminal').first);
    await tester.pumpAndSettle();

    expect(terminals().tabsInGroup(first), hasLength(1));
    expect(terminals().isEmptyGroup(second), isTrue);
    expect(find.text('Empty group'), findsOneWidget);
  });

  testWidgets('a workspace split to its floor survives the window matrix', (
    tester,
  ) async {
    openSessionTab('s1');
    // The smallest group a split can leave: a sixteenth of each axis.
    for (final axis in SplitAxis.values) {
      for (var i = 0; i < 4; i++) {
        expect(terminals().splitWorkspace(axis), isNotNull);
      }
      expect(terminals().canSplitWorkspace(axis), isFalse);
    }

    await expectSurvivesWindowMatrix(
      tester,
      build: () => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
      // Tab is the shell's once it reaches the one terminal, so the ring ends
      // there by design — the same with a single empty group beside a tab.
      checkFocus: false,
      because: 'a held split chord reaches this layout in eight presses',
    );
  });

  testWidgets('closing a group\'s last tab collapses it', (tester) async {
    final a = openSessionTab('s1');
    final b = openSessionTab('s2');
    splitAndMove(b);
    terminals().activateTab(a);
    await pump(tester);
    expect(find.byType(TerminalTabChip), findsNWidgets(2));

    terminals().closeTab(b);
    await tester.pumpAndSettle();

    expect(
      container.read(terminalSessionsControllerProvider).workspace!.groups,
      hasLength(1),
    );
    expect(find.byType(TerminalTabChip), findsOneWidget);
    expect(find.text('branch-s1'), findsOneWidget);
  });

  group('the Explorer opens a session into one group, and only that one', () {
    /// The tombstone a group draws for a session nothing of ours is running.
    final tombstone = find.textContaining(
      'No terminal of ours is running this session',
    );

    testWidgets('a paneless selection stays in the group it was opened into', (
      tester,
    ) async {
      // The whole of the report, in the form only two groups can show it: a
      // selection with no pane of ours was drawn by whichever group happened
      // to have the keyboard, so it moved from group to group as the user
      // clicked around — and the group it landed on lost its own tab to it.
      final a = openSessionTab('s1');
      final b = openSessionTab('s2');
      final groups = splitAndMove(b);
      terminals().activateTab(a);
      await pump(tester);
      mirroredServer(db).sessionRows.insert(session(id: 's3', title: 'Read the report'));

      container.read(selectedSessionIdProvider.notifier).select('s3');
      await tester.pumpAndSettle();

      expect(tombstone, findsOneWidget);
      expect(
        find.text('branch-s3'),
        findsOneWidget,
        reason: 'it opened into the group with the keyboard',
      );
      expect(
        find.text('branch-s2'),
        findsOneWidget,
        reason: 'the group nobody asked about is untouched',
      );
      expect(find.text('branch-s1'), findsNothing);

      terminals().focusGroup(groups.right);
      await tester.pumpAndSettle();

      // **The assertion that carries the weight.** Moving the keyboard is not
      // a request to see anything, so nothing on screen may move with it.
      expect(
        find.text('branch-s2'),
        findsOneWidget,
        reason: 'the other group still reads its own tab',
      );
      expect(
        find.text('branch-s3'),
        findsOneWidget,
        reason: 'the selection stayed in the group it was opened into',
      );
      expect(find.text('branch-s1'), findsNothing);
      expect(tombstone, findsOneWidget);
    });

    testWidgets('a group\'s conversation is its own tab\'s session', (
      tester,
    ) async {
      // The owner's words: *"the chat view is embeded with terminal but i
      // think it's still responding globally not to the session it's embeded
      // into"*. The chat half of a group read the window-wide selection, so a
      // group showing one tab could be reading another tab's transcript.
      final a = openSessionTab('s1');
      final b = openSessionTab('s2');
      final c = openSessionTab('s3');
      final groups = splitAndMove(b);
      terminals().activateTab(a);
      await pump(tester);

      // The Explorer picks the tab the group is already showing…
      container.read(selectedSessionIdProvider.notifier).select('s1');
      await tester.pumpAndSettle();
      // …and then the user moves that group to its other tab.
      terminals().activateTab(c);
      await tester.pumpAndSettle();
      terminals().showFaceIn(groups.left, terminal: false);
      await tester.pumpAndSettle();

      final chats = tester
          .widgetList<SessionTranscriptView>(find.byType(SessionTranscriptView))
          .toList();
      expect(chats, hasLength(1));
      expect(
        chats.single.sessionId,
        's3',
        reason: 'the group is showing s3, so its chat is s3',
      );
      expect(
        find.text('branch-s2'),
        findsOneWidget,
        reason: 'and the other group is still its own',
      );
    });

    testWidgets('a selection with a pane never shadows another group', (
      tester,
    ) async {
      final a = openSessionTab('s1');
      final b = openSessionTab('s2');
      final c = openSessionTab('s3');
      splitAndMove(b);
      terminals().activateTab(a);
      await pump(tester);
      terminals().activateTab(c);
      await tester.pumpAndSettle();

      // Selecting a session that lives in the other group opens it *there* —
      // that group's own tab is the one thing that may change.
      container.read(selectedSessionIdProvider.notifier).select('s2');
      await tester.pumpAndSettle();

      expect(find.text('branch-s2'), findsOneWidget);
      expect(
        find.text('branch-s3'),
        findsOneWidget,
        reason: 'the group that was not asked about kept its tab',
      );
      expect(find.text('branch-s1'), findsNothing);
    });
  });
}
