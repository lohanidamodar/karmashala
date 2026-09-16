import 'dart:async';

import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/pane_group_strip.dart';
import 'package:karmashala/src/features/terminal/presentation/session_status.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import 'fake_instance.dart';
import 'package:karmashala_ui/rows.dart';

/// The owner: *"in the terminals with an active session, can we add an icon or
/// something like cmux does that shows whether the session is actually running,
/// or waiting for something, or done?"*
///
/// The tab strip could only ever say whether a **process** existed — that is all
/// [TabLivenessDot] is, and it says it by being absent when one does. What the
/// agent inside that process is doing was known to the app (the Explorer card
/// has drawn it since the status registry landed) and had never reached a tab.
///
/// These tests hold two things: that the marker is drawn from the same
/// vocabulary as the badge, and that it costs one chip.

/// One report stream per session row, so a test can push a status and — the
/// half that matters for cost — push the *same* status again.
final _reports = <String, StreamController<AgentStatusReport>>{};

StreamController<AgentStatusReport> _streamFor(String sessionId) => _reports
    .putIfAbsent(sessionId, StreamController<AgentStatusReport>.broadcast);

void _say(
  String sessionId,
  AgentActivityStatus status, {
  Duration since = Duration.zero,
}) {
  _streamFor(sessionId).add(
    AgentStatusReport(
      agentId: AgentIds.claudeCode,
      sessionId: sessionId,
      status: status,
      // Moved on every push, so a report that repeats a status is still a new
      // value arriving at the provider — which is exactly the cycle the strip
      // must not redraw for.
      observedAt: testTime.add(since),
      source: AgentStatusSource.hook,
    ),
  );
}

