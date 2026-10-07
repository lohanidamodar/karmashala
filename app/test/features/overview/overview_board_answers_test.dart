import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
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
