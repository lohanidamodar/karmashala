import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_reads.dart';
import 'package:karmashala/src/features/overview/application/overview_seen.dart';
import 'package:karmashala/src/features/overview/presentation/overview_hybrid.dart';
import 'package:karmashala/src/features/overview/presentation/overview_done_card.dart';
import 'package:karmashala/src/features/overview/presentation/overview_title_block.dart'
    show OverviewChipFit;
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala_session/delivery.dart'
    show DeliveryAction, OfferedAction;
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart'
    show sessionsStartingProvider;
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
    ('360×800', const Size(360, 800), true),
  ]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('$name at ${scale}x text: heartbeat, queue, then work', (
        tester,
      ) async {
        await pump(tester, size: size, phone: phone, textScale: scale);

        expect(
          find.byKey(const ValueKey('overview-heartbeat')),
          findsOneWidget,
        );
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
    expect(tester.widget<Text>(line).data, 'Running a background command');
    expect(find.textContaining(r'$sp ='), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('overview-raw-toggle:ks-r32')).first,
    );
    await settleMission(tester);
    expect(find.byKey(const ValueKey('overview-raw:ks-r32')), findsOneWidget);
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
      final card = find.byKey(const ValueKey('overview-ready-card:ks-r30'));
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

    testWidgets('sub-sessions inside their parent: a summary, then every one '
        'up to five, each with its latest line and state', (tester) async {
      final fixture = MissionFixture.full();
      fixture.reader.answers['ks-r32-sub0'] = const LastAnswer.of(
        'Ran the layout tests: all green.',
      );
      await pump(tester, fixture: fixture);
      final subs = find.byKey(const ValueKey('overview-subs:ks-r32'));
      await tester.scrollUntilVisible(subs, 200, scrollable: hybridList);

      expect(
        find.text('↳ 5 sub-sessions · 2 working · 3 done'),
        findsOneWidget,
      );
      Finder row(String id) => find.byKey(ValueKey('overview-sub:$id'));
      for (var i = 0; i < 5; i++) {
        expect(row('ks-r32-sub$i'), findsOneWidget, reason: 'sub$i');
      }
      expect(find.textContaining('more'), findsNothing);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-last:ks-r32-sub0')),
            )
            .data,
        'Ran the layout tests: all green.',
      );

      await tester.tap(row('ks-r32-sub0'));
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-peek:ks-r32-sub0')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    MissionFixture withSubs(
      MissionSession Function(MissionSession s) change, {
      List<MissionSession> extra = const [],
    }) => MissionFixture(
      sessions: [...MissionFixture.realisticSessions().map(change), ...extra],
    );
    MissionSession asState(MissionSession s, AgentState state) => (
      id: s.id,
      title: s.title,
      project: s.project,
      machine: s.machine,
      agent: s.agent,
      state: state,
      age: s.age,
      parent: s.parent,
      report: s.report,
    );

    // The owner: "I asked an agent to start a sub-session from the dashboard
    // chat. It started … but the dashboard isn't showing it." Its parent had
    // finished its turn — a ready card, which drew no sub-sessions — and the
    // child, with nothing reported yet, read as ready too.
    MissionFixture agentStartedChild() => MissionFixture(
      sessions: [
        ...MissionFixture.realisticSessions(),
        (
          id: 'ks-r30-child',
          title: 'Check the webhook retries',
          project: 'p-ks',
          machine: 'windows',
          agent: AgentIds.claudeCode,
          state: AgentState.ready,
          age: Duration.zero,
          parent: 'ks-r30',
          report: null,
        ),
      ],
      starting: const {'ks-r30-child'},
    );

    testWidgets('an agent-started child shows at once inside its parent, '
        '"Starting…"', (tester) async {
      await pump(tester, fixture: agentStartedChild());
      final subs = find.byKey(const ValueKey('overview-subs:ks-r30'));
      await tester.scrollUntilVisible(subs, 200, scrollable: hybridList);

      final row = find.byKey(const ValueKey('overview-sub:ks-r30-child'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('Starting…')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('as cards, it is an "At work" card at once, "Starting…"', (
      tester,
    ) async {
      final c = await pump(tester, fixture: agentStartedChild());
      c
          .read(overviewPrefsProvider.notifier)
          .setSubSessions(OverviewSubSessionMode.cards);
      await settleMission(tester);

      final card = find.byKey(
        const ValueKey('overview-work-card:ks-r30-child'),
      );
      await tester.scrollUntilVisible(card, 200, scrollable: hybridList);
      expect(
        find.descendant(of: card, matching: find.textContaining('Starting…')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-ready-card:ks-r30-child')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('inside: a sixth folds into "+1 more"', (tester) async {
      final sixth = asState(
        MissionFixture.realisticSessions().firstWhere(
          (s) => s.id == 'ks-r32-sub4',
        ),
        AgentState.ended,
      );
      await pump(
        tester,
        fixture: withSubs(
          (s) => s,
          extra: [
            (
              id: 'ks-r32-sub5',
              title: 'Subagent 6',
              project: sixth.project,
              machine: sixth.machine,
              agent: sixth.agent,
              state: AgentState.ended,
              age: const Duration(minutes: 9),
              parent: 'ks-r32',
              report: null,
            ),
          ],
        ),
      );
      final subs = find.byKey(const ValueKey('overview-subs:ks-r32'));
      await tester.scrollUntilVisible(subs, 200, scrollable: hybridList);
      expect(find.text('+1 more'), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('inside: a child that needs you stands out as a waiting card '
        'does', (tester) async {
      await pump(
        tester,
        fixture: withSubs(
          (s) => s.id == 'ks-r32-sub2' ? asState(s, AgentState.needsYou) : s,
        ),
      );
      final subs = find.byKey(const ValueKey('overview-subs:ks-r32'));
      await tester.scrollUntilVisible(subs, 200, scrollable: hybridList);
      expect(
        find.byKey(const ValueKey('overview-sub-needs-you:ks-r32-sub2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-sub-needs-you:ks-r32-sub0')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('as cards: each child is a card of its own after its parent, '
        'tied to it, and the parent stacks none', (tester) async {
      final c = await pump(tester);
      c
          .read(overviewPrefsProvider.notifier)
          .setSubSessions(OverviewSubSessionMode.cards);
      await settleMission(tester);

      expect(find.byKey(const ValueKey('overview-subs:ks-r32')), findsNothing);
      final work = [
        for (final card in overviewSectionsOf(
          c.read(overviewBoardProvider),
          waitingSince: (_) => null,
        ).work)
          card.id,
      ];
      final at = work.indexOf('ks-r32');
      expect(work.sublist(at + 1, at + 3), ['ks-r32-sub0', 'ks-r32-sub1']);

      final child = find.byKey(
        const ValueKey('overview-work-card:ks-r32-sub0'),
      );
      await tester.scrollUntilVisible(child, 200, scrollable: hybridList);
      expect(
        find.descendant(
          of: child,
          matching: find.text('↳ Round 32 · Overview redesign'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-child-link:ks-r32-sub0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-child-link:ks-r32')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('the filter panel offers the choice, and it is kept', (
      tester,
    ) async {
      final c = await pump(tester);
      expect(
        c.read(overviewPrefsProvider).subSessions,
        OverviewSubSessionMode.inside,
      );
      await tester.tap(find.byKey(const ValueKey('overview-filter-button')));
      await settleMission(tester);
      await tester.tap(find.byKey(const ValueKey('sub-sessions:cards')));
      await settleMission(tester);

      expect(
        c.read(overviewPrefsProvider).subSessions,
        OverviewSubSessionMode.cards,
      );
      expect(
        OverviewPrefs.fromJson(
          c.read(overviewPrefsProvider).toJson(),
        ).subSessions,
        OverviewSubSessionMode.cards,
      );
      await unmountMission(tester);
    });

    for (final mode in OverviewSubSessionMode.values) {
      for (final size in const [Size(360, 800), Size(1440, 900)]) {
        testWidgets('${mode.name} at ${size.width.toInt()} px and text scale '
            '1.6 fits', (tester) async {
          final c = await pump(
            tester,
            size: size,
            phone: size.width < 600,
            textScale: 1.6,
          );
          c.read(overviewPrefsProvider.notifier).setSubSessions(mode);
          await settleMission(tester);
          // A phone draws a row per session; a desktop a card.
          await tester.scrollUntilVisible(
            size.width < 600
                ? find.byKey(const ValueKey('overview-phone-row:ks-r32'))
                : find.textContaining('Round 32 · Overview redesign').first,
            200,
            scrollable: hybridList,
          );
          expect(tester.takeException(), isNull);
          if (mode == OverviewSubSessionMode.cards) {
            await tester.scrollUntilVisible(
              find.byKey(const ValueKey('overview-child-link:ks-r32-sub0')),
              200,
              scrollable: hybridList,
            );
            expect(tester.takeException(), isNull);
          }
          await unmountMission(tester);
        });
      }
    }

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
    expect(
      [for (final c in ks) c.state],
      [AgentState.working, AgentState.working, AgentState.quiet],
    );
    final queue = overviewSectionsOf(board, waitingSince: (_) => null).queue;
    expect(
      [for (final c in queue) c.state],
      [AgentState.needsYou, AgentState.failed],
    );
  });

  group('the peek', () {
    Future<void> peek(WidgetTester tester, String title) async {
      final open = find.text(title).first;
      await tester.scrollUntilVisible(open, 200, scrollable: hybridList);
      await tester.tap(open);
      await settleMission(tester);
    }

    Finder inPeek(Finder f) => find.descendant(
      of: find.byKey(const ValueKey('overview-peek')),
      matching: f,
    );

    testWidgets('is the session\'s own chat, under its header and tabs', (
      tester,
    ) async {
      await pump(tester);
      await peek(tester, 'Round 32 · Overview redesign');

      expect(
        inPeek(find.byKey(const ValueKey('overview-peek-chat:ks-r32'))),
        findsOneWidget,
      );
      // The views as glyphs in the header's one row (round 66).
      expect(inPeek(find.byTooltip('Chat')), findsOneWidget);
      expect(inPeek(find.byTooltip('Files · 3 changed')), findsOneWidget);
      expect(inPeek(find.byTooltip('Sub-sessions · 5')), findsOneWidget);
      // No terminal on this machine: no Terminal tab.
      expect(inPeek(find.byTooltip('Terminal')), findsNothing);
      expect(
        inPeek(find.byKey(const ValueKey('overview-peek-open'))),
        findsOneWidget,
      );
      // "Open", or its glyph where the peek is narrow, named in full.
      expect(inPeek(find.byTooltip('Open in a tab')), findsOneWidget);
      expect(inPeek(find.text('Open tab')), findsNothing);
      // The model its agent says it runs, and where, on the status strip.
      final strip = find.byKey(const ValueKey('overview-peek-controls'));
      expect(
        find.descendant(of: strip, matching: find.text('Opus 5.5')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: strip,
          matching: find.byKey(const ValueKey('overview-peek-place')),
        ),
        findsOneWidget,
      );
      expect(inPeek(find.text('2/4')), findsOneWidget);
      // The old peek's sections are gone: the chat is the record.
      expect(inPeek(find.text('DOING NOW')), findsNothing);
      expect(
        find.byKey(const ValueKey('overview-composer:ks-r32')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('Files shows each file\'s +/− and opens its diff', (
      tester,
    ) async {
      await pump(tester);
      await peek(tester, 'Round 32 · Overview redesign');
      await tester.tap(find.byKey(const ValueKey('overview-peek-tab:files')));
      await settleMission(tester);

      const path =
          'app/lib/src/features/overview/presentation/overview_hybrid.dart';
      final stat = tester.widget<Text>(
        find.byKey(const ValueKey('overview-peek-file-stat:$path')),
      );
      expect(stat.textSpan!.toPlainText(), '+212 −40');
      expect(inPeek(find.text('overview_hybrid_test.dart')), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('Sub-sessions lists them all; one opens with its way back', (
      tester,
    ) async {
      await pump(tester);
      await peek(tester, 'Round 32 · Overview redesign');
      await tester.tap(
        find.byKey(const ValueKey('overview-peek-tab:subSessions')),
      );
      await settleMission(tester);
      for (var i = 0; i < 5; i++) {
        expect(
          find.byKey(ValueKey('overview-peek-sub:ks-r32-sub$i')),
          findsOneWidget,
        );
      }
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('overview-peek-sub:ks-r32-sub0')),
          matching: find.text('Subagent 1'),
        ),
      );
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-peek:ks-r32-sub0')),
        findsOneWidget,
      );
      // The way back is in ⋯, the header being one row (round 66).
      await tester.tap(find.byKey(const ValueKey('overview-peek-more')));
      await settleMission(tester);
      expect(
        find.text('Sub-session of Round 32 · Overview redesign'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('overview-peek-menu:parent')));
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-peek:ks-r32')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('a terminal-hosted session has a Terminal tab', (tester) async {
      await pump(
        tester,
        fixture: MissionFixture(
          activity: MissionFixture.realisticActivity(),
          panes: const {'ks-r32': 'pane-r32'},
        ),
      );
      await peek(tester, 'Round 32 · Overview redesign');
      expect(
        find.byKey(const ValueKey('overview-peek-tab:terminal')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('overview-peek-tab:terminal')),
      );
      await settleMission(tester);
      // No instance for the fixture's pane: said, not a blank.
      expect(
        find.text('This session has no terminal open on this machine.'),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('↑ ↓ walk the sessions; ✕ closes', (tester) async {
      final c = await pump(tester);
      await peek(tester, 'Round 21 · ACP sessions');
      await tester.tap(find.byKey(const ValueKey('overview-peek-next')));
      await settleMission(tester);
      final next = c.read(overviewFocusProvider).peeked;
      expect(next, isNot('ks-r21'));
      await tester.tap(find.byKey(const ValueKey('overview-peek-previous')));
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, 'ks-r21');
      await tester.tap(find.byKey(const ValueKey('overview-peek-close')));
      await settleMission(tester);
      expect(find.byKey(const ValueKey('overview-peek')), findsNothing);
      await unmountMission(tester);
    });

    for (final (name, size, mode) in [
      ('1440', const Size(1440, 900), 'docked'),
      ('1100', const Size(1100, 800), 'overlay'),
    ]) {
      testWidgets('$name px: the peek is $mode', (tester) async {
        await pump(tester, size: size);
        final workAt = tester.getTopLeft(
          find.byKey(const ValueKey('overview-work')),
        );
        await peek(tester, 'Round 21 · ACP sessions');
        final overlay = find.byKey(const ValueKey('overview-peek-overlay'));
        if (mode == 'overlay') {
          expect(overlay, findsOneWidget);
          // The board keeps its columns under it.
          expect(
            tester.getTopLeft(find.byKey(const ValueKey('overview-work'))),
            workAt,
          );
        } else {
          expect(overlay, findsNothing);
          expect(
            find.byKey(const ValueKey('overview-peek-resizer')),
            findsOneWidget,
          );
          final before = tester.getSize(
            find.byKey(const ValueKey('overview-peek')),
          );
          await tester.drag(
            find.byKey(const ValueKey('overview-peek-resizer')),
            const Offset(-100, 0),
          );
          await settleMission(tester);
          expect(
            tester.getSize(find.byKey(const ValueKey('overview-peek'))).width,
            greaterThan(before.width),
          );
        }
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }

    testWidgets('on a phone, the peek is a full-screen sheet', (tester) async {
      await pump(tester, size: const Size(390, 844), phone: true);
      await tester.tap(find.text('Round 21 · ACP sessions').first);
      await settleMission(tester);

      final peek = find.byKey(const ValueKey('overview-peek'));
      expect(peek, findsOneWidget);
      expect(tester.getSize(peek).height, greaterThan(700));
      expect(
        inPeek(find.byKey(const ValueKey('overview-peek-chat:ks-r21'))),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    testWidgets(
      'since you last looked: a count on the card, the line in chat',
      (tester) async {
        final now = MissionFixture.now;
        final fixture = MissionFixture(
          activity: MissionFixture.realisticActivity(),
          glances: {
            'ks-r30': OverviewGlance(
              messageTimes: [
                for (final m in [40, 30, 20, 10, 5])
                  now.subtract(Duration(minutes: m)),
              ],
            ),
          },
        );
        final c = await pump(tester, fixture: fixture);
        final badge = find.byKey(const ValueKey('overview-new:ks-r30'));
        // Never opened here: nothing to count from.
        expect(badge, findsNothing);
        final looked = now.subtract(const Duration(minutes: 25));
        c.read(overviewSeenProvider.notifier).markSeen('ks-r30', looked);
        await settleMission(tester);
        await tester.scrollUntilVisible(badge, 200, scrollable: hybridList);
        expect(
          find.descendant(of: badge, matching: find.text('3')),
          findsOneWidget,
        );

        final title = find.text('Round 30 · webhooks').first;
        await tester.ensureVisible(title);
        await settleMission(tester);
        await tester.tap(title);
        await settleMission(tester);
        // The chat is told when the owner last looked, to draw its line.
        expect(
          find.text('chat:ks-r30 seen:${looked.toIso8601String()}'),
          findsOneWidget,
        );
        expect(badge, findsNothing);
        expect(c.read(overviewSeenProvider)['ks-r30']!.isAfter(looked), isTrue);
        await unmountMission(tester);
      },
    );

    test('the last look is kept on this device', () async {
      final c = ProviderContainer(
        overrides: [
          overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      final at = DateTime.utc(2026, 10, 7, 9);
      c.read(overviewSeenProvider.notifier).markSeen('s1', at);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      c.dispose();
      final again = ProviderContainer(
        overrides: [
          overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      addTearDown(again.dispose);
      again.read(overviewSeenProvider);
      for (var i = 0; i < 50 && again.read(overviewSeenProvider).isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(again.read(overviewSeenProvider)['s1'], at);
    });
  });

  group('the phone', () {
    // The owner, on a Pixel: the sheet's header took 40% of the screen before
    // any chat — a drag handle, two-line title, three lines of meta with the
    // raw model id, usage and limit lines, a row of buttons, and a tab row
    // whose last tab was cut off.
    for (final size in const [Size(360, 640), Size(390, 844)]) {
      for (final scale in const [1.0, 1.6]) {
        testWidgets('the peek at ${size.width.toInt()}×${size.height.toInt()} '
            'and text ×$scale is a page whose chat has the room', (
          tester,
        ) async {
          final c = await pump(
            tester,
            size: size,
            phone: true,
            textScale: scale,
          );
          final row = find.byKey(const ValueKey('overview-phone-row:ks-r32'));
          await tester.scrollUntilVisible(row, 300, scrollable: hybridList);
          // The title: the row's own controls may sit at its middle.
          final title = find.byKey(
            const ValueKey('overview-card-title:ks-r32'),
          );
          await tester.ensureVisible(title);
          await settleMission(tester);
          await tester.tap(title);
          await settleMission(tester);

          // A page with a slim bar, not a sheet with a drag handle.
          expect(find.byType(BottomSheet), findsNothing);
          expect(find.byKey(const ValueKey('overview-peek-bar')), findsOne);
          expect(tester.takeException(), isNull);

          final body = tester.getRect(
            find.byKey(const ValueKey('overview-peek-body')),
          );
          expect(body.height, greaterThanOrEqualTo(size.height * 0.6));

          // The model by its name, on the strip and never folded.
          final strip = find.byKey(const ValueKey('overview-peek-controls'));
          expect(
            find
                .descendant(of: strip, matching: find.text('Opus 5.5'))
                .hitTestable(),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: strip,
              matching: find.textContaining('claude-'),
            ),
            findsNothing,
          );

          // The views in the bar, beside back.
          final back = tester.getRect(
            find.byKey(const ValueKey('overview-peek-close')),
          );
          final views = tester.getRect(
            find.byKey(const ValueKey('overview-peek-tabs')),
          );
          expect((views.center.dy - back.center.dy).abs(), lessThan(2));

          // Every action in reach: back in the bar, the rest in ⋯, and the
          // session's own strip under the chat.
          expect(find.byKey(const ValueKey('overview-peek-close')), findsOne);
          expect(
            find.byKey(const ValueKey('overview-peek-controls')),
            findsOne,
          );
          await tester.tap(find.byKey(const ValueKey('overview-peek-more')));
          await settleMission(tester);
          for (final item in const ['subSessions', 'pin', 'previous', 'next']) {
            expect(
              find.byKey(ValueKey('overview-peek-menu:$item')),
              findsOne,
              reason: item,
            );
          }
          // Open is the session menu's own, as everywhere (round 66).
          expect(find.byKey(const ValueKey('session-menu:open')), findsOne);
          expect(tester.takeException(), isNull);
          // An item does what it says, and closes the menu.
          await tester.tap(
            find.byKey(const ValueKey('overview-peek-menu:pin')),
          );
          await settleMission(tester);
          expect(c.read(overviewPrefsProvider).pinned, contains('ks-r32'));

          await tester.tap(find.byKey(const ValueKey('overview-peek-close')));
          await settleMission(tester);
          await tester.pump(const Duration(seconds: 1));
          expect(c.read(overviewFocusProvider).peeked, isNull);
          expect(find.byKey(const ValueKey('overview-peek')), findsNothing);
          await unmountMission(tester);
        });
      }
    }

    for (final (name, size) in [
      ('390', const Size(390, 844)),
      ('360', const Size(360, 800)),
    ]) {
      testWidgets('$name px: a two-line list, the queue first', (tester) async {
        await pump(tester, size: size, phone: true);
        final row = find.byKey(const ValueKey('overview-phone-row:ks-r32'));
        await tester.scrollUntilVisible(row, 300, scrollable: hybridList);
        expect(row, findsOneWidget);
        expect(workCard('ks-r32'), findsNothing);
        // Two lines: the title and what it is doing, nothing more, beside
        // the state chip (which holds its full and short forms).
        final chip = find.descendant(
          of: row,
          matching: find.byType(OverviewChipFit),
        );
        expect(chip, findsOneWidget);
        expect(
          find
              .descendant(of: row, matching: find.byType(Text))
              .evaluate()
              .where(
                (e) => find
                    .descendant(of: chip, matching: find.byWidget(e.widget))
                    .evaluate()
                    .isEmpty,
              ),
          hasLength(2),
        );
        final ready = find.byKey(const ValueKey('overview-phone-row:ks-r30'));
        await tester.scrollUntilVisible(ready, 300, scrollable: hybridList);
        expect(
          find.byKey(const ValueKey('overview-ready-card:ks-r30')),
          findsNothing,
        );

        await tester.scrollUntilVisible(row, -300, scrollable: hybridList);
        await settleMission(tester);
        await tester.tap(row);
        await settleMission(tester);
        final peek = find.byKey(const ValueKey('overview-peek'));
        expect(peek, findsOneWidget);
        expect(tester.getSize(peek).height, greaterThan(size.height * 0.8));
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }

    testWidgets('the queue comes before the list', (tester) async {
      await pump(tester, size: const Size(390, 844), phone: true);
      final queueAt = tester.getTopLeft(queueCard('ks-r21')).dy;
      final row = find.byKey(const ValueKey('overview-phone-row:ks-r32'));
      await tester.scrollUntilVisible(row, 300, scrollable: hybridList);
      final scrolled = tester
          .state<ScrollableState>(hybridList)
          .position
          .pixels;
      expect(queueAt, lessThan(tester.getTopLeft(row).dy + scrolled));
      await unmountMission(tester);
    });
  });

  group('New session', () {
    testWidgets('opens the app\'s dialog, kept here and in chat form', (
      tester,
    ) async {
      final c = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('overview-new-session')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final dialog = tester.widget<NewSessionDialog>(
        find.byType(NewSessionDialog),
      );
      expect(dialog.keepHere, isTrue);
      expect(dialog.preferChat, isTrue);

      // Kept here: its card is picked and peeked, and nothing else opens.
      final started = MissionFixture().entry(
        MissionFixture.realisticSessions().firstWhere((s) => s.id == 'ks-r30'),
      );
      dialog.onStarted!(started.native!, keptHere: true);
      await tester.pump();
      expect(c.read(overviewFocusProvider).peeked, 'ks-r30');
      expect(c.read(overviewFocusProvider).selected, 'ks-r30');

      // Unticked: a tab, this once. The setting is what the tick starts
      // from, and the dialog does not rewrite it.
      c.read(overviewFocusProvider.notifier).closePeek();
      dialog.onStarted!(started.native!, keptHere: false);
      await tester.pump();
      expect(c.read(overviewFocusProvider).peeked, isNull);
      expect(c.read(overviewPrefsProvider).launchInBackground, isTrue);
      await unmountMission(tester);
    });

    testWidgets('with the setting off, the dialog starts unticked', (
      tester,
    ) async {
      final c = await pump(tester);
      c.read(overviewPrefsProvider.notifier).setLaunchInBackground(false);
      await tester.tap(find.byKey(const ValueKey('overview-new-session')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester.widget<NewSessionDialog>(find.byType(NewSessionDialog)).keepHere,
        isFalse,
      );
      await unmountMission(tester);
    });
  });

  group('the Done lane', () {
    const merge = OfferedAction(
      DeliveryAction.merge,
      isPrimary: true,
      promptOverride: 'Merge the pull request with a squash.',
    );

    testWidgets('ready sessions sit at the bottom, out of At work', (
      tester,
    ) async {
      await pump(tester);
      final lane = find.byKey(const ValueKey('overview-ready'));
      await tester.scrollUntilVisible(lane, 300, scrollable: hybridList);
      expect(find.text('DONE · READY TO CLOSE · 4'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overview-ready-card:ks-r30')),
        findsOneWidget,
      );
      expect(workCard('ks-r30'), findsNothing);
      expect(
        tester.getTopLeft(lane).dy,
        greaterThan(tester.getTopLeft(workCard('relay-load')).dy),
      );
      await unmountMission(tester);
    });

    testWidgets(
      'Merge sends the delivery strip\'s own merge, naming the base',
      (tester) async {
        final fixture = MissionFixture(
          answers: MissionFixture.realisticAnswers(),
          activity: MissionFixture.realisticActivity(),
          merges: const {'ks-r30': (merge, 'origin/feat/acp')},
        );
        await pump(tester, fixture: fixture);
        final button = find.byKey(const ValueKey('overview-merge:ks-r30'));
        await tester.scrollUntilVisible(button, 300, scrollable: hybridList);
        await tester.ensureVisible(button);
        await settleMission(tester);
        final tip = tester.widget<Tooltip>(
          find.ancestor(of: button, matching: find.byType(Tooltip)).first,
        );
        expect(tip.message, contains('into origin/feat/acp'));
        await tester.tap(button);
        await settleMission(tester);
        expect(sent, [('ks-r30', 'Merge the pull request with a squash.')]);

        // No pull request: nothing to merge yet, and it says so.
        final none = find.byKey(const ValueKey('overview-merge:beej-ci'));
        await tester.scrollUntilVisible(none, 300, scrollable: hybridList);
        expect(tester.widget<FilledButton>(none).onPressed, isNull);
        expect(
          tester
              .widget<Tooltip>(
                find.ancestor(of: none, matching: find.byType(Tooltip)).first,
              )
              .message,
          startsWith('Nothing to merge yet'),
        );
        await unmountMission(tester);
      },
    );

    testWidgets('a sub-session hands its last answer back to its parent', (
      tester,
    ) async {
      final sessions = [
        for (final s in MissionFixture.realisticSessions())
          if (s.id != 'ks-r32-sub2') s,
        (
          id: 'ks-r29-child',
          title: 'Fork benchmarks',
          project: 'p-ks',
          machine: 'windows',
          agent: AgentIds.claudeCode,
          state: AgentState.ready,
          age: const Duration(minutes: 4),
          parent: 'ks-r29',
          report: null,
        ),
      ];
      await pump(
        tester,
        fixture: MissionFixture(
          sessions: sessions,
          answers: const {
            'ks-r29-child': LastAnswer.of('Forks are 3× faster on SSH.'),
          },
        ),
      );
      final button = find.byKey(
        const ValueKey('overview-hand-back:ks-r29-child'),
      );
      await tester.scrollUntilVisible(button, 300, scrollable: hybridList);
      await tester.ensureVisible(button);
      await settleMission(tester);
      await tester.tap(button);
      await settleMission(tester);
      expect(sent, [
        (
          'ks-r29',
          handBackMessage('Fork benchmarks', 'Forks are 3× faster on SSH.'),
        ),
      ]);
      // A top-level session has no parent to hand back to.
      expect(
        find.byKey(const ValueKey('overview-hand-back:ks-r30')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('overview-done-archive:ks-r29-child')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    MissionSession child(
      String id,
      String parent,
      AgentState state, {
      Duration age = const Duration(minutes: 3),
    }) => (
      id: id,
      title: 'Child $id',
      project: 'p-ks',
      machine: 'windows',
      agent: AgentIds.claudeCode,
      state: state,
      age: age,
      parent: parent,
      report: null,
    );

    testWidgets('a parent whose sub-session works stays at work and says '
        'what it waits on', (tester) async {
      await pump(
        tester,
        fixture: MissionFixture(
          sessions: [
            ...MissionFixture.realisticSessions(),
            child('ks-r30-a', 'ks-r30', AgentState.working),
          ],
        ),
      );
      final card = find.byKey(const ValueKey('overview-work-card:ks-r30'));
      await tester.scrollUntilVisible(card, 200, scrollable: hybridList);
      expect(
        find.descendant(
          of: card,
          matching: find.text('Waiting on 1 sub-session'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-ready-card:ks-r30')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    for (final mode in OverviewSubSessionMode.values) {
      testWidgets('${mode.name}: a done parent\'s sub-sessions are seen from '
          'the Done lane', (tester) async {
        final c = await pump(
          tester,
          fixture: MissionFixture(
            sessions: [
              ...MissionFixture.realisticSessions(),
              child('ks-r29-a', 'ks-r29', AgentState.ended),
              child('ks-r29-b', 'ks-r29', AgentState.ended),
            ],
          ),
        );
        c.read(overviewPrefsProvider.notifier).setSubSessions(mode);
        await settleMission(tester);
        final fold = find.byKey(const ValueKey('overview-done-fold'));
        await tester.scrollUntilVisible(fold, 200, scrollable: hybridList);
        await tester.tap(fold);
        await settleMission(tester);

        if (mode == OverviewSubSessionMode.inside) {
          final line = find.byKey(const ValueKey('overview-done-subs:ks-r29'));
          await tester.scrollUntilVisible(line, 200, scrollable: hybridList);
          expect(
            find.descendant(of: line, matching: find.text('↳ 2 sub-sessions')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('overview-sub:ks-r29-a')),
            findsNothing,
          );
          await tester.tap(line);
          await settleMission(tester);
          expect(
            find.byKey(const ValueKey('overview-sub:ks-r29-a')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('overview-sub:ks-r29-b')),
            findsOneWidget,
          );
        } else {
          final tied = find.byKey(
            const ValueKey('overview-child-link:ks-r29-a'),
          );
          await tester.scrollUntilVisible(tied, 200, scrollable: hybridList);
          expect(tied, findsOneWidget);
          expect(
            find.byKey(const ValueKey('overview-child-link:ks-r29-b')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }

    testWidgets("a ready card's Archive waits while it is resumed, and says "
        'why', (tester) async {
      final c = await pump(tester);
      final archive = find.byKey(
        const ValueKey('overview-done-archive:ks-r30'),
      );
      await tester.scrollUntilVisible(archive, 300, scrollable: hybridList);
      await settleMission(tester);
      bool enabled() =>
          tester.widget<ButtonStyleButton>(archive).onPressed != null;
      final saysResuming = find.ancestor(
        of: archive,
        matching: find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Resuming…',
        ),
      );
      expect(enabled(), isTrue);

      c.read(sessionsStartingProvider.notifier).add('ks-r30');
      await settleMission(tester);
      expect(enabled(), isFalse);
      expect(saysResuming, findsOneWidget);

      c.read(sessionsStartingProvider.notifier).remove('ks-r30');
      await settleMission(tester);
      expect(enabled(), isTrue);
      expect(saysResuming, findsNothing);
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
    expect(find.byKey(const ValueKey('overview-none-at-work')), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('Hide while working leaves "N hidden · Show" on Working', (
    tester,
  ) async {
    final c = await pump(tester, fixture: MissionFixture(hiddenWorking: 3));
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
    expect(find.byKey(const ValueKey('overview-none-at-work')), findsOneWidget);
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
      contextOfProject: const {'p-ks': 'c-apps', 'p-beej': 'c-web'},
    );

    Finder group(String key) =>
        find.byKey(ValueKey('overview-work-group:$key'));

    testWidgets('a header per context in order, "No context" last', (
      tester,
    ) async {
      final c = await pump(tester, fixture: filed());
      c
          .read(overviewPrefsProvider.notifier)
          .setGroupBy(OverviewGroupBy.context);
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
      c
          .read(overviewPrefsProvider.notifier)
          .setGroupBy(OverviewGroupBy.context);
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
