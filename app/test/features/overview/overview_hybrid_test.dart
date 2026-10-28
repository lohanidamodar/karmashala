import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
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
import 'package:karmashala/src/features/overview/application/overview_seen.dart';
import 'package:karmashala/src/features/overview/application/overview_tree.dart';
import 'package:karmashala/src/features/overview/presentation/overview_hybrid.dart';
import 'package:karmashala/src/features/overview/presentation/overview_done_card.dart';
import 'package:karmashala/src/features/overview/presentation/overview_strip.dart';
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
import 'package:karmashala_ui/tokens.dart';

import 'package:karmashala_verification/verification.dart';

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
    bool waiting = false,
  }) => pumpMission(
    tester,
    fixture: fixture ?? MissionFixture.full(),
    prefsDir: dir,
    size: size,
    phone: phone,
    textScale: textScale,
    waiting: waiting,
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
  Finder pill(String id) => find.byKey(ValueKey('overview-tree-pill:$id'));

  /// Pins [id], so its short card with what it is doing is drawn on top.
  Future<void> pin(WidgetTester tester, ProviderContainer c, String id) async {
    c.read(overviewPrefsProvider.notifier).togglePin(id);
    await settleMission(tester);
  }

  /// Opens [id]'s family ⋯ menu.
  Future<void> openMenu(WidgetTester tester, String id) async {
    final menu = find.byKey(ValueKey('overview-card-menu:$id'));
    await tester.scrollUntilVisible(menu, 300, scrollable: hybridList);
    await tester.ensureVisible(menu);
    await settleMission(tester);
    await tester.tap(menu);
    await settleMission(tester);
  }

  for (final (name, size, phone) in [
    ('1440×900', const Size(1440, 900), false),
    ('1024×768', const Size(1024, 768), false),
    ('390×844', const Size(390, 844), true),
    ('360×800', const Size(360, 800), true),
  ]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('$name at ${scale}x text: the strip, the lanes, and the '
          'waiting drawer over them', (tester) async {
        await pump(tester, size: size, phone: phone, textScale: scale);

        expect(find.byKey(const ValueKey('overview-strip')), findsOneWidget);
        expect(find.byKey(const ValueKey('overview-heartbeat')), findsNothing);
        // What waits is in the drawer, closed until asked for.
        expect(queueCard('ks-r21'), findsNothing);
        final work = find.byKey(const ValueKey('overview-work'));
        final workAt = tester.getTopLeft(work);
        await openWaiting(tester);
        expect(queueCard('ks-r21'), findsOneWidget);
        expect(find.byType(ApprovalRequestCard), findsWidgets);
        // The drawer lies over the board: nothing under it moved.
        expect(tester.getTopLeft(work), workAt);
        final drawer = find.byKey(const ValueKey('overview-waiting-drawer'));
        if (phone) {
          // A bottom sheet on a phone.
          expect(tester.getTopLeft(drawer).dx, 0);
        } else {
          // Docked on the right on a desktop.
          expect(tester.getTopLeft(drawer).dx, greaterThan(workAt.dx));
        }
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('overview-drawer-close')));
        await settleMission(tester);
        expect(queueCard('ks-r21'), findsNothing);
        // More unfolds the heartbeat under the strip.
        await tester.tap(find.byKey(const ValueKey('overview-more-toggle')));
        await settleMission(tester);
        expect(
          find.byKey(const ValueKey('overview-heartbeat')),
          findsOneWidget,
        );
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
    final c = await pump(
      tester,
      fixture: MissionFixture(activity: MissionFixture.realisticActivity()),
    );
    // What a session is doing in words is on its short, pinned card.
    await pin(tester, c, 'ks-r32');

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

  testWidgets('a running call\'s own words lead', (tester) async {
    final c = await pump(tester);
    await pin(tester, c, 'ks-r32');

    final line = find.byKey(const ValueKey('overview-activity:ks-r32'));
    await tester.scrollUntilVisible(line, 200, scrollable: hybridList);
    expect(tester.widget<Text>(line).data, 'Run the overview tests · 4m');
    await unmountMission(tester);
  });

  group('calm cards', () {
    testWidgets('a family card is one calm surface, with no message box and '
        'no state-coloured edge', (tester) async {
      await pump(tester);
      final card = familyCard('ks-r32');
      await tester.scrollUntilVisible(card, 200, scrollable: hybridList);

      // Answering lives in the drawer and the peek: no composer on the card.
      expect(
        find.byKey(const ValueKey('overview-composer:ks-r32')),
        findsNothing,
      );
      final scheme = Theme.of(tester.element(card)).colorScheme;
      BoxDecoration frameOf(String id) =>
          tester.widget<Container>(familyCard(id)).decoration! as BoxDecoration;
      final frame = frameOf('ks-r32');
      expect(frame.color, scheme.surfaceContainerLowest);
      expect((frame.border! as Border).top.color, scheme.outlineVariant);
      // An ask's family is the same surface with the same edge.
      final ask = frameOf('ks-r21');
      expect(ask.color, scheme.surfaceContainerLowest);
      expect((ask.border! as Border).top.color, scheme.outlineVariant);
      await unmountMission(tester);
    });

    testWidgets('it shows the latest message and how far its family is', (
      tester,
    ) async {
      await pump(tester);
      final card = familyCard('ks-r30');
      await tester.scrollUntilVisible(card, 200, scrollable: hybridList);

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('overview-last:ks-r30')))
            .data,
        startsWith('Webhooks are wired: 3 events reach the inbox'),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-family-meta:ks-r32')),
            )
            .data,
        startsWith('3/5 finished'),
      );
      await unmountMission(tester);
    });

    testWidgets('a check over code that changed since is stale on the card', (
      tester,
    ) async {
      const head = 'dddddddddddddddddddddddddddddddddddddddd';
      await pump(
        tester,
        fixture: MissionFixture.full(
          verificationRuns: [
            VerificationRun(
              id: 'vr-r30',
              title: 'Project checks',
              target: const VerificationTarget.change(),
              startedAt: MissionFixture.now,
              finishedAt: MissionFixture.now,
              verdict: VerificationVerdict.pass,
              artifactDirectory: '/art/vr-r30',
              sessionId: 'ks-r30',
              producedBySessionId: 'karmashala',
              identity: const CodeIdentity(
                environmentId: 'windows',
                path: '/src/ks-r30',
                head: head,
                tree: '',
                dirty: {},
              ),
            ),
          ],
          codeFreshness: {
            head: const CodeFreshness.stale(
              'Uncommitted files changed since this ran.',
              filesChanged: 2,
            ),
          },
        ),
      );
      final card = familyCard('ks-r30');
      await tester.scrollUntilVisible(card, 200, scrollable: hybridList);

      final mark = find.byKey(const ValueKey('overview-verdict:ks-r30'));
      expect(mark, findsOneWidget);
      expect(
        find.descendant(
          of: mark,
          matching: find.text('Checked: pass · stale (2 files changed since)'),
        ),
        findsOneWidget,
      );
      // A card nothing checked draws no verdict at all.
      expect(
        find.byKey(const ValueKey('overview-verdict:ks-r32')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('wide, the meta row carries the plan step, diff and check '
        'on one line; narrow, it does not', (tester) async {
      await pump(tester);
      final card = familyCard('ks-r32');
      await tester.scrollUntilVisible(card, 200, scrollable: hybridList);
      final meta = find.byKey(const ValueKey('overview-family-meta:ks-r32'));
      final line = find.byKey(const ValueKey('overview-meta:ks-r32'));
      expect(line, findsOneWidget);
      // On the same row as "3/5 finished", never a second line.
      expect(
        tester.getCenter(line).dy,
        moreOrLessEquals(tester.getCenter(meta).dy, epsilon: 1),
      );
      await unmountMission(tester);

      await pump(tester, size: const Size(390, 844), phone: true);
      expect(find.byKey(const ValueKey('overview-meta:ks-r32')), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('a family is one card: the parent\'s header, then each '
        'sub-session on a branch with its latest line and state, opening in '
        'the peek', (tester) async {
      final fixture = MissionFixture.full();
      fixture.reader.answers['ks-r32-sub0'] = const LastAnswer.of(
        'Ran the layout tests: all green.',
      );
      await pump(tester, fixture: fixture);
      final family = familyCard('ks-r32');
      await tester.scrollUntilVisible(family, 200, scrollable: hybridList);

      expect(
        find.descendant(
          of: family,
          matching: find.byKey(const ValueKey('overview-family-head:ks-r32')),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-family-meta:ks-r32')),
            )
            .data,
        startsWith('3/5 finished'),
      );
      for (var i = 0; i < 5; i++) {
        expect(
          find.descendant(of: family, matching: pill('ks-r32-sub$i')),
          findsOneWidget,
          reason: 'sub$i',
        );
      }
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-last:ks-r32-sub0')),
            )
            .data,
        'Ran the layout tests: all green.',
      );

      // A pill opens the peek, never a detail in place.
      await tester.ensureVisible(pill('ks-r32-sub0'));
      await tester.tap(pill('ks-r32-sub0'));
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-tree-detail:ks-r32-sub0')),
        findsNothing,
      );
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

    testWidgets('an agent-started child shows at once on its parent\'s tree, '
        '"Starting…", its parent waiting on it', (tester) async {
      await pump(tester, fixture: agentStartedChild());
      final pill = find.byKey(
        const ValueKey('overview-tree-pill:ks-r30-child'),
      );
      await tester.scrollUntilVisible(pill, 200, scrollable: hybridList);

      expect(
        find.descendant(of: pill, matching: find.textContaining('Starting…')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-family:ks-r30')),
          matching: pill,
        ),
        findsOneWidget,
      );
      // The parent is held at work by it: its state says Waiting, and its
      // footer is the same as any: Stop, disabled, for its own turn is over,
      // and Message.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-family-state:ks-r30')),
          matching: find.text('Waiting'),
        ),
        findsOneWidget,
      );
      final stop = find.byKey(const ValueKey('overview-interrupt:ks-r30'));
      expect(tester.widget<OutlinedButton>(stop).onPressed, isNull);
      expect(
        find.byKey(const ValueKey('overview-family-message:ks-r30')),
        findsOneWidget,
      );
      expect(familyCard('ks-r30-child'), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('past four sub-sessions, the rest fold into one row that '
        'shows them', (tester) async {
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
      final more = find.byKey(const ValueKey('overview-tree-more:ks-r32'));
      await tester.scrollUntilVisible(more, 200, scrollable: hybridList);
      final pills = find.descendant(
        of: familyCard('ks-r32'),
        matching: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'overview-tree-pill:',
              ),
        ),
      );
      // Four rows, in spawn order; the rest are one row.
      expect(pills, findsNWidgets(4));
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-tree-more-line:ks-r32')),
            )
            .data,
        startsWith('2 more'),
      );
      await tester.ensureVisible(more);
      await settleMission(tester);
      await tester.tap(more);
      await settleMission(tester);
      expect(pills, findsNWidgets(6));
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-tree-more-line:ks-r32')),
            )
            .data,
        'Show fewer',
      );
      await unmountMission(tester);
    });

    testWidgets('a child that needs you is amber on its tree, counted on the '
        'root, and Review opens the drawer on its family', (tester) async {
      await pump(
        tester,
        fixture: withSubs(
          (s) => s.id == 'ks-r32-sub2' ? asState(s, AgentState.needsYou) : s,
        ),
      );
      final pill = find.byKey(const ValueKey('overview-tree-pill:ks-r32-sub2'));
      await tester.scrollUntilVisible(pill, 200, scrollable: hybridList);
      expect(
        find.byKey(const ValueKey('session-avatar-badge:ks-r32-sub2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-avatar-badge:ks-r32-sub0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('session-avatar-badge:ks-r32')),
        findsOneWidget,
      );
      // Answered in the drawer, narrowed to this family.
      expect(queueCard('ks-r32-sub2'), findsNothing);
      final review = find.byKey(
        const ValueKey('overview-family-review:ks-r32'),
      );
      await tester.ensureVisible(review);
      await settleMission(tester);
      expect(
        find.descendant(of: review, matching: find.text('1 ask')),
        findsOneWidget,
      );
      await tester.tap(review);
      await settleMission(tester);
      expect(queueCard('ks-r32-sub2'), findsOneWidget);
      expect(queueCard('ks-r21'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('overview-drawer-all')));
      await settleMission(tester);
      expect(queueCard('ks-r21'), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('the filter panel offers no sub-session layout: there is one', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('overview-filter-button')));
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-filter-group')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('overview-filter-subs')), findsNothing);
      expect(find.text('Sub-sessions'), findsNothing);
      await unmountMission(tester);
    });

    for (final size in const [Size(360, 800), Size(1440, 900)]) {
      testWidgets('the tree at ${size.width.toInt()} px and text scale 1.6 '
          'fits', (tester) async {
        await pump(tester, size: size, phone: size.width < 600, textScale: 1.6);
        final last = find.byKey(
          const ValueKey('overview-tree-pill:ks-r32-sub4'),
        );
        await tester.scrollUntilVisible(last, 200, scrollable: hybridList);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(last);
        await tester.tap(last);
        await settleMission(tester);
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
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

  test('within a group families sit by start time; the queue puts the '
      'most urgent first', () {
    final fixture = MissionFixture();
    final board = buildOverviewBoard(
      fixture.groups,
      facts: fixture.facts,
      filter: const OverviewFilter(),
      groupBy: OverviewGroupBy.project,
      startOfToday: MissionFixture.now.subtract(const Duration(hours: 6)),
      memo: BoardOrderMemo(),
    );
    final forest = overviewForestOf(board);
    final starts = [
      for (final tree in forest.lanes.first.$2) tree.card.entry.createdAt,
    ];
    expect(starts, [...starts]..sort());
    final queue = overviewSectionsOf(
      board,
      forest,
      waitingSince: (_) => null,
    ).queue;
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
        inPeek(find.byKey(const ValueKey('overview-composer:ks-r32'))),
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

    // Docked at both: the peek takes its own room and the board reflows
    // beside it, never covered (owner, 2026-10-13; the overlay is gone).
    for (final (name, size) in [
      ('1440', const Size(1440, 900)),
      ('1100', const Size(1100, 800)),
    ]) {
      testWidgets('$name px: the peek is docked beside the board', (
        tester,
      ) async {
        await pump(tester, size: size);
        await peek(tester, 'Round 21 · ACP sessions');
        expect(
          find.byKey(const ValueKey('overview-peek-overlay')),
          findsNothing,
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('overview-work'))).right,
          lessThanOrEqualTo(
            tester.getRect(find.byKey(const ValueKey('overview-peek'))).left,
          ),
        );
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
          find.descendant(of: badge, matching: find.text('3 new')),
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
          final row = familyCard('ks-r32');
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
      testWidgets('$name px: the same trees, their avatars a step smaller', (
        tester,
      ) async {
        await pump(tester, size: size, phone: true);
        final root = familyCard('ks-r32');
        await tester.scrollUntilVisible(root, 300, scrollable: hybridList);
        expect(root, findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('session-avatar:ks-r32'))),
          const Size.square(Chrome.sessionAvatarCompact),
        );
        final pill = find.byKey(const ValueKey('session-avatar:ks-r32-sub0'));
        await tester.scrollUntilVisible(pill, 300, scrollable: hybridList);
        expect(
          tester.getSize(pill),
          const Size.square(Chrome.subSessionAvatarCompact),
        );
        final ready = familyCard('ks-r30');
        await tester.scrollUntilVisible(ready, 300, scrollable: hybridList);
        expect(ready, findsOneWidget);

        final title = find.byKey(const ValueKey('overview-card-title:ks-r30'));
        await tester.ensureVisible(title);
        await settleMission(tester);
        await tester.tap(title);
        await settleMission(tester);
        final peek = find.byKey(const ValueKey('overview-peek'));
        expect(peek, findsOneWidget);
        expect(tester.getSize(peek).height, greaterThan(size.height * 0.8));
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }

    testWidgets('Waiting opens a bottom sheet over the families', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 844), phone: true);
      final root = familyCard('ks-r21');
      final rootAt = tester.getTopLeft(root);
      await openWaiting(tester);
      final sheet = tester.getRect(
        find.byKey(const ValueKey('overview-waiting-drawer')),
      );
      expect(sheet.left, 0);
      expect(sheet.right, 390);
      expect(sheet.top, greaterThan(0));
      expect(sheet.bottom, lessThanOrEqualTo(844));
      expect(queueCard('ks-r21'), findsOneWidget);
      // The families stay where they were under it.
      expect(tester.getTopLeft(root), rootAt);
      expect(tester.takeException(), isNull);
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

  group('ready and ended families', () {
    const merge = OfferedAction(
      DeliveryAction.merge,
      isPrimary: true,
      promptOverride: 'Merge the pull request with a squash.',
    );

    testWidgets('a ready family keeps its place in its lane, and Message sends '
        'from its footer through the one send path', (tester) async {
      await pump(tester);
      final card = familyCard('ks-r30');
      await tester.scrollUntilVisible(card, 300, scrollable: hybridList);
      final reply = find.byKey(
        const ValueKey('overview-family-message:ks-r30'),
      );
      expect(find.descendant(of: card, matching: reply), findsOneWidget);
      await tester.ensureVisible(reply);
      await settleMission(tester);
      await tester.tap(reply);
      await settleMission(tester);
      // The box opens in the card, not the peek.
      expect(find.byKey(const ValueKey('overview-peek:ks-r30')), findsNothing);
      final field = find.byKey(const ValueKey('overview-composer:ks-r30'));
      expect(find.descendant(of: card, matching: field), findsOneWidget);
      await tester.enterText(field, 'Run the webhook tests again');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleMission(tester);
      expect(sent, [('ks-r30', 'Run the webhook tests again')]);
      await unmountMission(tester);
    });

    testWidgets('Merge in the ⋯ sends the delivery strip\'s own merge', (
      tester,
    ) async {
      final fixture = MissionFixture(
        answers: MissionFixture.realisticAnswers(),
        activity: MissionFixture.realisticActivity(),
        merges: const {'ks-r30': (merge, 'origin/feat/acp')},
      );
      await pump(tester, fixture: fixture);
      await openMenu(tester, 'ks-r30');
      final item = find.byKey(const ValueKey('overview-card-menu:merge'));
      expect(tester.widget<PopupMenuItem<String>>(item).enabled, isTrue);
      await tester.tap(item);
      await settleMission(tester);
      expect(sent, [('ks-r30', 'Merge the pull request with a squash.')]);

      // No pull request: nothing to merge yet, so Merge cannot be picked.
      await openMenu(tester, 'beej-ci');
      expect(tester.widget<PopupMenuItem<String>>(item).enabled, isFalse);
      await unmountMission(tester);
    });

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
      // Its parent ended, and still heads it: it is a pill on the parent's
      // tree, handing back from its menu.
      final child = pill('ks-r29-child');
      await tester.scrollUntilVisible(child, 300, scrollable: hybridList);
      await tester.ensureVisible(child);
      await settleMission(tester);
      await tester.tap(child, buttons: kSecondaryButton);
      await settleMission(tester);
      final item = find.byKey(const ValueKey('overview-card-menu:hand-back'));
      expect(item, findsOneWidget);
      await tester.tap(item);
      await settleMission(tester);
      expect(sent, [
        (
          'ks-r29',
          handBackMessage('Fork benchmarks', 'Forks are 3× faster on SSH.'),
        ),
      ]);
      // A top-level session has no parent to hand back to.
      await openMenu(tester, 'ks-r30');
      expect(item, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleMission(tester);
      // The ended family archives whole.
      expect(
        find.byKey(const ValueKey('overview-archive-family:ks-r29')),
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
      final card = familyCard('ks-r30');
      await tester.scrollUntilVisible(card, 200, scrollable: hybridList);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-family-state:ks-r30')),
          matching: find.text('Waiting'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-family-meta:ks-r30')),
            )
            .data,
        startsWith('0/1 finished'),
      );
      // Its own turn is over: nothing for Stop to interrupt.
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('overview-interrupt:ks-r30')),
            )
            .onPressed,
        isNull,
      );
      await unmountMission(tester);
    });

    testWidgets("an ended parent's sub-sessions sit under it on its tree, a "
        'step in', (tester) async {
      await pump(
        tester,
        fixture: MissionFixture(
          sessions: [
            ...MissionFixture.realisticSessions(),
            child('ks-r29-a', 'ks-r29', AgentState.ended),
            child('ks-r29-b', 'ks-r29', AgentState.ended),
          ],
        ),
      );
      final parent = find.byKey(const ValueKey('session-avatar:ks-r29'));
      final kid = pill('ks-r29-a');
      await tester.scrollUntilVisible(kid, 200, scrollable: hybridList);
      expect(
        find.descendant(of: familyCard('ks-r29'), matching: kid),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(kid).dx,
        greaterThan(tester.getTopLeft(parent).dx),
      );
      expect(
        tester.getTopLeft(kid).dy,
        greaterThan(tester.getTopLeft(parent).dy),
      );
      expect(
        find.byKey(const ValueKey('overview-archive-family:ks-r29')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    testWidgets("an ended card's Archive waits while it is resumed, and says "
        'why', (tester) async {
      final c = await pump(tester);
      final archive = find.byKey(
        const ValueKey('overview-done-archive:ks-r29'),
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

      c.read(sessionsStartingProvider.notifier).add('ks-r29');
      await settleMission(tester);
      expect(enabled(), isFalse);
      expect(saysResuming, findsOneWidget);

      c.read(sessionsStartingProvider.notifier).remove('ks-r29');
      await settleMission(tester);
      expect(enabled(), isTrue);
      expect(saysResuming, findsNothing);
      await unmountMission(tester);
    });
  });

  testWidgets('what ended today keeps its place in its lane', (tester) async {
    await pump(tester);
    final card = familyCard('ks-r29');
    await tester.scrollUntilVisible(card, 300, scrollable: hybridList);
    expect(card, findsOneWidget);
    expect(
      find.byKey(const ValueKey('overview-done-archive:ks-r29')),
      findsOneWidget,
    );
    await unmountMission(tester);
  });

  testWidgets('a part of Today filters the families and the drawer', (
    tester,
  ) async {
    final c = await pump(tester, waiting: true);
    await tester.tap(find.byKey(const ValueKey('overview-today:needsYou')));
    await settleMission(tester);
    expect(c.read(overviewPrefsProvider).filter.columns, {
      BoardColumn.needsYou,
    });
    expect(queueCard('ks-r21'), findsOneWidget);
    expect(familyCard('ks-r21'), findsOneWidget);
    expect(familyCard('ks-r32'), findsNothing);
    await unmountMission(tester);
  });

  testWidgets('Hide while working leaves "N hidden · Show" on Working', (
    tester,
  ) async {
    final c = await pump(tester, fixture: MissionFixture(hiddenWorking: 3));
    c.read(sessionListPrefsProvider.notifier).setHideWorking(true);
    await settleMission(tester);

    expect(find.text('3 hidden · Show'), findsOneWidget);
    // The counts slide sideways in the strip: bring it into view first.
    final hidden = find.byKey(const ValueKey('overview-working-hidden'));
    await tester.ensureVisible(hidden);
    await settleMission(tester);
    await tester.tap(hidden);
    await settleMission(tester);
    expect(c.read(sessionListPrefsProvider).hideWorking, isFalse);
    await unmountMission(tester);
  });

  testWidgets('nothing live: the ended families stay, nothing waits', (
    tester,
  ) async {
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
    // A phone's Waiting is in the bottom bar, with no count while none waits.
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('overview-bar-waiting')))
          .label,
      'Waiting',
    );
    expect(find.byKey(const ValueKey('overview-none-at-work')), findsNothing);
    expect(find.textContaining('Archive done · '), findsWidgets);
    await openWaiting(tester);
    expect(find.byKey(const ValueKey('overview-drawer-empty')), findsOneWidget);
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
      waiting: true,
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
    testWidgets('Stuck counts the failures, and shows them without the asks', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final c = await pump(tester, waiting: true);
      expect(find.bySemanticsLabel(RegExp(r'^1 needs you, ')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^\d+ stuck, .*1 failed')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('overview-today:stuck')));
      await settleMission(tester);
      expect(c.read(overviewPrefsProvider).filter.states, {
        AgentState.failed,
        AgentState.quiet,
      });
      expect(queueCard('store-reviews'), findsOneWidget);
      expect(queueCard('ks-r21'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp(r'^\d+ stuck, .*showing only these')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('overview-today:needsYou')));
      await settleMission(tester);
      expect(queueCard('ks-r21'), findsOneWidget);
      expect(queueCard('store-reviews'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('overview-today:needsYou')));
      await settleMission(tester);
      expect(c.read(overviewPrefsProvider).filter.allStates, isTrue);
      expect(queueCard('store-reviews'), findsOneWidget);
      handle.dispose();
      await unmountMission(tester);
    });

    testWidgets('under More, one slim row with the sparkline; Today stays '
        'in the strip above it', (tester) async {
      await pump(tester);
      final heart = find.byKey(const ValueKey('overview-heartbeat'));
      final chart = find.byKey(const ValueKey('overview-heartbeat-chart'));
      expect(heart, findsNothing);
      await tester.tap(find.byKey(const ValueKey('overview-more-toggle')));
      await settleMission(tester);
      expect(chart, findsOneWidget);
      expect(find.byKey(const ValueKey('overview-chart-toggle')), findsNothing);
      expect(tester.getSize(heart).height, lessThan(64));
      final today = find.byKey(const ValueKey('overview-today'));
      expect(today, findsOneWidget);
      expect(
        tester.getTopLeft(today).dy,
        lessThan(tester.getTopLeft(heart).dy),
      );
      await unmountMission(tester);
    });

    testWidgets('on a phone the sparkline folds behind a toggle', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 844), phone: true);
      await tester.tap(find.byKey(const ValueKey('overview-more-toggle')));
      await settleMission(tester);
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

    Finder group(String key) => find.byWidgetPredicate(
      (w) => w is OverviewLaneHeader && w.lane.key == key,
    );

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