ProviderContainer harness(AppDatabase db) {
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      availableSystemTerminalsProvider.overrideWith(
        (ref) async => const <SystemTerminal>[],
      ),
      // The workbench case below mounts the whole surface, and three of its
      // pieces poll the host on a real timer. Answered here for
      // `workbench_test.dart`'s reasons rather than reached for: a timer left
      // pending outlives the tree, and a unit test must never run `git`.
      sessionTranscriptProvider.overrideWith((ref, id) => Stream.value(const [])),
      sessionDeliveryProvider.overrideWith(
        (ref, _) async => SessionDelivery.unknown,
      ),
      sessionContinuationProvider.overrideWith(
        (ref, _) => SessionContinuation(
          targets: const [],
          plan: SessionForkPlan.decide(descriptor: null, agentName: 'Test CLI'),
        ),
      ),
      // The one seam the whole feature reads. Overridden rather than driven
      // through a real `SessionStatusRegistry` on purpose: the registry already
      // suppresses a cycle that changed nothing, and pinning the cost here
      // proves the *strip* suppresses it too.
      agentSessionStatusProvider.overrideWith(
        (ref, sessionId) => _streamFor(sessionId).stream,
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

AppDatabase workspace() {
  final db = AppDatabase.memory();
  addTearDown(db.close);
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation());
  return db;
}

/// Puts a running session row in [paneId], the way a launch or an adoption
/// would.
void placeSession(AppDatabase db, String id, String paneId) {
  SessionDao(db).insert(
    session(id: id, status: SessionStatus.running).copyWith(paneId: paneId),
  );
}

TerminalSessionsController controllerOf(ProviderContainer container) =>
    container.read(terminalSessionsControllerProvider.notifier);

String openPane(ProviderContainer container) {
  controllerOf(container).openTab(TerminalProfile.powerShell);
  return container
      .read(terminalSessionsControllerProvider)
      .activeTab!
      .layout
      .panes
      .single;
}

/// One region chip, mounted on its own. The smallest thing that exercises the
/// whole path: the pane's liveness, the paneId → session map, the status
/// stream, and the marker.
Future<void> pumpChips(
  WidgetTester tester,
  ProviderContainer container,
  List<String> paneIds,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              for (final paneId in paneIds)
                SizedBox(
                  width: 200,
                  child: PaneTabChip(
                    key: PaneTabChip.keyFor(paneId),
                    paneId: paneId,
                    selected: true,
                    accented: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Two frames: a stream event reaches the provider on the first and the widget
/// it dirtied is rebuilt on the second.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Finder dotIn(String paneId) => find.descendant(
  of: find.byKey(PaneTabChip.keyFor(paneId)),
  matching: find.byType(TabAgentStatusDot),
);

void main() {
  setUp(_reports.clear);
  tearDown(() {
    for (final controller in _reports.values) {
      controller.close();
    }
    _reports.clear();
  });

  group('the marker', () {
    testWidgets('says what the agent is doing, in words as well as a glyph', (
      tester,
    ) async {
      final db = workspace();
      final container = harness(db);
      final paneId = openPane(container);
      placeSession(db, 's1', paneId);

      await pumpChips(tester, container, [paneId]);

      // Before any source has spoken. Drawn rather than hidden: a live agent
      // nothing can read is a different fact from a plain shell tab.
      expect(
        tester.widget<TabAgentStatusDot>(dotIn(paneId)).status,
        AgentActivityStatus.unknown,
      );

      for (final (status, word) in const [
        (AgentActivityStatus.working, 'Working'),
        (AgentActivityStatus.awaitingApproval, 'Needs you'),
        (AgentActivityStatus.idle, 'Idle'),
        (AgentActivityStatus.failed, 'Failed'),
      ]) {
        _say('s1', status);
        await settle(tester);

        expect(tester.widget<TabAgentStatusDot>(dotIn(paneId)).status, status);
        // Colour is never the only carrier: the tooltip and the semantic label
        // both name the state, and each state has its own glyph.
        expect(
          tester.widget<Tooltip>(
            find.descendant(of: dotIn(paneId), matching: find.byType(Tooltip)),
          ).message,
          'Agent: $word',
        );
        expect(
          tester
              .widget<StatusGlyph>(
                find.descendant(
                  of: dotIn(paneId),
                  matching: find.byType(StatusGlyph),
                ),
              )
              .semanticLabel,
          'Agent: $word',
        );
      }

      // Every state's glyph is its own, so the row is readable in monochrome.
      final glyphs = {
        for (final status in AgentActivityStatus.values)
          agentStatusAppearanceIcon(status),
      };
      expect(glyphs, hasLength(AgentActivityStatus.values.length));
    });

    testWidgets('a plain shell tab has no agent to report on', (tester) async {
      final db = workspace();
      final container = harness(db);
      final paneId = openPane(container);

      await pumpChips(tester, container, [paneId]);

      expect(dotIn(paneId), findsNothing);
      // And the liveness marker keeps the slot — which for a live shell means
      // drawing nothing at all, exactly as it always did.
      expect(
        container.read(paneAgentActivityProvider(paneId)),
        isNull,
      );
    });

    testWidgets('a pane whose process is gone falls back to liveness', (
      tester,
    ) async {
      final db = workspace();
      final container = harness(db);
      final paneId = openPane(container);
      placeSession(db, 's1', paneId);

      await pumpChips(tester, container, [paneId]);
      _say('s1', AgentActivityStatus.working);
      await settle(tester);
      expect(dotIn(paneId), findsOneWidget);

      (controllerOf(container).instanceFor(paneId)! as FakeTerminalInstance)
          .livenessNotifier
          .value = PaneLiveness.exited;
      await tester.pump();

      // One slot, never two glyphs — and never a status read off a screen
      // nothing is writing to.
      expect(dotIn(paneId), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(PaneTabChip.keyFor(paneId)),
          matching: find.byType(TabLivenessDot),
        ),
        findsOneWidget,
      );
    });
  });

  group('what it costs', () {
    testWidgets('a status change redraws one chip, not the header', (
      tester,
    ) async {
      final db = workspace();
      final container = harness(db);
      final panes = [
        for (var i = 0; i < 3; i++) openPane(container),
      ];
      for (final (index, paneId) in panes.indexed) {
        placeSession(db, 's$index', paneId);
      }

      await pumpChips(tester, container, panes);
      for (var i = 0; i < 3; i++) {
        _say('s$i', AgentActivityStatus.working);
      }
      await settle(tester);

      // The guard against a false green: without it the zeros below could just
      // mean the chips were never built.
      expect(PaneTabChip.debugBuildCount, greaterThan(0));
      PaneTabChip.debugBuildCount = 0;

      // The 1.2 s cycle re-reports what it already reported, over and over, for
      // as long as an agent sits still. That must reach nothing.
      for (var tick = 1; tick <= 5; tick++) {
        for (var i = 0; i < 3; i++) {
          _say(
            's$i',
            AgentActivityStatus.working,
            since: Duration(seconds: tick),
          );
        }
        await settle(tester);
      }
      expect(
        PaneTabChip.debugBuildCount,
        0,
        reason: 'a cycle that reconfirms a status is not a change',
      );

      // And a real change reaches exactly the chip it is about. Three chips
      // built together, so anything wider than a `select` would show up here.
      _say('s1', AgentActivityStatus.awaitingApproval);
      await settle(tester);

      expect(PaneTabChip.debugBuildCount, 1);
      expect(
        tester.widget<TabAgentStatusDot>(dotIn(panes[1])).status,
        AgentActivityStatus.awaitingApproval,
      );
      expect(
        tester.widget<TabAgentStatusDot>(dotIn(panes[0])).status,
        AgentActivityStatus.working,
      );
    });

    testWidgets('and the workbench strip is no wider', (tester) async {
      // The same property one level up: the workbench chip folds every pane in
      // its tab, so the fold is where an over-broad watch would hide.
      final db = workspace();
      final container = harness(db);
      final panes = [
        for (var i = 0; i < 3; i++) openPane(container),
      ];
      for (final (index, paneId) in panes.indexed) {
        placeSession(db, 's$index', paneId);
      }

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ShellShortcuts(child: WorkbenchView())),
          ),
        ),
      );
      // Settled rather than pumped: the transcript surface schedules
      // zero-duration work on mount, and a timer left pending outlives the
      // tree. Extra frames rebuild nothing that is not dirty, so the counter
      // below is unaffected.
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        _say('s$i', AgentActivityStatus.working);
      }
      await tester.pumpAndSettle();

      expect(
        tester
            .widgetList<TerminalTabChip>(find.byType(TerminalTabChip))
            .map((chip) => chip.agentStatus),
        everyElement(AgentActivityStatus.working),
      );

      expect(TerminalTabChip.debugBuildCount, greaterThan(0));
      TerminalTabChip.debugBuildCount = 0;

      _say('s2', AgentActivityStatus.failed);
      await tester.pumpAndSettle();

      // One chip. Three were laid out, and the strip rebuilds all of them
      // whenever it rebuilds at all, so this is also the assertion that the
      // strip did not.
      expect(TerminalTabChip.debugBuildCount, 1);
    });
  });

  group('a tab holding several agents', () {
    test('shows the one the user has to do something about', () {
      // Ordered by what is owed, not by what `AgentGridRules` reads off one
      // screen: a session holding the user up outranks one that has stopped.
      expect(
        mostUrgentAgentActivity(const [
          AgentActivityStatus.working,
          AgentActivityStatus.awaitingApproval,
          AgentActivityStatus.failed,
        ]),
        AgentActivityStatus.awaitingApproval,
      );
      expect(
        mostUrgentAgentActivity(const [
          AgentActivityStatus.idle,
          AgentActivityStatus.failed,
          AgentActivityStatus.working,
        ]),
        AgentActivityStatus.failed,
      );
      expect(
        mostUrgentAgentActivity(const [
          AgentActivityStatus.unknown,
          AgentActivityStatus.idle,
        ]),
        AgentActivityStatus.idle,
      );
    });

    test('and a tab of plain shells shows nothing', () {
      expect(mostUrgentAgentActivity(const []), isNull);
      expect(mostUrgentAgentActivity(const [null, null]), isNull);
      // One agent among shells still reports: null is "no agent here", not a
      // status that outranks anything.
      expect(
        mostUrgentAgentActivity(const [null, AgentActivityStatus.unknown]),
        AgentActivityStatus.unknown,
      );
    });
  });
}

/// The glyph [TabAgentStatusDot] draws for [status], for the "no two states
/// share a shape" assertion above.
IconData agentStatusAppearanceIcon(AgentActivityStatus status) =>
    agentStatusAppearance(status).icon;
