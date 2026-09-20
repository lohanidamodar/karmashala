import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_wait.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/pane_exit_signal.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **The wait, driven by events and never by a clock.**
///
/// Every test here completes because something was *emitted* — a status report,
/// a pane exit, the injected deadline — and never because time passed. That is
/// the property under test as much as any assertion is: a wait that needed a
/// sleep to finish would be a poll wearing a different name.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late StreamController<AgentStatusReport> reports;
  late Completer<void> deadline;
  late AgentStatusReport? Function(String) statusLookup;
  late List<InboxItem> inboxItems;

  AgentStatusReport report({
    AgentActivityStatus status = AgentActivityStatus.working,
    AgentWaitKind waiting = AgentWaitKind.unrecorded,
    List<String> evidence = const [],
    DateTime? modifiedAt,
    AgentStatusSource source = AgentStatusSource.hook,
  }) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: 's1',
    status: status,
    observedAt: testTime,
    source: source,
    waiting: waiting,
    evidence: evidence,
    sourceModifiedAt: modifiedAt,
  );

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1', title: 'Helper'));

    reports = StreamController<AgentStatusReport>.broadcast();
    deadline = Completer<void>();
    statusLookup = (_) => null;
    inboxItems = [];
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // A fixed inbox. The real controller listens to half the app to decide
        // what has been seen, and none of that is what these tests are about.
        attentionInboxProvider.overrideWith(
          () => _FixedInbox(() => inboxItems),
        ),
        sessionStatusLookupProvider.overrideWithValue(
          (sessionId) => statusLookup(sessionId),
        ),
        sessionStatusStreamProvider.overrideWithValue((_) => reports.stream),
        // The bound, as an event the test fires. Nothing here sleeps.
        waitDeadlineProvider.overrideWithValue((_) => deadline.future),
      ],
    );
  });

  tearDown(() {
    reports.close();
    container.dispose();
    db.close();
  });

  /// Attaches a live pane to [sessionId], so the session counts as running.
  String attachPane(String sessionId) {
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .last
        .layout
        .panes
        .first;
    SessionDao(db).updatePaneId(sessionId, paneId);
    return paneId;
  }

  SessionWaitService waitService() => container.read(sessionWaitProvider);

  /// Puts one item in the inbox for [sessionId]. Read lazily, so a test sets
  /// this before the wait it is about.
  void inboxItem(
    String sessionId, {
    required InboxItemKind kind,
    String? detail,
  }) {
    inboxItems.add(
      InboxItem(
        session: WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, sessionId),
          openId: sessionId,
          label: 'Helper',
          imported: false,
        ),
        kind: kind,
        at: testTime,
        detail: detail,
      ),
    );
  }

  group('the two ready states', () {
    test(
      'a session that was already idle and stayed so answers idle',
      () async {
        attachPane('s1');
        final pending = waitService().wait('s1');
        reports.add(report(status: AgentActivityStatus.idle));

        final outcome = await pending;
        expect(outcome.state, SessionWaitState.idle);
        expect(outcome.changed, isFalse);
      },
    );

    test('idle after work answers done, not idle', () async {
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.working));
      await pumpEventQueue();
      reports.add(report(status: AgentActivityStatus.idle));

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.done);
      expect(outcome.changed, isTrue);
    });

    test('a source flip on its own is not a change', () async {
      // A hook ageing out re-sources the same reading. The registry publishes
      // it, and it must not be read as the agent having done something.
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(
        report(
          status: AgentActivityStatus.idle,
          source: AgentStatusSource.hook,
        ),
      );
      await pumpEventQueue();
      reports.add(
        report(
          status: AgentActivityStatus.idle,
          source: AgentStatusSource.stateFile,
        ),
      );

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.idle);
    });

    test('a turn that ended badly still settles, carrying the word', () async {
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.failed));

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.idle);
      expect(outcome.agentStatus, AgentActivityStatus.failed);
    });

    test('an agent at its own input is ready, not blocked', () async {
      // Claude Code's post-turn nudge: awaitingApproval with nothing to
      // confirm. Nothing may be answered on the user's behalf, but the session
      // is at its prompt and a message would reach it.
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(
        report(
          status: AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.input,
        ),
      );

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.idle);
    });
  });

  group('an unknown is never settled', () {
    test('working keeps waiting', () async {
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.working));
      await pumpEventQueue();
      deadline.complete();

      expect((await pending).state, SessionWaitState.timeout);
    });

    test('unknown keeps waiting and times out saying so', () async {
      // Antigravity with no reachable hook, and every agent before its first
      // signal. Reporting it as settled would be the confident false statement.
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(
        report(
          status: AgentActivityStatus.unknown,
          source: AgentStatusSource.none,
        ),
      );
      await pumpEventQueue();
      deadline.complete();

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.timeout);
      expect(outcome.agentStatus, AgentActivityStatus.unknown);
      expect(outcome.source, AgentStatusSource.none);
    });
  });

  group('blocked', () {
    test('an open approval prompt blocks, and quotes the agent', () async {
      attachPane('s1');
      statusLookup = (_) => report(
        status: AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.approval,
        evidence: const ['Allow Bash(rm -rf build)?'],
      );
      final pending = waitService().wait('s1');
      reports.add(
        report(
          status: AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.approval,
          evidence: const ['Allow Bash(rm -rf build)?'],
        ),
      );

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.blocked);
      expect(outcome.blockedOn?.kind, 'approvalPrompt');
      expect(outcome.blockedOn?.text, 'Allow Bash(rm -rf build)?');
    });

    test('an inbox question blocks, with its kind and its text', () async {
      attachPane('s1');
      inboxItem(
        's1',
        kind: InboxItemKind.needsApproval,
        detail: 'Which branch should I target?',
      );
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.idle));

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.blocked);
      expect(outcome.blockedOn?.kind, 'needsApproval');
      expect(outcome.blockedOn?.text, 'Which branch should I target?');
    });

    test('a finished turn in the inbox is not a block', () async {
      // `finished` means somebody has not read it yet, which is a session
      // ready for input rather than one holding a person up.
      attachPane('s1');
      inboxItem('s1', kind: InboxItemKind.finished);
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.idle));

      expect((await pending).state, SessionWaitState.idle);
    });

    test('blockedOn answers before anything is sent', () {
      statusLookup = (_) => report(
        status: AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.approval,
      );
      expect(waitService().blockedOn('s1')?.kind, 'approvalPrompt');
    });

    // Seen 2026-09-19: a send-and-wait to a session at its own prompt was
    // refused as "blocked on a person (needsApproval)". Claude Code's
    // 60-second idle nudge files an inbox item, but the agent is waiting for
    // exactly the message the caller is about to send.
    test(
      'an agent at its own input is not blocked, whatever the inbox holds',
      () {
        statusLookup = (_) => report(
          status: AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.input,
          evidence: const ['Claude is waiting for your input'],
        );
        inboxItem(
          's1',
          kind: InboxItemKind.needsApproval,
          detail: 'Claude is waiting for your input',
        );
        expect(waitService().blockedOn('s1'), isNull);
      },
    );

    test('blockedOn is null for a session that is merely busy', () {
      statusLookup = (_) => report(status: AgentActivityStatus.working);
      expect(waitService().blockedOn('s1'), isNull);
    });
  });

  group('ended', () {
    test(
      'a session with no live pane is over before the wait starts',
      () async {
        final pending = waitService().wait('s1');
        reports.add(report(status: AgentActivityStatus.working));

        final outcome = await pending;
        expect(outcome.state, SessionWaitState.ended);
        expect(outcome.exitCodeKnown, isFalse);
        expect(outcome.exitCode, isNull);
      },
    );

    test('a pane exit ends the wait, carrying its code', () async {
      final paneId = attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.working));
      await pumpEventQueue();
      container
          .read(paneExitProvider.notifier)
          .record(PaneExit(paneId: paneId, sessionId: 's1', exitCode: 3));

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.ended);
      expect(outcome.exitCode, 3);
      expect(outcome.exitCodeKnown, isTrue);
    });

    test('an exit with no code is never reported as a zero', () async {
      final paneId = attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.working));
      await pumpEventQueue();
      container
          .read(paneExitProvider.notifier)
          .record(PaneExit(paneId: paneId, sessionId: 's1', exitCode: null));

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.ended);
      expect(outcome.exitCode, isNull);
      expect(outcome.exitCodeKnown, isFalse);
    });

    test('another pane exiting is not this session ending', () async {
      final paneId = attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.working));
      await pumpEventQueue();
      container
          .read(paneExitProvider.notifier)
          .record(
            PaneExit(paneId: paneId, sessionId: 'somebody-else', exitCode: 0),
          );
      await pumpEventQueue();
      deadline.complete();

      expect((await pending).state, SessionWaitState.timeout);
    });
  });

  group('the answer carries its own age', () {
    test(
      'since is when the evidence was produced, not when we looked',
      () async {
        attachPane('s1');
        final written = testTime.subtract(const Duration(minutes: 4));
        final pending = waitService().wait('s1');
        reports.add(
          report(
            status: AgentActivityStatus.idle,
            source: AgentStatusSource.stateFile,
            modifiedAt: written,
          ),
        );

        final outcome = await pending;
        expect(outcome.since, written);
        expect(outcome.evidenceAge, const Duration(minutes: 4));
      },
    );

    test('a transcript nothing can read reports null, never false', () async {
      // A hook carries no transcript position and a PTY session keeps no event
      // log. "We do not know" is the answer; `false` would read as "it said
      // nothing".
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.idle));

      expect((await pending).transcriptChanged, isNull);
    });

    test('a transcript that was rewritten reports true', () async {
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(
        report(
          status: AgentActivityStatus.working,
          source: AgentStatusSource.stateFile,
          modifiedAt: testTime.subtract(const Duration(minutes: 1)),
        ),
      );
      await pumpEventQueue();
      reports.add(
        report(
          status: AgentActivityStatus.idle,
          source: AgentStatusSource.stateFile,
          modifiedAt: testTime,
        ),
      );

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.done);
      expect(outcome.transcriptChanged, isTrue);
    });

    test(
      'a transcript that stood still reports false, whatever it says',
      () async {
        // **The reading is a watermark, not a parse.** Nothing in the wait opens
        // a transcript or looks at a row, so what a CLI writes *inside* one — a
        // thinking block among them — cannot reach this answer: the mtime is the
        // whole evidence, and an unmoved mtime is `false` however much the file
        // would have to say.
        attachPane('s1');
        final pending = waitService().wait('s1');
        final written = testTime.subtract(const Duration(minutes: 1));
        reports.add(
          report(
            status: AgentActivityStatus.working,
            source: AgentStatusSource.stateFile,
            modifiedAt: written,
          ),
        );
        await pumpEventQueue();
        reports.add(
          report(
            status: AgentActivityStatus.idle,
            source: AgentStatusSource.stateFile,
            modifiedAt: written,
          ),
        );

        final outcome = await pending;
        expect(outcome.state, SessionWaitState.done);
        expect(outcome.transcriptChanged, isFalse);
      },
    );
  });

  group('the bound', () {
    test('a timeout says the session is still running', () async {
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.working));
      await pumpEventQueue();
      deadline.complete();

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.timeout);
      expect(outcome.agentStatus, AgentActivityStatus.working);
    });

    test('a timeout carries whether input was sent', () async {
      attachPane('s1');
      final pending = waitService().wait('s1', inputSent: true);
      reports.add(report(status: AgentActivityStatus.working));
      await pumpEventQueue();
      deadline.complete();

      final outcome = await pending;
      expect(outcome.state, SessionWaitState.timeout);
      expect(outcome.inputSent, isTrue);
    });

    test('a wait that sent nothing says so as null, not false', () async {
      attachPane('s1');
      final pending = waitService().wait('s1');
      reports.add(report(status: AgentActivityStatus.working));
      await pumpEventQueue();
      deadline.complete();

      expect((await pending).inputSent, isNull);
    });

    test('the bound is defaulted, clamped, and never zero', () {
      expect(
        SessionWaitService.boundFor(null),
        SessionWaitService.defaultBound,
      );
      expect(SessionWaitService.boundFor(0), SessionWaitService.defaultBound);
      expect(SessionWaitService.boundFor(-5), SessionWaitService.defaultBound);
      expect(SessionWaitService.boundFor(10), const Duration(seconds: 10));
      expect(SessionWaitService.boundFor(600), SessionWaitService.maxBound);
    });

    test('the cap clears the transports a call has to cross', () {
      // `kLocalRpcTimeout` is 60s and the MCP client's own timeout is about the
      // same — and it *retries*. A bound at or over either would turn one wait
      // into two.
      expect(
        SessionWaitService.maxBound,
        lessThan(const Duration(seconds: 60)),
      );
    });
  });
}

/// The inbox as a test states it, without the controller's view-tracking.
class _FixedInbox extends AttentionInboxController {
  _FixedInbox(this._items);

  final List<InboxItem> Function() _items;

  @override
  AttentionInbox build() => AttentionInbox(items: _items());
}
