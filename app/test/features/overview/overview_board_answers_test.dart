import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/presentation/overview_queue_card.dart';
import 'package:karmashala/src/features/remote/application/remote_approval_bindings.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/presentation/approval_request_card.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_remote/remote.dart';

import 'mission_fixture.dart';

/// Records what the board sends, and sends nothing.
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

class _Recorder implements PromptAnswering {
  _Recorder({this.menu});

  final AgentScreenMenu? menu;
  final asked = <PromptAnswerRequest>[];

  @override
  Future<SessionApprovalAnswer> answer(PromptAnswerRequest request) async {
    asked.add(request);
    return const SessionApprovalAnswer(answered: 'ok', effect: 'ok');
  }

  @override
  Future<PromptEvidence> evidence(String sessionId) =>
      throw UnimplementedError();

  @override
  AgentScreenMenu? menuOnScreen(String sessionId) => menu;
}

/// **Waiting on you, answered on the board**: a question by its numbered
/// options, a command by Allow / Always / Deny / Edit…, a terminal-only
/// prompt by the terminal or the chat, a failed turn by retrying it.
void main() {
  late Directory dir;
  final sent = <(String, String)>[];
  final questions = <RemoteQuestionAnswerRequest>[];

  setUp(() async {
    sent.clear();
    questions.clear();
    dir = await Directory.systemTemp.createTemp('ks-board-answers');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  final now = MissionFixture.now;
  MissionSession session(
    String id,
    String title,
    AgentState state, {
    AgentStatusReport? report,
    String? parent,
  }) => (
    id: id,
    title: title,
    project: 'p-beej',
    machine: 'windows',
    agent: AgentIds.claudeCode,
    state: state,
    age: const Duration(minutes: 3),
    parent: parent,
    report: report,
  );
  AgentStatusReport waiting(String id, AgentWaitKind kind) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: 'cli-$id',
    status: AgentActivityStatus.awaitingApproval,
    observedAt: now,
    source: AgentStatusSource.hook,
    waiting: kind,
    waitingSince: now.subtract(const Duration(minutes: 3)),
  );
  const question = RemoteQuestion(
    toolUseId: 'toolu_q',
    questions: [
      RemoteQuestionItem(
        question: 'Which branch should I merge round 21 into?',
        header: 'Merge target',
        multiSelect: false,
        options: [
          RemoteQuestionOption(
            label: 'feat/acp',
            description: 'The integration branch every round merges into.',
          ),
          RemoteQuestionOption(
            label: 'main',
            description: 'Straight to release. Skips the integration gates.',
          ),
        ],
      ),
    ],
  );
  const alwaysMenu = AgentScreenMenu(
    prompt: ['Bash command', 'flutter test --exclude-tags=live-ssh,live-wsl'],
    options: [
      'Yes',
      "Yes, and don't ask again for flutter test commands in /src/ks-r21",
      'No, and tell Claude what to do differently (esc)',
    ],
    highlighted: 0,
  );

  Future<(ProviderContainer, _Recorder)> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    bool phone = false,
  }) async {
    final recorder = _Recorder(menu: alwaysMenu);
    final container = await pumpMission(
      tester,
      fixture: MissionFixture(
        sessions: [
          for (final s in MissionFixture.realisticSessions())
            if (s.id == 'ks-r21' || s.id == 'store-reviews' || s.id == 'ks-r32')
              s,
          session(
            'ask-q',
            'Pick the merge target',
            AgentState.needsYou,
            report: waiting('ask-q', AgentWaitKind.question),
            parent: 'ks-r32',
          ),
          session(
            'term',
            'Scaffold templates v3',
            AgentState.needsYou,
            report: waiting('term', AgentWaitKind.input),
          ),
        ],
        panes: const {'term': 'pane-term'},
      ),
      prefsDir: dir,
      size: size,
      phone: phone,
      overrides: [
        sessionActionsProvider.overrideWith((ref) => _SpyActions(ref, sent)),
        sessionAnswerableProvider.overrideWithValue((_) => true),
        sessionPromptAnswersProvider.overrideWithValue(recorder),
        chatOpenQuestionProvider.overrideWith(
          (ref, id) async => id == 'ask-q' ? question : null,
        ),
        chatQuestionAnswerProvider.overrideWithValue((request) async {
          questions.add(request);
          return 'ok';
        }),
      ],
    );
    return (container, recorder);
  }

  Finder queueCard(String id) =>
      find.byKey(ValueKey('overview-queue-card:$id'));
  Finder inCard(String id, Finder f) =>
      find.descendant(of: queueCard(id), matching: f);

  testWidgets('a question: numbered options, Send, Decline, Reply in words', (
    tester,
  ) async {
    await pump(tester);
    final card = queueCard('ask-q');
    await tester.ensureVisible(card);

    expect(inCard('ask-q', find.text('1')), findsOneWidget);
    expect(inCard('ask-q', find.text('2')), findsOneWidget);
    // A sub-session says where it is from.
    expect(
      inCard('ask-q', find.text('↳ from Round 32 · Overview redesign')),
      findsOneWidget,
    );
    final desc = tester.widget<Text>(
      find.byKey(const ValueKey('question-option-desc-0-1')),
    );
    expect(desc.maxLines, 1);
    expect(inCard('ask-q', find.text('Decline')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('question-option-0-1')));
    await settleMission(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('question-option-desc-0-1')))
          .maxLines,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('question-send')));
    await settleMission(tester);
    expect(questions.single.toolUseId, 'toolu_q');
    expect(questions.single.answers.single.options, [1]);

    await tester.tap(find.byKey(const ValueKey('question-reply-in-words')));
    await settleMission(tester);
    expect(
      find.byKey(const ValueKey('overview-composer:ask-q')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  });

  group('reply in words', () {
    Future<Finder> composer(WidgetTester tester) async {
      await pump(tester);
      await tester.ensureVisible(queueCard('ask-q'));
      await settleMission(tester);
      await tester.tap(find.byKey(const ValueKey('question-reply-in-words')));
      await settleMission(tester);
      final field = find.byKey(const ValueKey('overview-composer:ask-q'));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await settleMission(tester);
      return field;
    }

    testWidgets('Enter sends through the one send path', (tester) async {
      final field = await composer(tester);
      await tester.enterText(field, 'Merge it into feat/acp');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleMission(tester);

      expect(sent, [('ask-q', 'Merge it into feat/acp')]);
      expect(find.text('Sent'), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await unmountMission(tester);
    });

    testWidgets('Shift+Enter makes a new line, Esc clears, nothing is sent', (
      tester,
    ) async {
      final field = await composer(tester);
      await tester.enterText(field, 'one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settleMission(tester);
      expect(sent, isEmpty);
      expect(
        tester.widget<TextField>(field).controller!.text,
        startsWith('one'),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleMission(tester);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(sent, isEmpty);
      await unmountMission(tester);
    });
  });

  testWidgets('a command: two lines of it, where, and Allow / Always / Deny', (
    tester,
  ) async {
    final (_, recorder) = await pump(tester);

    final command = tester.widget<Text>(
      find.byKey(const ValueKey('board-command:ks-r21')),
    );
    expect(command.data, 'flutter test --exclude-tags=live-ssh,live-wsl');
    expect(command.maxLines, 2);
    expect(find.byKey(const ValueKey('board-where:ks-r21')), findsOneWidget);
    for (final k in ['edit', 'deny', 'always', 'allow']) {
      expect(find.byKey(ValueKey('board-$k:ks-r21')), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('board-allow:ks-r21')));
    await settleMission(tester);
    final allow = recorder.asked.single as ApprovalAnswerRequest;
    expect(allow.sessionId, 'ks-r21');
    expect(allow.approve, isTrue);

    await tester.tap(find.byKey(const ValueKey('board-always:ks-r21')));
    await settleMission(tester);
    final always = recorder.asked.last as MenuAnswerRequest;
    expect(always.option, 1);

    await tester.tap(find.byKey(const ValueKey('board-deny:ks-r21')));
    await settleMission(tester);
    expect((recorder.asked.last as ApprovalAnswerRequest).approve, isFalse);
    await unmountMission(tester);
  });

  testWidgets('Edit… opens the peek with the command to change, then runs it', (
    tester,
  ) async {
    final (_, recorder) = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('board-edit:ks-r21')));
    await settleMission(tester);

    final field = find.byKey(const ValueKey('board-edit-field'));
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(field).controller!.text,
      'flutter test --exclude-tags=live-ssh,live-wsl',
    );
    await tester.enterText(field, 'flutter test test/features/overview');
    await tester.tap(find.byKey(const ValueKey('board-run-edited')));
    await settleMission(tester);

    expect((recorder.asked.single as ApprovalAnswerRequest).approve, isFalse);
    expect(sent, [
      ('ks-r21', editedCommandMessage('flutter test test/features/overview')),
    ]);
    expect(field, findsNothing);
    await unmountMission(tester);
  });

  testWidgets('a terminal-only prompt: Answer in terminal, Continue in chat', (
    tester,
  ) async {
    await pump(tester);
    final card = queueCard('term');
    await tester.ensureVisible(card);
    expect(
      inCard('term', find.textContaining('only its terminal shows')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('overview-answer-terminal:term')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('overview-continue-chat:term')),
      findsOneWidget,
    );
    expect(overviewAskKind, isNotNull);
    await unmountMission(tester);
  });

  testWidgets('a failed turn: Retry the turn sends, Read the log peeks', (
    tester,
  ) async {
    await pump(tester);
    final retry = find.byKey(const ValueKey('overview-retry:store-reviews'));
    await tester.ensureVisible(retry);
    await settleMission(tester);
    await tester.tap(retry);
    await settleMission(tester);
    expect(sent, [('store-reviews', kOverviewRetryWords)]);

    await tester.tap(
      find.byKey(const ValueKey('overview-read-log:store-reviews')),
    );
    await settleMission(tester);
    expect(
      find.byKey(const ValueKey('overview-peek:store-reviews')),
      findsOneWidget,
    );
    await unmountMission(tester);
  });

  testWidgets('the title row opens the peek; the rest of the card does not', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('board-where:ks-r21')));
    await settleMission(tester);
    expect(find.byKey(const ValueKey('overview-peek:ks-r21')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('overview-queue-title:ks-r21')));
    await settleMission(tester);
    expect(find.byKey(const ValueKey('overview-peek:ks-r21')), findsOneWidget);
    await unmountMission(tester);
  });

  group('keyboard triage', () {
    String? selected(ProviderContainer c) =>
        c.read(overviewFocusProvider).selected;
    String? peeked(ProviderContainer c) => c.read(overviewFocusProvider).peeked;
    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await settleMission(tester);
    }

    testWidgets('N walks what waits on you, asks before failures', (
      tester,
    ) async {
      final (c, _) = await pump(tester);
      await press(tester, LogicalKeyboardKey.keyN);
      expect(selected(c), 'ks-r21');
      await press(tester, LogicalKeyboardKey.keyN);
      expect(selected(c), isIn(['ask-q', 'term']));
      await press(tester, LogicalKeyboardKey.keyN);
      await press(tester, LogicalKeyboardKey.keyN);
      expect(selected(c), 'store-reviews');
      await press(tester, LogicalKeyboardKey.keyN);
      expect(selected(c), 'ks-r21');
      expect(peeked(c), isNull);
      await unmountMission(tester);
    });

    testWidgets('Y allows the selected command, and the next is selected', (
      tester,
    ) async {
      final (c, recorder) = await pump(tester);
      await press(tester, LogicalKeyboardKey.keyN);
      expect(selected(c), 'ks-r21');
      await press(tester, LogicalKeyboardKey.keyY);
      final allow = recorder.asked.single as ApprovalAnswerRequest;
      expect((allow.sessionId, allow.approve), ('ks-r21', true));
      expect(selected(c), isNot('ks-r21'));
      expect(selected(c), isNotNull);

      // A on a question offers nothing: the key does nothing.
      await press(tester, LogicalKeyboardKey.keyA);
      expect(recorder.asked, hasLength(1));
      await unmountMission(tester);
    });

    testWidgets('A always allows; D denies', (tester) async {
      final (c, recorder) = await pump(tester);
      await press(tester, LogicalKeyboardKey.keyN);
      await press(tester, LogicalKeyboardKey.keyA);
      expect((recorder.asked.single as MenuAnswerRequest).option, 1);
      c.read(overviewFocusProvider.notifier).select('ks-r21');
      await settleMission(tester);
      await press(tester, LogicalKeyboardKey.keyD);
      expect((recorder.asked.last as ApprovalAnswerRequest).approve, isFalse);
      await unmountMission(tester);
    });

    testWidgets('1–9 picks an option, Enter sends it and moves on', (
      tester,
    ) async {
      final (c, _) = await pump(tester);
      c.read(overviewFocusProvider.notifier).select('ask-q');
      await settleMission(tester);
      await press(tester, LogicalKeyboardKey.digit2);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('question-option-desc-0-1')),
            )
            .maxLines,
        isNull,
        reason: 'the chosen option shows its description whole',
      );
      await press(tester, LogicalKeyboardKey.enter);
      expect(questions.single.answers.single.options, [1]);
      expect(selected(c), isNot('ask-q'));
      expect(selected(c), isNotNull);
      await unmountMission(tester);
    });

    testWidgets('↑ ↓ and J K move between sessions; Enter opens; Esc closes', (
      tester,
    ) async {
      final (c, _) = await pump(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      final first = selected(c);
      expect(first, isNotNull);
      await press(tester, LogicalKeyboardKey.keyJ);
      final second = selected(c);
      expect(second, isNot(first));
      await press(tester, LogicalKeyboardKey.keyK);
      expect(selected(c), first);

      await press(tester, LogicalKeyboardKey.enter);
      expect(peeked(c), first);
      // With the peek open, moving opens the next one in it.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(peeked(c), second);
      await press(tester, LogicalKeyboardKey.escape);
      expect(peeked(c), isNull);
      expect(selected(c), second);
      await press(tester, LogicalKeyboardKey.escape);
      expect(selected(c), isNull);
      await unmountMission(tester);
    });

    testWidgets('with the peek open, N opens the next waiting item in it', (
      tester,
    ) async {
      final (c, _) = await pump(tester);
      await tester.tap(
        find.byKey(const ValueKey('overview-queue-title:ks-r21')),
      );
      await settleMission(tester);
      expect(peeked(c), 'ks-r21');
      await press(tester, LogicalKeyboardKey.keyN);
      expect(peeked(c), isIn(['ask-q', 'term']));
      await unmountMission(tester);
    });

    testWidgets('a click on the board gives it the keys back', (tester) async {
      final (c, _) = await pump(tester);
      // Focus somewhere else — the header's New session, a closed dialog.
      FocusManager.instance.primaryFocus?.unfocus();
      await settleMission(tester);
      await press(tester, LogicalKeyboardKey.keyN);
      expect(selected(c), isNull);

      await tester.tapAt(const Offset(900, 800));
      await settleMission(tester);
      await press(tester, LogicalKeyboardKey.keyN);
      expect(selected(c), 'ks-r21');
      await unmountMission(tester);
    });

    testWidgets('keys never fire while typing in a field', (tester) async {
      final (c, recorder) = await pump(tester);
      c.read(overviewFocusProvider.notifier).select('ks-r21');
      await tester.tap(find.byKey(const ValueKey('question-reply-in-words')));
      await settleMission(tester);
      final field = find.byKey(const ValueKey('overview-composer:ask-q'));
      await tester.tap(field);
      await settleMission(tester);
      c.read(overviewFocusProvider.notifier).select('ks-r21');
      await settleMission(tester);
      for (final key in [
        LogicalKeyboardKey.keyY,
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyD,
        LogicalKeyboardKey.digit1,
      ]) {
        await press(tester, key);
      }
      expect(recorder.asked, isEmpty);
      expect(selected(c), 'ks-r21');
      await unmountMission(tester);
    });

    testWidgets('T, or Answer in terminal, opens the peek on its terminal', (
      tester,
    ) async {
      final (c, _) = await pump(tester);
      c.read(overviewFocusProvider.notifier).select('term');
      await settleMission(tester);
      await press(tester, LogicalKeyboardKey.keyT);
      expect(peeked(c), 'term');
      expect(c.read(overviewFocusProvider).tab, OverviewPeekTab.terminal);
      expect(
        find.byKey(const ValueKey('overview-peek-tab:terminal')),
        findsOneWidget,
      );
      await press(tester, LogicalKeyboardKey.escape);

      // T on a command offers nothing: it goes on its way.
      c.read(overviewFocusProvider.notifier).select('ks-r21');
      await settleMission(tester);
      await press(tester, LogicalKeyboardKey.keyT);
      expect(peeked(c), isNull);

      final button = find.byKey(
        const ValueKey('overview-answer-terminal:term'),
      );
      await tester.ensureVisible(button);
      await settleMission(tester);
      await tester.tap(button);
      await settleMission(tester);
      expect(peeked(c), 'term');
      expect(c.read(overviewFocusProvider).tab, OverviewPeekTab.terminal);
      await unmountMission(tester);
    });

    testWidgets('? shows the keys', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settleMission(tester);
      expect(find.byKey(const ValueKey('overview-keys')), findsOneWidget);
      expect(
        find.text('Allow, always allow or deny the selected command'),
        findsOneWidget,
      );
      await tester.tap(find.text('Done'));
      await settleMission(tester);
      await unmountMission(tester);
    });
  });

  for (final (name, size, phone) in [
    ('390×844', const Size(390, 844), true),
    ('360×800', const Size(360, 800), true),
  ]) {
    testWidgets('$name: every kind of ask fits', (tester) async {
      await pump(tester, size: size, phone: phone);
      for (final id in ['ks-r21', 'ask-q', 'term', 'store-reviews']) {
        await tester.ensureVisible(queueCard(id));
        await settleMission(tester);
      }
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  }
}
