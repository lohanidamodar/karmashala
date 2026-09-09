import 'dart:async';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_providers.dart';
import 'package:karmashala/src/features/follow_ups/data/follow_up_dao.dart';
import 'package:karmashala/src/features/follow_ups/domain/follow_up.dart';
import 'package:karmashala/src/features/follow_ups/domain/session_ending.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/terminal/application/pane_exit_signal.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/verification/data/verification_dao.dart';
import 'package:karmashala/src/features/verification/domain/verification_run.dart';
import 'package:karmashala/src/features/verification/domain/verification_target.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The third signal: **a pane's own process stopped**.
///
/// Every in-app session runs in a PTY, so its row says `running` until somebody
/// deletes it and its status pipeline only ever settles on `failed`. An agent
/// that simply *finished* was therefore invisible to both of the other two
/// signals — which is the whole of what follow-ups were for.
///
/// The negative cases below are the important ones. A pane exiting is a common
/// event and most of them are not a session ending at all; getting that wrong
/// puts a notification on the screen every time somebody closes a terminal.
void main() {
  late AppDatabase db;
  late FollowUpDao followUps;
  late StreamController<AgentStatusReport> reports;

  AgentStatusReport report(AgentActivityStatus status) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: 's1',
    status: status,
    observedAt: testTime,
    source: AgentStatusSource.terminalGrid,
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1', status: SessionStatus.running));
    followUps = FollowUpDao(db);
    reports = StreamController<AgentStatusReport>.broadcast();
    addTearDown(reports.close);
  });
  tearDown(() => db.close());

  /// A verification run nobody ever finished, so a *clean* finish is owed a
  /// follow-up. Without one a completion is a completion and the app should say
  /// nothing at all — see `followUpFor`.
  void abandonedRun({String sessionId = 's1', String id = 'v1'}) {
    VerificationDao(db).insertRun(
      VerificationRun(
        id: id,
        title: 'the login page still loads',
        target: const VerificationTarget.browser('https://example.com'),
        startedAt: testTime,
        artifactDirectory: 'C:/art/$id',
        sessionId: sessionId,
      ),
    );
  }

  /// A container with fake panes, a real database, and the ending observer
  /// mounted the way the app mounts it.
  ProviderContainer observing() {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentSessionStatusProvider.overrideWith((ref, id) => reports.stream),
      ],
    );
    addTearDown(container.dispose);
    // Watched, not merely read: Riverpod 3 pauses a provider's own
    // subscriptions while nothing listens to it, so an observer nobody watches
    // sees nothing. The app mounts it the same way, through `openFollowUps`.
    container.listen(sessionEndingObserverProvider, (_, _) {});
    return container;
  }

  TerminalSessionsController terminal(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider.notifier);

  FakeTerminalInstance paneIn(ProviderContainer container, String paneId) =>
      terminal(container).instanceFor(paneId)! as FakeTerminalInstance;

  AgentPaneLaunch launchFor(String? sessionId) => AgentPaneLaunch(
    agentId: AgentIds.claudeCode,
    executable: r'C:\Users\me\.bin\claude.exe',
    sessionId: sessionId,
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('the rule', () {
    test('only a clean exit is a finish', () {
      expect(endingOfPaneExit(0), SessionEnding.completed);
    });

    test('a non-zero exit is left to the failure signal', () {
      // The exit status of a wrapper is not the agent's own verdict, and a
      // non-zero code covers a crash, a Ctrl-C (130, or 0xC000013A on Windows)
      // and a launcher that never got off the ground. `SessionEnding.failed`
      // already arrives from the status pipeline, which reads what the agent
      // actually printed.
      expect(endingOfPaneExit(1), isNull);
      expect(endingOfPaneExit(130), isNull);
    });

    test('a status we never learned is not a clean one', () {
      // The same direction `shouldCollapseOnExit` errs in.
      expect(endingOfPaneExit(null), isNull);
    });
  });

  group('what reaches the follow-up side', () {
    test('an agent that finishes cleanly leaves exactly one offer', () async {
      abandonedRun();
      final container = observing();
      final pane = terminal(container).openAgentTab(launchFor('s1'));
      await settle();

      paneIn(container, pane.paneId).exitCleanly();
      await settle();

      final raised = followUps.open().single;
      expect(raised.sessionId, 's1');
      expect(raised.ending, SessionEnding.completed);
      expect(raised.reason, FollowUpReason.verificationAbandoned);
    });

    test('a clean finish with nothing outstanding is silent', () async {
      // No verification run at all: nobody checked anything, which is not
      // evidence about the session and must not become a notice.
      final container = observing();
      final pane = terminal(container).openAgentTab(launchFor('s1'));
      await settle();

      paneIn(container, pane.paneId).exitCleanly();
      await settle();

      expect(followUps.open(), isEmpty);
    });

    test('a plain shell tab raises nothing', () async {
      abandonedRun();
      final container = observing();
      terminal(container).openTab(TerminalProfile.powerShell);
      await settle();

      final paneId = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      paneIn(container, paneId).exitCleanly();
      await settle();

      // The exit is still published — it is a fact about a pane — but it names
      // no session, so there is no row for a follow-up to be about.
      final published = container.read(paneExitProvider);
      expect(published, isNotNull);
      expect(published!.sessionId, isNull);
      expect(followUps.open(), isEmpty);
    });

    test('an agent pane with no session row raises nothing', () async {
      abandonedRun();
      final container = observing();
      final pane = terminal(container).openAgentTab(launchFor(null));
      await settle();

      paneIn(container, pane.paneId).exitCleanly();
      await settle();

      expect(followUps.open(), isEmpty);
    });

    test('a pane the user closed raises nothing', () async {
      abandonedRun();
      final container = observing();
      final pane = terminal(container).openAgentTab(launchFor('s1'));
      await settle();

      // Ending the pane disposes it, and disposing sets its liveness to
      // `exited` — but the user closing a tab is not an agent finishing its
      // work, so that exit must never be announced.
      terminal(container).closePane(pane.paneId, detach: false);
      await settle();

      expect(container.read(paneExitProvider), isNull);
      expect(followUps.open(), isEmpty);
    });

    test('ending a detached session raises nothing', () async {
      abandonedRun();
      final container = observing();
      final pane = terminal(container).openAgentTab(launchFor('s1'));
      await settle();

      terminal(container).closePane(pane.paneId);
      terminal(container).endSession(pane.paneId);
      await settle();

      expect(container.read(paneExitProvider), isNull);
      expect(followUps.open(), isEmpty);
    });

    test('detaching and reattaching is not an ending', () async {
      abandonedRun();
      final container = observing();
      final pane = terminal(container).openAgentTab(launchFor('s1'));
      await settle();

      // Detaching keeps the process; nothing exited, so nothing is announced.
      terminal(container).closePane(pane.paneId);
      terminal(container).reattachSession(pane.paneId);
      await settle();

      expect(container.read(paneExitProvider), isNull);
      expect(followUps.open(), isEmpty);
    });

    test('quitting the app raises nothing', () async {
      abandonedRun();
      final container = observing();
      terminal(container).openAgentTab(launchFor('s1'));
      await settle();

      // Quitting kills every pane, so the code each one exits with says what
      // the app did rather than what the agent was doing.
      await terminal(container).shutdownProcesses();
      await settle();

      expect(container.read(paneExitProvider), isNull);
      expect(followUps.open(), isEmpty);
    });
  });

  group('one ending, one offer', () {
    test('a failure keeps taking the existing path, once', () async {
      abandonedRun();
      final container = observing();
      final pane = terminal(container).openAgentTab(launchFor('s1'));
      await settle();

      // A pane that exited non-zero is not this seam's business.
      paneIn(container, pane.paneId)
        ..exitCode = 1
        ..livenessNotifier.value = PaneLiveness.exited;
      await settle();
      expect(followUps.open(), isEmpty);

      // The status pipeline is what notices a crash, exactly as before.
      reports.add(report(AgentActivityStatus.working));
      await settle();
      reports.add(report(AgentActivityStatus.failed));
      await settle();

      final raised = followUps.open().single;
      expect(raised.reason, FollowUpReason.endedInFailure);
      expect(raised.ending, SessionEnding.failed);
    });

    test('the same session finishing twice is offered once', () async {
      abandonedRun();
      final container = observing();
      final pane = terminal(container).openAgentTab(launchFor('s1'));
      await settle();

      paneIn(container, pane.paneId).exitCleanly();
      await settle();
      expect(followUps.open(), hasLength(1));

      // The user started the agent again in the same pane and it finished
      // again. The ending is the one already offered.
      terminal(container).startAgentInPane(pane.paneId, launchFor('s1'));
      paneIn(container, pane.paneId).exitCleanly();
      await settle();

      expect(followUps.open(), hasLength(1));
    });

    test('a dismissed offer is not raised again after a restart', () async {
      // What `predatesTheFeature` and `raisedEndings` are for: the mark that
      // says "already considered" is seeded from the table, resolved rows and
      // all, so a restart cannot re-raise something the user is done with.
      abandonedRun();
      final first = observing();
      final pane = terminal(first).openAgentTab(launchFor('s1'));
      await settle();
      paneIn(first, pane.paneId).exitCleanly();
      await settle();

      final raised = followUps.open().single;
      first.read(followUpServiceProvider).dismiss(raised);
      expect(followUps.open(), isEmpty);

      final second = observing();
      final again = terminal(second).openAgentTab(launchFor('s1'));
      await settle();
      paneIn(second, again.paneId).exitCleanly();
      await settle();

      expect(followUps.open(), isEmpty);
    });
  });
}
