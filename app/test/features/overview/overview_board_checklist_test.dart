import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';

import 'mission_fixture.dart';

class _Recorder implements PromptAnswering {
  _Recorder(this.menu);

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

/// **Claude Code's project-MCP checklist, waiting on you on the board**
/// (owner, 2026-10-17): the card offered Approve and Deny, which could only
/// be refused, and its "Answer in the terminal" did nothing. It now offers
/// the checklist's own answers, and the way to the terminal goes where the
/// board's own does.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-board-checklist');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  final now = MissionFixture.now;
  const checklist = AgentScreenMenu(
    prompt: [
      '2 new MCP servers found in this project',
      'Select any you wish to enable.',
      'MCP servers may execute code or access system resources. All tool '
          'calls require approval. Learn more in the MCP',
      'documentation.',
    ],
    options: ['dart', 'marionette', 'Enable selected'],
    highlighted: 0,
    checked: [true, true, null],
  );

  Future<(ProviderContainer, _Recorder)> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    bool phone = false,
    double textScale = 1,
    bool pane = true,
  }) async {
    final recorder = _Recorder(checklist);
    final container = await pumpMission(
      tester,
      fixture: MissionFixture(
        sessions: [
          (
            id: 'mcp',
            title: 'Karmakanda',
            project: 'p-beej',
            machine: 'windows',
            agent: AgentIds.claudeCode,
            state: AgentState.needsYou,
            age: const Duration(minutes: 1),
            parent: null,
            report: AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: 'cli-mcp',
              status: AgentActivityStatus.awaitingApproval,
              observedAt: now,
              source: AgentStatusSource.terminalGrid,
              waiting: AgentWaitKind.approval,
              waitingSince: now.subtract(const Duration(minutes: 1)),
            ),
          ),
        ],
        panes: pane ? const {'mcp': 'pane-mcp'} : const {},
      ),
      prefsDir: dir,
      size: size,
      phone: phone,
      textScale: textScale,
      waiting: true,
      overrides: [
        sessionAnswerableProvider.overrideWithValue((_) => true),
        sessionPromptAnswersProvider.overrideWithValue(recorder),
      ],
    );
    return (container, recorder);
  }

  Finder card() => find.byKey(const ValueKey('overview-queue-card:mcp'));
  Finder inCard(Finder f) => find.descendant(of: card(), matching: f);

  testWidgets("its own answers — the boxes, Enable selected and Reject all — "
      'and no Approve or Deny', (tester) async {
    final (_, recorder) = await pump(tester);
    expect(
      inCard(find.text('Claude Code: 2 new MCP servers found in this project')),
      findsOneWidget,
    );
    expect(inCard(find.byKey(const ValueKey('checklist-box-0'))), findsOne);
    expect(inCard(find.byKey(const ValueKey('checklist-box-1'))), findsOne);
    for (final words in ['Approve', 'Deny', 'Allow', 'Allow once']) {
      expect(inCard(find.text(words)), findsNothing, reason: words);
    }
    expect(find.byKey(const ValueKey('board-allow:mcp')), findsNothing);

    // Untick marionette, then submit: dart alone, by the checklist's path.
    await tester.tap(inCard(find.byKey(const ValueKey('checklist-box-1'))));
    await settleMission(tester);
    await tester.tap(inCard(find.byKey(const ValueKey('checklist-submit'))));
    await settleMission(tester);
    final submitted = recorder.asked.single as MenuAnswerRequest;
    expect(submitted.menuId, checklist.id);
    expect(submitted.option, 2, reason: 'the "Enable selected" row');
    expect(submitted.ticks, [true, false]);

    await tester.tap(inCard(find.byKey(const ValueKey('checklist-reject'))));
    await settleMission(tester);
    final rejected = recorder.asked.last as MenuAnswerRequest;
    expect(rejected.dismiss, isTrue);
    expect(rejected.menuId, checklist.id);
    await unmountMission(tester);
  });

  testWidgets('Answer in the terminal peeks its terminal, as T does', (
    tester,
  ) async {
    final (c, recorder) = await pump(tester);
    expect(c.read(overviewFocusProvider).peeked, isNull);
    final button = inCard(find.text('Answer in the terminal'));
    await tester.ensureVisible(button);
    await settleMission(tester);
    await tester.tap(button);
    await settleMission(tester);
    expect(c.read(overviewFocusProvider).peeked, 'mcp');
    expect(c.read(overviewFocusProvider).tab, OverviewPeekTab.terminal);
    expect(
      find.byKey(const ValueKey('overview-peek-tab:terminal')),
      findsOneWidget,
    );
    expect(recorder.asked, isEmpty, reason: 'no key was sent');
    await unmountMission(tester);
  });

  testWidgets('with no terminal on this machine it says so, never nothing', (
    tester,
  ) async {
    final (c, _) = await pump(tester, pane: false);
    final button = inCard(find.text('Answer in the terminal'));
    await tester.ensureVisible(button);
    await settleMission(tester);
    await tester.tap(button);
    await settleMission(tester);
    expect(
      find.text('This session has no terminal open on this machine.'),
      findsOneWidget,
    );
    expect(c.read(overviewFocusProvider).peeked, isNull);
    await unmountMission(tester);
  });

  for (final (name, size) in [
    ('390×844', const Size(390, 844)),
    ('360×800', const Size(360, 800)),
  ]) {
    testWidgets('$name at text scale 1.6: it fits, and the terminal opens', (
      tester,
    ) async {
      final (c, _) = await pump(
        tester,
        size: size,
        phone: true,
        textScale: 1.6,
      );
      await tester.ensureVisible(card());
      await settleMission(tester);
      for (final key in ['checklist-submit', 'checklist-reject']) {
        await tester.ensureVisible(inCard(find.byKey(ValueKey(key))));
        await settleMission(tester);
      }
      final button = inCard(find.text('Answer in the terminal'));
      await tester.ensureVisible(button);
      await settleMission(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(button);
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, 'mcp');
      expect(c.read(overviewFocusProvider).tab, OverviewPeekTab.terminal);
      await unmountMission(tester);
    });
  }
}
