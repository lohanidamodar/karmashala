import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_reads.dart';
import 'package:karmashala/src/features/overview/presentation/overview_hybrid.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala/src/features/remote/application/remote_approval_bindings.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/presentation/approval_request_card.dart';
import 'package:karmashala/src/features/sessions/presentation/prompt_cards/question_prompt_card.dart';
import 'package:karmashala_remote/remote.dart';

import 'mission_fixture.dart';

/// Records what the Overview sends, and sends nothing.
class _SpyActions extends SessionActions {
  _SpyActions(super.ref, this.sent);

  final List<(String, String)> sent;

  @override
  Future<void> continueSession(
    String sessionId,
    String text, {
    String? requestId,
  }) async => sent.add((sessionId, text));
}

/// **The Overview, hybrid**, over a realistic workspace: the heartbeat, what
/// waits on you and what is at work, the activity in words, a quick message
/// through the one send path, and the peek — at desktop, laptop and phone
/// sizes and at 1.6× text.
void main() {
  late Directory dir;
  final sent = <(String, String)>[];

  setUp(() async {
    sent.clear();
    dir = await Directory.systemTemp.createTemp('ks-hybrid');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    MissionFixture? fixture,
    Size size = const Size(1440, 900),
    bool phone = false,
    double textScale = 1,
    Set<String> features = const {},
  }) => pumpMission(
    tester,
    fixture: fixture ?? MissionFixture.full(),
    prefsDir: dir,
    size: size,
    phone: phone,
    textScale: textScale,
    overrides: [
      sessionActionsProvider.overrideWith((ref) => _SpyActions(ref, sent)),
      if (features.isNotEmpty)
        serverOfferProvider.overrideWithValue(
          ServerOffer(sameMachine: true, features: features),
        ),
    ],
  );

  Finder queueCard(String id) =>
      find.byKey(ValueKey('overview-queue-card:$id'));
  Finder workCard(String id) => find.byKey(ValueKey('overview-work-card:$id'));

  for (final (name, size, phone) in [
    ('1440×900', const Size(1440, 900), false),
    ('1024×768', const Size(1024, 768), false),
    ('390×844', const Size(390, 844), true),
  ]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('$name at ${scale}x text: heartbeat, queue, then work', (
        tester,
      ) async {
        await pump(tester, size: size, phone: phone, textScale: scale);

        expect(find.byKey(const ValueKey('overview-heartbeat')), findsOneWidget);
        expect(queueCard('ks-r21'), findsOneWidget);
        expect(queueCard('store-reviews'), findsOneWidget);
        expect(find.byType(ApprovalRequestCard), findsWidgets);
        final queueAt = tester.getTopLeft(queueCard('ks-r21'));
        // Built only once scrolled near: measured in the list's own frame.
        final work = find.byKey(const ValueKey('overview-work'));
        await tester.scrollUntilVisible(work, 300, scrollable: hybridList);
        final scrolled = tester
            .state<ScrollableState>(hybridList)
            .position
            .pixels;
        final workAt = tester.getTopLeft(work) + Offset(0, scrolled);
        if (phone || scale > 1 && size.width < 1440) {
          // Stacked: what waits on you comes first.
          expect(queueAt.dy, lessThan(workAt.dy));
        } else {
          // Side by side: the queue on the left.
          expect(queueAt.dx, lessThan(workAt.dx));
        }
        expect(tester.takeException(), isNull);
        await tester.drag(
          find.byKey(const ValueKey('overview-hybrid')),
          const Offset(0, -6000),
        );
        await settleMission(tester);
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }
  }

  testWidgets('a raw command is never the card\'s line; it folds away', (
    tester,
  ) async {
    await pump(
      tester,
      fixture: MissionFixture(activity: MissionFixture.realisticActivity()),
    );

    final line = find.byKey(const ValueKey('overview-activity:ks-r32'));
    await tester.scrollUntilVisible(line, 200, scrollable: hybridList);
    expect(
      tester.widget<Text>(line).data,
      'Running a background command',
    );
    expect(find.textContaining(r'$sp ='), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('overview-raw-toggle:ks-r32')).first,
    );
    await settleMission(tester);
    expect(
      find.byKey(const ValueKey('overview-raw:ks-r32')),
      findsOneWidget,
    );
    expect(find.textContaining(r'$sp ='), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('a running call\'s own words lead, with its plan step beside', (
    tester,
  ) async {
    await pump(tester);

    final line = find.byKey(const ValueKey('overview-activity:ks-r32'));
    await tester.scrollUntilVisible(line, 200, scrollable: hybridList);
    expect(tester.widget<Text>(line).data, 'Run the overview tests · 4m');
    expect(find.text('2/4 · Write the layout tests'), findsOneWidget);
    await unmountMission(tester);
  });

  group('calm cards', () {
    testWidgets('a work card has no message box, strip or tinted surface', (
      tester,
    ) async {
      await pump(tester);
      final card = workCard('ks-r32');
      await tester.scrollUntilVisible(card, 200, scrollable: hybridList);
      Finder inCard(Finder f) => find.descendant(of: card, matching: f);

      expect(inCard(find.byType(TextField)), findsNothing);
      expect(find.byKey(const ValueKey('overview-strip:ks-r32')), findsNothing);
      final frame = tester.widget<Material>(
        find.byKey(const ValueKey('overview-card:ks-r32')),
      );
      final scheme = Theme.of(tester.element(card)).colorScheme;
      expect(frame.color, scheme.surfaceContainerLow);
      // An ask's card is the same surface; only its edge is coloured.
      final ask = tester.widget<Material>(
        find.byKey(const ValueKey('overview-card:ks-r21')),
      );
      expect(ask.color, scheme.surfaceContainerLow);
      expect(
        (ask.shape as RoundedRectangleBorder).side.color,
        isNot(scheme.outlineVariant),
      );
      await unmountMission(tester);
    });

    testWidgets('it shows the step, the diff and the latest message', (
      tester,
    ) async {
      await pump(tester);
      final card = workCard('ks-r30');
      await tester.scrollUntilVisible(card, 200, scrollable: hybridList);

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('overview-last:ks-r30')))
            .data,
        startsWith('Webhooks are wired: 3 events reach the inbox'),
      );
      final diff = tester.widget<Text>(
        find.byKey(const ValueKey('overview-diff:ks-r30')),
      );
      expect(diff.textSpan!.toPlainText(), '+310 −0 · 1 file');
      final r32 = tester.widget<Text>(
        find.byKey(const ValueKey('overview-diff:ks-r32')),
      );
      expect(r32.textSpan!.toPlainText(), '+620 −40 · 3 files');
      await unmountMission(tester);
    });

    testWidgets('sub-sessions: a summary, the three most urgent, "+2 more"', (
      tester,
    ) async {
      await pump(tester);
      final subs = find.byKey(const ValueKey('overview-subs:ks-r32'));
      await tester.scrollUntilVisible(subs, 200, scrollable: hybridList);

      expect(
        find.text('↳ 5 sub-sessions · 2 working · 3 done'),
        findsOneWidget,
      );
      Finder row(String id) => find.byKey(ValueKey('overview-sub:$id'));
      expect(row('ks-r32-sub0'), findsOneWidget);
      expect(row('ks-r32-sub1'), findsOneWidget);
      expect(row('ks-r32-sub2'), findsOneWidget);
      expect(row('ks-r32-sub3'), findsNothing);
      expect(find.text('+2 more'), findsOneWidget);

      await tester.tap(row('ks-r32-sub0'));
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-peek:ks-r32-sub0')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('the latest message follows the agent, lit when it changes', (
      tester,
    ) async {
      final fixture = MissionFixture.full();
      final c = await pump(tester, fixture: fixture);
      final last = find.byKey(const ValueKey('overview-last:ks-r30'));
      await tester.scrollUntilVisible(last, 200, scrollable: hybridList);

      double lit() {
        final box = tester.widget<DecoratedBox>(
          find.ancestor(of: last, matching: find.byType(DecoratedBox)).first,
        );
        return (box.decoration as BoxDecoration).color!.a;
      }

      expect(lit(), 0);
      fixture.reader.answers['ks-r30'] = const LastAnswer.of(
        'Retries now back off to ten minutes.',
      );
      c.invalidate(overviewLastAnswerProvider('ks-r30'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.widget<Text>(last).data,
        'Retries now back off to ten minutes.',
      );
      expect(lit(), greaterThan(0));
      await tester.pump(const Duration(seconds: 2));
      expect(lit(), 0);
      await unmountMission(tester);
    });
  });

  test('within a group the most urgent comes first', () {
    final fixture = MissionFixture();
    final board = buildOverviewBoard(
      fixture.groups,
      facts: fixture.facts,
      filter: const OverviewFilter(),
      groupBy: OverviewGroupBy.project,
      startOfToday: MissionFixture.now.subtract(const Duration(hours: 6)),
      memo: BoardOrderMemo(),
    );
    final ks = overviewWorkGroupsOf(board).first.$2;
    expect([for (final c in ks) c.state], [
      AgentState.working,
      AgentState.working,
      AgentState.quiet,
      AgentState.ready,
    ]);
    final queue = overviewSectionsOf(board, waitingSince: (_) => null).queue;
    expect([for (final c in queue) c.state], [
      AgentState.needsYou,
      AgentState.failed,
    ]);
  });

  group('quick message', () {
    const queue = {'sessions.send', 'sessions.interrupt', 'sessions.queue'};

    Future<Finder> peekComposer(
      WidgetTester tester,
      String title,
      String id,
    ) async {
      final open = find.text(title).first;
      await tester.scrollUntilVisible(open, 200, scrollable: hybridList);
      await tester.tap(open);
      await settleMission(tester);
      final field = find.byKey(ValueKey('overview-composer:$id'));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await settleMission(tester);
      return field;
    }

    testWidgets('Enter sends through the send path; queued while working', (
      tester,
    ) async {
      await pump(tester, features: queue);
      final field = await peekComposer(
        tester,
        'Round 32 · Overview redesign',
        'ks-r32',
      );

      await tester.enterText(field, 'Also check the phone layout');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleMission(tester);

      expect(sent, [('ks-r32', 'Also check the phone layout')]);
      expect(
        find.text('Queued · goes when this turn ends'),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await unmountMission(tester);
    });

    testWidgets('a session between turns takes it now: "Sent"', (
      tester,
    ) async {
      await pump(tester, features: queue);
      final field = await peekComposer(tester, 'Round 30 · webhooks', 'ks-r30');

      await tester.enterText(field, 'Ship it');
      final send = find.byKey(const ValueKey('overview-composer-send:ks-r30'));
      await tester.ensureVisible(send);
      await settleMission(tester);
      await tester.tap(send);
      await settleMission(tester);

      expect(sent, [('ks-r30', 'Ship it')]);
      expect(find.text('Sent'), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('Shift+Enter makes a new line, Esc clears, nothing is sent', (
      tester,
    ) async {
      await pump(tester, features: queue);
      final field = await peekComposer(tester, 'Round 30 · webhooks', 'ks-r30');
      await tester.enterText(field, 'one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settleMission(tester);
      expect(sent, isEmpty);
      expect(tester.widget<TextField>(field).controller!.text, startsWith('one'));
      // Still the field's: the Board did not take the Enter it let through.
      expect(find.byKey(const ValueKey('overview-peek')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleMission(tester);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(sent, isEmpty);
      await unmountMission(tester);
    });
  });

  group('the peek', () {
    testWidgets('shows doing now, plan, last answer, files, the composer', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('Round 32 · Overview redesign').first);
      await settleMission(tester);

      final peek = find.byKey(const ValueKey('overview-peek'));
      expect(peek, findsOneWidget);
      Finder inPeek(Finder f) => find.descendant(of: peek, matching: f);
      expect(inPeek(find.text('DOING NOW')), findsOneWidget);
      expect(inPeek(find.text('Run the overview tests · 4m')), findsOneWidget);
      expect(inPeek(find.text('Check it in a probe')), findsOneWidget);
      expect(inPeek(find.text('3 FILES CHANGED')), findsOneWidget);
      expect(inPeek(find.text('SUB-SESSIONS · 5')), findsOneWidget);
      expect(
        inPeek(find.byKey(const ValueKey('overview-composer:ks-r32'))),
        findsOneWidget,
      );
      // No answer recorded is said, not a "Reading…" that never ends.
      expect(
        inPeek(find.byKey(const ValueKey('overview-peek-no-answer'))),
        findsOneWidget,
      );
      expect(inPeek(find.text('Reading…')), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('renders the last answer as markdown, with More', (
      tester,
    ) async {
      final long = [
        'Webhooks are wired.',
        for (var i = 1; i <= 9; i++) '- step $i of the change',
      ].join('\n');
      await pump(
        tester,
        fixture: MissionFixture(
          answers: {'ks-r30': LastAnswer.of(long)},
          activity: MissionFixture.realisticActivity(),
        ),
      );
      await tester.tap(find.text('Round 30 · webhooks').first);
      await settleMission(tester);

      expect(
        find.byKey(const ValueKey('overview-peek-answer')),
        findsOneWidget,
      );
      expect(find.text('Webhooks are wired.'), findsOneWidget);
      expect(find.byKey(const ValueKey('overview-peek-more')), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('a sub-session is peeked from its parent', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Round 32 · Overview redesign').first);
      await settleMission(tester);

      await tester.tap(
        find.byKey(const ValueKey('overview-peek-sub:ks-r32-sub0')),
      );
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-peek:ks-r32-sub0')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('on a phone, the peek is a sheet with the composer', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 844), phone: true);
      await tester.tap(find.text('Round 21 · ACP sessions').first);
      await settleMission(tester);

      final peek = find.byKey(const ValueKey('overview-peek'));
      expect(peek, findsOneWidget);
      expect(
        find.descendant(
          of: peek,
          matching: find.byKey(const ValueKey('overview-composer:ks-r21')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: peek, matching: find.byType(ApprovalRequestCard)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  });

  testWidgets('what finished today folds under a line', (tester) async {
    await pump(tester);
    final fold = find.byKey(const ValueKey('overview-done-fold'));
    await tester.scrollUntilVisible(fold, 300, scrollable: hybridList);
    await tester.ensureVisible(fold);
    await settleMission(tester);
    expect(find.byKey(const ValueKey('overview-done:web-seo')), findsNothing);
    await tester.tap(fold);
    await settleMission(tester);
    expect(find.byKey(const ValueKey('overview-done:web-seo')), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('a counter filters the cards; nothing at work says so', (
    tester,
  ) async {
    final c = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('overview-counter:needsYou')));
    await settleMission(tester);
    expect(c.read(overviewPrefsProvider).filter.columns, {
      BoardColumn.needsYou,
    });
    expect(queueCard('ks-r21'), findsOneWidget);
    expect(workCard('ks-r32'), findsNothing);
    expect(
      find.byKey(const ValueKey('overview-none-at-work')),
      findsOneWidget,
    );
    await unmountMission(tester);
  });

  testWidgets('Hide while working leaves "N hidden · Show" on Working', (
    tester,
  ) async {
    final c = await pump(
      tester,
      fixture: MissionFixture(hiddenWorking: 3),
    );
    c.read(sessionListPrefsProvider.notifier).setHideWorking(true);
    await settleMission(tester);

    expect(find.text('3 hidden · Show'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-working-hidden')));
    await settleMission(tester);
    expect(c.read(sessionListPrefsProvider).hideWorking, isFalse);
    await unmountMission(tester);
  });

  testWidgets('nothing live: the work column says so', (tester) async {
    await pump(
      tester,
      fixture: MissionFixture(
        sessions: [
          for (final s in MissionFixture.realisticSessions())
            if (s.state == AgentState.ended && s.parent == null) s,
        ],
      ),
      size: const Size(390, 844),
      phone: true,
    );
    expect(find.byKey(const ValueKey('overview-queue')), findsNothing);
    expect(
      find.byKey(const ValueKey('overview-none-at-work')),
      findsOneWidget,
    );
    expect(find.text('4 done today'), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('a question in the queue is round 35\'s dense card', (
    tester,
  ) async {
    final now = MissionFixture.now;
    final asking = (
      id: 'ask-q',
      title: 'Pick the matrix',
      project: 'p-beej',
      machine: 'windows',
      agent: AgentIds.claudeCode,
      state: AgentState.needsYou,
      age: const Duration(minutes: 3),
      parent: null,
      report: AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-ask-q',
        status: AgentActivityStatus.awaitingApproval,
        observedAt: now,
        source: AgentStatusSource.hook,
        waiting: AgentWaitKind.question,
        waitingSince: now.subtract(const Duration(minutes: 3)),
      ),
    );
    const question = RemoteQuestion(
      toolUseId: 'toolu_q',
      questions: [
        RemoteQuestionItem(
          question: 'Which Xcode should the macOS matrix pin?',
          header: 'Xcode',
          multiSelect: false,
          options: [
            RemoteQuestionOption(label: '16.4 (stable)'),
            RemoteQuestionOption(label: '26 beta'),
          ],
        ),
      ],
    );
    await pumpMission(
      tester,
      fixture: MissionFixture(sessions: [asking]),
      prefsDir: dir,
      overrides: [
        chatOpenQuestionProvider.overrideWith(
          (ref, id) async => id == 'ask-q' ? question : null,
        ),
        sessionAnswerableProvider.overrideWithValue((_) => true),
      ],
    );

    final card = find.descendant(
      of: queueCard('ask-q'),
      matching: find.byType(QuestionPromptCard),
    );
    expect(card, findsOneWidget);
    final drawn = tester.widget<QuestionPromptCard>(card);
    expect(drawn.dense, isTrue);
    expect(drawn.showHeader, isFalse);
    expect(find.text('16.4 (stable)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  });

  group('heartbeat', () {
    testWidgets('failed has its own counter, and it shows failures alone', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final c = await pump(tester);
      expect(find.bySemanticsLabel(RegExp(r'^Needs you, 1, ')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Failed, 1, ')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('overview-counter:failed')));
      await settleMission(tester);
      expect(c.read(overviewPrefsProvider).filter.states, {AgentState.failed});
      expect(queueCard('store-reviews'), findsOneWidget);
      expect(queueCard('ks-r21'), findsNothing);
      expect(workCard('ks-r32'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp(r'^Failed, 1, showing only these')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('overview-counter:needsYou')));
      await settleMission(tester);
      expect(queueCard('ks-r21'), findsOneWidget);
      expect(queueCard('store-reviews'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('overview-counter:needsYou')));
      await settleMission(tester);
      expect(c.read(overviewPrefsProvider).filter.allStates, isTrue);
      expect(queueCard('store-reviews'), findsOneWidget);
      handle.dispose();
      await unmountMission(tester);
    });

    testWidgets('one slim row with the sparkline beside the counters', (
      tester,
    ) async {
      await pump(tester);
      final heart = find.byKey(const ValueKey('overview-heartbeat'));
      final chart = find.byKey(const ValueKey('overview-heartbeat-chart'));
      expect(chart, findsOneWidget);
      expect(find.byKey(const ValueKey('overview-chart-toggle')), findsNothing);
      expect(tester.getSize(heart).height, lessThan(64));
      expect(
        tester.getCenter(chart).dx,
        greaterThan(
          tester.getCenter(find.byKey(const ValueKey('overview-counters'))).dx,
        ),
      );
      await unmountMission(tester);
    });

    testWidgets('on a phone the sparkline folds behind a toggle', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 844), phone: true);
      final chart = find.byKey(const ValueKey('overview-heartbeat-chart'));
      expect(chart, findsNothing);
      await tester.tap(find.byKey(const ValueKey('overview-chart-toggle')));
      await settleMission(tester);
      expect(chart, findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  });

  group('group by context', () {
    MissionFixture filed() => MissionFixture(
      activity: MissionFixture.realisticActivity(),
      contexts: const [
        OverviewLaneKey('c-apps', 'Apps'),
        OverviewLaneKey('c-web', 'Web'),
      ],
      contextOfProject: const {
        'p-ks': 'c-apps',
        'p-beej': 'c-apps',
        'p-web': 'c-web',
      },
    );

    Finder group(String key) =>
        find.byKey(ValueKey('overview-work-group:$key'));

    testWidgets('a header per context in order, "No context" last', (
      tester,
    ) async {
      final c = await pump(tester, fixture: filed());
      c.read(overviewPrefsProvider.notifier).setGroupBy(OverviewGroupBy.context);
      await settleMission(tester);

      expect(
        find.descendant(
          of: group('c-apps'),
          matching: find.textContaining('Apps · '),
        ),
        findsOneWidget,
      );
      // Each card names its context too.
      expect(find.textContaining('Apps · karmashala'), findsWidgets);
      final apps = tester.getTopLeft(group('c-apps')).dy;
      final web = tester.getTopLeft(group('c-web')).dy;
      expect(apps, lessThan(web));
      final none = group(kOverviewUnfiledLane);
      await tester.scrollUntilVisible(none, 300, scrollable: hybridList);
      expect(
        find.descendant(of: none, matching: find.textContaining('No context')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('the panel offers Context only when a context exists', (
      tester,
    ) async {
      await pump(tester, fixture: filed());
      await tester.tap(find.byKey(const ValueKey('overview-filter-button')));
      await settleMission(tester);
      expect(find.byKey(const ValueKey('group-by:context')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('group-by:context')));
      await settleMission(tester);
      await unmountMission(tester);
    });

    testWidgets('a saved Context with no context left groups by project', (
      tester,
    ) async {
      final c = await pump(tester);
      c.read(overviewPrefsProvider.notifier).setGroupBy(OverviewGroupBy.context);
      await settleMission(tester);

      expect(c.read(overviewGroupByProvider), OverviewGroupBy.project);
      expect(group('p-ks'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('overview-filter-button')));
      await settleMission(tester);
      expect(find.byKey(const ValueKey('group-by:context')), findsNothing);
      await unmountMission(tester);
    });
  });
}
