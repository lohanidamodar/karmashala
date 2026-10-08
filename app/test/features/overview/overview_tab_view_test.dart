import 'dart:async';

import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_reads.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';
import 'package:karmashala/src/features/overview/presentation/overview_triage.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';
import 'mission_fixture.dart' show FakeOverviewReader, hybridList;

/// **The Overview tab, drawn** over the real data path: the counters and a
/// tile per project at desktop and phone sizes, the counters filtering, the
/// one filter control and its chips, and the peek's actions reaching the paths
/// every other surface uses.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Directory dir;
  late _SpyActions actions;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-view');
  });
  tearDownAll(() => dir.delete(recursive: true));

  WatchedSession watch(String row) => WatchedSession(
    key: AgentSessionKey(AgentIds.claudeCode, 'cli-$row'),
    label: row,
    openId: row,
    imported: false,
  );

  void insert(
    String id, {
    SessionStatus status = SessionStatus.running,
    Duration age = const Duration(hours: 1),
    String repo = 'r1',
    String? conversation,
    bool archived = false,
  }) => db.server.sessionRows.insert(
    Session(
      id: id,
      repositoryId: repo,
      agentInstallationId: 'a1',
      title: 'Chat $id',
      useWorktree: false,
      status: status,
      createdAt: testTime.subtract(age),
    ).copyWith(
      externalSessionId: conversation,
      archivedAt: archived ? testTime.subtract(age) : null,
    ),
  );

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
    server.projectRows
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));
    server.repositoryRows
      ..insert(
        repository(
          id: 'r1',
          projectId: 'p1',
          name: 'alpha',
          path: r'C:\src\alpha',
        ),
      )
      ..insert(
        repository(
          id: 'r2',
          projectId: 'p2',
          name: 'beta',
          path: r'C:\src\beta',
        ),
      );
    insert('ask');
    insert('busy');
    insert('idle', status: SessionStatus.idle);
    insert('done', status: SessionStatus.completed);
    insert(
      'old',
      status: SessionStatus.completed,
      age: const Duration(days: 3),
    );
    insert('beta-done', status: SessionStatus.completed, repo: 'r2');
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db, data: await server.override()),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
        explorerActionsProvider.overrideWith(
          (ref) => actions = _SpyActions(ref),
        ),
        // What the server runs is what its fake says it started.
        sessionRunningOnHostProvider.overrideWithValue(
          server.sessionWork.running.contains,
        ),
        // A peeked chat with a conversation would read the CLI's own store.
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
        ),
        overviewReaderProvider.overrideWithValue(
          FakeOverviewReader(
            answers: const {
              'parked': LastAnswer.of(
                'Wired the **webhooks**: three events reach the inbox, the '
                'retry backs off to five minutes, and the tests are in '
                '`webhooks_test.dart`.',
              ),
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: OverviewTabView()),
        ),
      ),
    );
    server.attention.statusOf(
      'busy',
      AgentActivityStatus.working,
      sessionId: 'cli-busy',
      label: 'busy',
      // A screen reading: no evidence age, so the lens arms no quiet timer.
      source: AgentStatusSource.terminalGrid,
    );
    server.attention.setInbox(
      AttentionInbox(
        items: [
          InboxItem(
            session: watch('ask'),
            kind: InboxItemKind.needsApproval,
            at: testTime,
          ),
        ],
      ),
      waiting: [
        SessionAttention(session: watch('ask'), kind: AttentionKind.needsInput),
      ],
    );
    await settle(tester);
    return container;
  }

  Finder card(String id) => find.byKey(ValueKey('overview-card:$id'));

  Future<void> openDone(WidgetTester tester) async {
    final fold = find.byKey(const ValueKey('overview-done-fold'));
    await tester.ensureVisible(fold);
    await settle(tester);
    await tester.tap(fold);
    await settle(tester);
  }

  Finder counter(BoardColumn column) =>
      find.byKey(ValueKey('overview-counter:${column.name}'));

  for (final (name, size) in [
    ('1440×900', const Size(1440, 900)),
    ('1024×768', const Size(1024, 768)),
    ('390×844', const Size(390, 844)),
  ]) {
    testBoard('$name: the heartbeat, what waits on you, then what works', (
      tester,
    ) async {
      await pump(tester, size);

      expect(find.byKey(const ValueKey('overview-hybrid')), findsOneWidget);
      for (final column in BoardColumn.values) {
        expect(counter(column), findsOneWidget);
      }
      expect(card('ask'), findsOneWidget);
      // A phone lists what is at work in rows; the queue keeps its cards.
      Finder atWork(String id) => size.width < 600
          ? find.byKey(ValueKey('overview-phone-row:$id'))
          : card(id);
      expect(atWork('busy'), findsOneWidget);
      expect(atWork('idle'), findsOneWidget);
      // Done today folds under a line; what ended before today is not drawn.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('overview-done-fold')),
        200,
        scrollable: hybridList,
      );
      expect(find.text('2 done today'), findsOneWidget);
      await openDone(tester);
      expect(find.byKey(const ValueKey('overview-done:done')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overview-done:beta-done')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('overview-done:old')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testBoard('the counters count what the tiles hold, spend left out', (
    tester,
  ) async {
    await pump(tester, const Size(1440, 900));

    expect(find.bySemanticsLabel(RegExp(r'^Needs you, 1, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Working, 1, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Ready, 1, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Done today, 2, ')), findsOneWidget);
    // No agent here reports cost over a protocol: nothing is said about it.
    expect(find.textContaining('spend'), findsNothing);
    expect(find.byKey(const ValueKey('overview-facts')), findsNothing);
  });

  testBoard('a counter shows only its state; tapped again, all of them', (
    tester,
  ) async {
    final c = await pump(tester, const Size(1440, 900));

    await tester.tap(counter(BoardColumn.working));
    await settle(tester);
    expect(c.read(overviewPrefsProvider).filter.columns, {BoardColumn.working});
    expect(card('busy'), findsOneWidget);
    expect(card('ask'), findsNothing);
    expect(find.byKey(const ValueKey('overview-done-fold')), findsNothing);
    // The other counters keep their numbers.
    expect(find.bySemanticsLabel(RegExp(r'^Needs you, 1, ')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Working, 1, showing only these')),
      findsOneWidget,
    );

    await tester.tap(counter(BoardColumn.working));
    await settle(tester);
    expect(c.read(overviewPrefsProvider).filter.columns, isNull);
    expect(card('ask'), findsOneWidget);
  });

  testBoard('the filter control sets the prefs; a chip clears its filter', (
    tester,
  ) async {
    final c = await pump(tester, const Size(1440, 900));
    expect(find.byKey(const ValueKey('overview-active-filters')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('overview-filter-button')));
    await settle(tester);
    expect(find.byKey(const ValueKey('overview-filter-panel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-filter-project:p2')));
    await settle(tester);
    expect(c.read(overviewPrefsProvider).filter.projects, {'p1'});
    await tester.tap(find.byKey(const ValueKey('group-by:machine')));
    await settle(tester);
    expect(c.read(overviewPrefsProvider).groupBy, OverviewGroupBy.machine);
    await tester.tap(find.byKey(const ValueKey('group-by:project')));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.text('Projects: Alpha'), findsOneWidget);
    expect(find.text('1 done today'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('overview-active-filter:projects')),
        matching: find.byTooltip('Clear Projects: Alpha'),
      ),
    );
    await settle(tester);
    expect(c.read(overviewPrefsProvider).filter.projects, isNull);
    expect(find.byKey(const ValueKey('overview-active-filters')), findsNothing);
    expect(find.text('2 done today'), findsOneWidget);
  });

  testBoard("a waiting card peeks into the session's own chat and its asks", (
    tester,
  ) async {
    await pump(tester, const Size(1440, 900));

    await tester.tap(find.text('Chat ask').first);
    await settle(tester);

    final peek = find.byKey(const ValueKey('overview-peek:ask'));
    expect(peek, findsOneWidget);
    // The chat its own tab draws, whose dock answers what it asks.
    expect(
      find.descendant(of: peek, matching: find.byType(SessionTranscriptView)),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const ValueKey('overview-peek')), findsNothing);
  });

  testBoard("a terminal session's chat in the peek is read, with no chat tab "
      'open anywhere', (tester) async {
    // The probe, 2026-10-07: only the dashboard was open, so no workbench
    // group showed a chat, the server feed was never watched, and the peek's
    // chat spun for ever.
    final c = await pump(tester, const Size(1440, 900));
    expect(c.read(chatTranscriptPollingProvider), isFalse);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('overview-done-fold')),
      200,
      scrollable: hybridList,
    );
    await openDone(tester);
    await tester.tap(find.byKey(const ValueKey('overview-done:done')));
    await settle(tester);
    expect(find.byKey(const ValueKey('overview-peek:done')), findsOneWidget);

    expect(c.read(chatTranscriptPollingProvider), isTrue);

    // Closed, or on another of its tabs, it is read no longer.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const ValueKey('overview-peek')), findsNothing);
    expect(c.read(chatTranscriptPollingProvider), isFalse);
  });

  testBoard("the peek's Resume and Archive reach the lists' own paths", (
    tester,
  ) async {
    await pump(tester, const Size(1440, 900));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('overview-done-fold')),
      200,
      scrollable: hybridList,
    );
    await openDone(tester);
    await tester.tap(find.byKey(const ValueKey('overview-done:done')));
    await settle(tester);

    // Resume keeps it here (below); Open tab is the lists' own open.
    expect(find.byKey(const ValueKey('overview-peek-resume')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-peek-open')));
    await settle(tester);
    expect(actions.opened, ['done']);
    expect(find.text('Open tab'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('overview-peek-archive')));
    await settle(tester);
    expect(
      server.requests.where((k) => k == SessionsArchive.name),
      hasLength(1),
    );
  });

  testBoard('the arrows move between cards and Enter peeks', (tester) async {
    await pump(tester, const Size(1440, 900));
    // Click once to give the Board the keyboard, then close what it opened.
    await tester.tap(find.text('Chat busy').first);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // The queue is drawn before the work, so up from the first card is it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);

    expect(find.byKey(const ValueKey('overview-peek:ask')), findsOneWidget);
  });

  group('Resume…', () {
    Finder row(String id) => find.byKey(ValueKey('overview-resume-row:$id'));
    Finder byKey(String key) => find.byKey(ValueKey(key));

    List<SessionStartSpec> starts() => [
      for (final request in server.sessionWork.asked)
        if (request is SessionStart) request.spec,
    ];

    /// Nothing opened in this window and nothing selected in the lists.
    void expectStayedPut(ProviderContainer c) {
      expect(c.read(terminalSessionsControllerProvider).tabs, isEmpty);
      expect(c.read(selectedSessionIdProvider), isNull);
      expect(find.byType(OverviewTabView), findsOneWidget);
    }

    setUp(() {
      // The live ones run at the server; the rest are stopped or ended.
      server.sessionWork.running.addAll(['ask', 'busy', 'idle']);
      insert(
        'parked',
        status: SessionStatus.completed,
        age: const Duration(days: 2),
        conversation: 'conv-parked',
      );
    });

    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(byKey('overview-resume'));
      await settle(tester);
      expect(byKey('overview-resume-picker'), findsOneWidget);
    }

    testBoard('lists only what nothing runs, newest first, with search and '
        'filters', (tester) async {
      insert(
        'shelved',
        status: SessionStatus.completed,
        conversation: 'conv-shelved',
        archived: true,
      );
      await pump(tester, const Size(1440, 900));
      await openPicker(tester);

      for (final id in ['done', 'beta-done', 'old', 'parked']) {
        expect(row(id), findsOneWidget, reason: id);
      }
      for (final id in ['ask', 'busy', 'idle', 'shelved']) {
        expect(row(id), findsNothing, reason: id);
      }
      expect(
        tester.getTopLeft(row('done')).dy,
        lessThan(tester.getTopLeft(row('parked')).dy),
      );
      expect(
        tester.getTopLeft(row('parked')).dy,
        lessThan(tester.getTopLeft(row('old')).dy),
      );
      // Agent · project, then its age.
      expect(
        find.descendant(
          of: row('done'),
          matching: find.text('Claude Code · Alpha'),
        ),
        findsOneWidget,
      );

      await tester.tap(byKey('overview-resume-archived'));
      await settle(tester);
      expect(row('shelved'), findsOneWidget);

      await tester.enterText(byKey('overview-resume-search'), 'beta');
      await settle(tester);
      expect(row('beta-done'), findsOneWidget);
      expect(row('done'), findsNothing);
      await tester.enterText(byKey('overview-resume-search'), '');
      await settle(tester);

      await tester.tap(byKey('overview-resume-project'));
      await settle(tester);
      await tester.tap(find.text('Beta').last);
      await settle(tester);
      expect(row('beta-done'), findsOneWidget);
      expect(row('done'), findsNothing);
      expect(row('old'), findsNothing);
    });

    testBoard('Resume keeps you here: no tab, nothing selected, the peek '
        'opens and the agent comes back idle', (tester) async {
      final c = await pump(tester, const Size(1440, 900));
      await openPicker(tester);
      await tester.tap(row('parked'));
      await settle(tester);
      expect(byKey('overview-resume-cost'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(byKey('overview-resume-keep-here'))
            .value,
        isTrue,
      );
      await tester.tap(byKey('overview-resume-idle'));
      await settle(tester);

      final spec = starts().single;
      expect(spec.resumeConversationId, 'conv-parked');
      expect(spec.prompt, isNull);
      expect(server.sessionWork.sent, isEmpty);
      expect(server.sessionWork.running, contains('parked'));
      expect(byKey('overview-resume-picker'), findsNothing);
      expect(c.read(overviewFocusProvider).peeked, 'parked');
      expect(byKey('overview-peek:parked'), findsOneWidget);
      expect(c.read(overviewPrefsProvider).launchInBackground, isTrue);
      expectStayedPut(c);
    });

    testBoard('Resume and send delivers the message, with Enter', (
      tester,
    ) async {
      final c = await pump(tester, const Size(1440, 900));
      await openPicker(tester);
      await tester.tap(row('parked'));
      await settle(tester);
      expect(
        tester.widget<FilledButton>(byKey('overview-resume-send')).onPressed,
        isNull,
      );
      await tester.enterText(
        byKey('overview-resume-message'),
        'pick up the tests',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      expect(starts().single.prompt, 'pick up the tests');
      expect(c.read(overviewFocusProvider).peeked, 'parked');
      expectStayedPut(c);
    });

    testBoard('an archived session is unarchived, and the picker says so', (
      tester,
    ) async {
      insert(
        'shelved',
        status: SessionStatus.completed,
        conversation: 'conv-shelved',
        archived: true,
      );
      final c = await pump(tester, const Size(1440, 900));
      await openPicker(tester);
      await tester.tap(byKey('overview-resume-archived'));
      await settle(tester);
      await tester.tap(row('shelved'));
      await settle(tester);
      expect(byKey('overview-resume-unarchives'), findsOneWidget);
      await tester.tap(byKey('overview-resume-idle'));
      await settle(tester);

      expect(db.server.sessionRows.getById('shelved')!.isArchived, isFalse);
      expect(starts().single.resumeConversationId, 'conv-shelved');
      expect(find.textContaining('unarchived'), findsOneWidget);
      expectStayedPut(c);
    });

    testBoard('unticked, it opens a tab, this once', (tester) async {
      final c = await pump(tester, const Size(1440, 900));
      await openPicker(tester);
      await tester.tap(row('parked'));
      await settle(tester);
      await tester.tap(byKey('overview-resume-keep-here'));
      await settle(tester);
      await tester.tap(byKey('overview-resume-idle'));
      await settle(tester);

      expect(actions.opened, ['parked']);
      expect(c.read(overviewPrefsProvider).launchInBackground, isTrue);
    });

    testBoard('with the setting off, it starts unticked', (tester) async {
      final c = await pump(tester, const Size(1440, 900));
      c.read(overviewPrefsProvider.notifier).setLaunchInBackground(false);
      await openPicker(tester);
      await tester.tap(row('parked'));
      await settle(tester);

      expect(
        tester
            .widget<CheckboxListTile>(byKey('overview-resume-keep-here'))
            .value,
        isFalse,
      );
    });

    testBoard('on a phone it is a full-screen sheet, and resuming keeps you '
        'on the dashboard', (tester) async {
      final c = await pump(tester, const Size(390, 844));
      await openPicker(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        tester.getSize(byKey('overview-resume-picker')).height,
        greaterThan(844 * 0.75),
      );
      await tester.tap(row('parked'));
      await settle(tester);
      await tester.tap(byKey('overview-resume-idle'));
      await settle(tester);

      expect(starts().single.resumeConversationId, 'conv-parked');
      expect(c.read(overviewFocusProvider).peeked, 'parked');
      expectStayedPut(c);
    });

    for (final (name, size) in [
      ('360×800', const Size(360, 800)),
      ('390×844', const Size(390, 844)),
      ('1024×768', const Size(1024, 768)),
      ('1920×1080', const Size(1920, 1080)),
    ]) {
      for (final scale in [1.0, 1.6]) {
        testBoard('$name at ${scale}x text: the picker and its choice fit', (
          tester,
        ) async {
          insert(
            'a-very-long-session-title-that-has-to-ellipsize-somewhere',
            status: SessionStatus.completed,
            conversation: 'conv-long',
            archived: true,
          );
          final c = await pump(tester, size, textScale: scale);
          await openPicker(tester);
          // Any overflow fails the test on its own; these say it laid out.
          expect(row('parked'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('overview-resume-answer:parked')),
            findsOneWidget,
          );
          await tester.tap(byKey('overview-resume-archived'));
          await settle(tester);
          final picker = tester.getRect(byKey('overview-resume-picker'));
          expect(picker.width, lessThanOrEqualTo(size.width));
          expect(picker.right, lessThanOrEqualTo(size.width));

          await tester.tap(row('parked'));
          await settle(tester);
          for (final key in [
            'overview-resume-message',
            'overview-resume-cost',
            'overview-resume-keep-here',
            'overview-resume-idle',
            'overview-resume-send',
          ]) {
            await tester.ensureVisible(byKey(key));
            await settle(tester);
            expect(byKey(key), findsOneWidget, reason: key);
            expect(
              tester.getRect(byKey(key)).right,
              lessThanOrEqualTo(size.width),
              reason: key,
            );
          }
          await tester.tap(byKey('overview-resume-idle'));
          await settle(tester);
          expect(c.read(overviewFocusProvider).peeked, 'parked');
          expectStayedPut(c);
        });
      }
    }

    testBoard('R opens it, and "?" lists R', (tester) async {
      await pump(tester, const Size(1440, 900));
      await tester.tap(find.text('Chat busy').first);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await settle(tester);
      expect(byKey('overview-resume-picker'), findsOneWidget);
      expect(overviewKeyRows().expand((k) => k.keys), contains('R'));
    });

    group('from the peek and the cards', () {
      setUp(() {
        insert(
          'paused',
          status: SessionStatus.completed,
          age: const Duration(minutes: 30),
          conversation: 'conv-paused',
        );
      });

      Future<void> peekPaused(WidgetTester tester) async {
        await tester.scrollUntilVisible(
          byKey('overview-done-fold'),
          200,
          scrollable: hybridList,
        );
        await openDone(tester);
        await tester.tap(byKey('overview-done:paused'));
        await settle(tester);
        expect(byKey('overview-peek:paused'), findsOneWidget);
      }

      testBoard("the peek's Resume brings it back here, idle", (tester) async {
        final c = await pump(tester, const Size(1440, 900));
        await peekPaused(tester);
        await tester.tap(byKey('overview-peek-resume'));
        await settle(tester);

        final spec = starts().single;
        expect(spec.resumeConversationId, 'conv-paused');
        expect(spec.prompt, isNull);
        // Running now: the button gives way to Stop.
        expect(byKey('overview-peek-resume'), findsNothing);
        expectStayedPut(c);
      });

      testBoard("with the setting off, the peek's Resume opens its tab", (
        tester,
      ) async {
        final c = await pump(tester, const Size(1440, 900));
        c.read(overviewPrefsProvider.notifier).setLaunchInBackground(false);
        await peekPaused(tester);
        await tester.tap(byKey('overview-peek-resume'));
        await settle(tester);

        expect(actions.opened, ['paused']);
        expect(starts(), isEmpty);
      });

      testBoard("Open tab opens it whatever the setting", (tester) async {
        final c = await pump(tester, const Size(1440, 900));
        expect(c.read(overviewPrefsProvider).launchInBackground, isTrue);
        await peekPaused(tester);
        await tester.tap(byKey('overview-peek-open'));
        await settle(tester);

        expect(actions.opened, ['paused']);
      });

      testBoard('a card\'s ⋯ offers Resume', (tester) async {
        final c = await pump(tester, const Size(1440, 900));
        await tester.scrollUntilVisible(
          byKey('overview-done-fold'),
          200,
          scrollable: hybridList,
        );
        await openDone(tester);
        await tester.tap(byKey('overview-card-menu:paused'));
        await settle(tester);
        await tester.tap(find.text('Resume').last);
        await settle(tester);

        expect(starts().single.resumeConversationId, 'conv-paused');
        expect(c.read(overviewFocusProvider).peeked, 'paused');
        expectStayedPut(c);
      });

      testBoard("typing into a stopped session's peek resumes it here and "
          'sends', (tester) async {
        final c = await pump(tester, const Size(1440, 900));
        await peekPaused(tester);
        final box = find.descendant(
          of: byKey('overview-peek:paused'),
          matching: find.byType(TextField),
        );
        await tester.enterText(box.last, 'and the docs');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);

        final spec = starts().single;
        expect(spec.resumeConversationId, 'conv-paused');
        expect(spec.prompt, 'and the docs');
        expectStayedPut(c);
      });

      // The box is disabled while a message goes, and a disabled field gives
      // the keys up; after the send they have to come back to it, while the
      // card moves on — at work, then waiting.
      for (final how in ['Enter', 'the send button']) {
        testBoard('after a send by $how the peek keeps the keys in its box, '
            'as the card moves group', (tester) async {
          await pump(tester, const Size(1440, 900));
          await peekPaused(tester);
          Finder box() => find
              .descendant(
                of: byKey('overview-peek:paused'),
                matching: find.byType(EditableText),
              )
              .last;
          await tester.tap(box());
          await settle(tester);
          await tester.enterText(box(), 'and the docs');
          // A server that takes a moment, as a real one does: the box draws
          // disabled while it waits.
          final slow = server.hold = Completer<void>();
          if (how == 'Enter') {
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          } else {
            await tester.tap(
              find
                  .descendant(
                    of: byKey('overview-peek:paused'),
                    matching: find.byTooltip(
                      'Send (Enter) · Shift + Enter for a new line',
                    ),
                  )
                  .last,
            );
          }
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          server.hold = null;
          slow.complete();
          await settle(tester);
          expect(starts().single.prompt, 'and the docs');

          bool boxHasKeys() =>
              tester.widget<EditableText>(box()).focusNode.hasFocus;
          expect(boxHasKeys(), isTrue, reason: 'right after the send');

          server.attention.statusOf('paused', AgentActivityStatus.working);
          await settle(tester);
          expect(boxHasKeys(), isTrue, reason: 'at work');

          server.attention.statusOf(
            'paused',
            AgentActivityStatus.idle,
            waiting: AgentWaitKind.input,
          );
          await settle(tester);
          expect(boxHasKeys(), isTrue, reason: 'waiting');
          expect(byKey('overview-peek:paused'), findsOneWidget);
        });
      }

      testBoard('"Resuming…" shows while it comes back', (tester) async {
        final c = await pump(tester, const Size(1440, 900));
        await peekPaused(tester);
        c.read(sessionsStartingProvider.notifier).add('paused');
        await settle(tester);
        expect(byKey('overview-resuming:paused'), findsOneWidget);
        expect(byKey('overview-peek-resume'), findsNothing);
        c.read(sessionsStartingProvider.notifier).remove('paused');
        await settle(tester);
        expect(byKey('overview-resuming:paused'), findsNothing);
      });

      testBoard("the peek's Archive waits while it comes back, and says "
          'why', (tester) async {
        final c = await pump(tester, const Size(1440, 900));
        await peekPaused(tester);
        const archives = ['overview-peek-archive'];
        bool enabled(String key) =>
            tester.widget<ButtonStyleButton>(byKey(key)).onPressed != null;
        Finder saysResuming(String key) => find.ancestor(
          of: byKey(key),
          matching: find.byWidgetPredicate(
            (w) => w is Tooltip && w.message == 'Resuming…',
          ),
        );
        for (final key in archives) {
          expect(enabled(key), isTrue, reason: key);
        }

        c.read(sessionsStartingProvider.notifier).add('paused');
        await settle(tester);
        for (final key in archives) {
          expect(enabled(key), isFalse, reason: key);
          expect(saysResuming(key), findsOneWidget, reason: key);
        }

        c.read(sessionsStartingProvider.notifier).remove('paused');
        await settle(tester);
        for (final key in archives) {
          expect(enabled(key), isTrue, reason: key);
          expect(saysResuming(key), findsNothing, reason: key);
        }
      });
    });
  });

  group('a click outside the peek closes it, as Esc does', () {
    Finder byKey(String key) => find.byKey(ValueKey(key));

    Future<ProviderContainer> peekBusy(
      WidgetTester tester, {
      Size size = const Size(1440, 900),
    }) async {
      final c = await pump(tester, size);
      await tester.tap(find.text('Chat busy').first);
      await settle(tester);
      expect(c.read(overviewFocusProvider).peeked, 'busy');
      return c;
    }

    /// The board's empty space: the foot of its list, under the last card.
    Future<void> tapBoardSpace(WidgetTester tester) async {
      final list = tester.getRect(hybridList.first);
      await tester.tapAt(Offset(list.left + 8, list.bottom - 8));
      await settle(tester);
    }

    testBoard('docked: the board\'s space closes it', (tester) async {
      final c = await peekBusy(tester);
      await tapBoardSpace(tester);
      expect(c.read(overviewFocusProvider).peeked, isNull);
      expect(byKey('overview-peek:busy'), findsNothing);
    });

    testBoard('overlay, below 1280 px: the board beside it closes it', (
      tester,
    ) async {
      final c = await peekBusy(tester, size: const Size(1100, 900));
      expect(byKey('overview-peek-overlay'), findsOneWidget);
      await tapBoardSpace(tester);
      expect(c.read(overviewFocusProvider).peeked, isNull);
    });

    testBoard('another card switches it instead', (tester) async {
      final c = await peekBusy(tester);
      await tester.tap(find.text('Chat idle').first);
      await settle(tester);
      expect(c.read(overviewFocusProvider).peeked, 'idle');
    });

    testBoard('the peek itself, the header and the filters never close it', (
      tester,
    ) async {
      final c = await peekBusy(tester);
      await tester.tap(
        find
            .descendant(
              of: byKey('overview-peek:busy'),
              matching: find.text('Chat busy'),
            )
            .first,
      );
      await settle(tester);
      expect(c.read(overviewFocusProvider).peeked, 'busy');

      await tester.tap(byKey('overview-filter-button'));
      await settle(tester);
      expect(byKey('overview-filter-panel'), findsOneWidget);
      await tester.tap(byKey('overview-filter-archived'));
      await settle(tester);
      expect(c.read(overviewFocusProvider).peeked, 'busy');
    });

    testBoard('side by side, both close', (tester) async {
      final c = await pump(tester, const Size(1900, 1000));
      c.read(overviewFocusProvider.notifier).peekSideBySide('busy', 'idle');
      await settle(tester);
      expect(byKey('overview-side-by-side-peeks'), findsOneWidget);
      await tapBoardSpace(tester);
      expect(c.read(overviewFocusProvider).peeked, isNull);
      expect(c.read(overviewFocusProvider).beside, isNull);
    });

    testBoard('not while its box holds an unsent message, which is kept', (
      tester,
    ) async {
      final c = await peekBusy(tester);
      final box = find
          .descendant(
            of: byKey('overview-peek:busy'),
            matching: find.byType(EditableText),
          )
          .last;
      await tester.enterText(box, 'half a thought');
      await settle(tester);

      await tapBoardSpace(tester);
      expect(c.read(overviewFocusProvider).peeked, 'busy');

      await tester.enterText(box, '');
      await settle(tester);
      await tapBoardSpace(tester);
      expect(c.read(overviewFocusProvider).peeked, isNull);
    });
  });
}

/// Bounded: an ask's shield breathes for ever.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _SpyActions extends ExplorerActions {
  _SpyActions(super.ref);

  final List<String> opened = [];

  @override
  Future<ExplorerResult> openNative(String sessionId) async {
    opened.add(sessionId);
    return const ExplorerResult(ExplorerOutcome.selected);
  }
}

/// A widget test that unmounts the tab before it ends, so the Agents lens's
/// own quiet timer is cancelled with the providers that held it.
void testBoard(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
