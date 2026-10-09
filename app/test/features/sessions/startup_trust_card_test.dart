import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/presentation/approval_request_card.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';

import 'chat_cards_support.dart';

/// Codex 0.160's and Antigravity's folder-trust menus, as their screens read
/// (`codex-trust-prompt-0.160.raw`, `antigravity-trust-prompt.raw`), reach the
/// chat as a card answered by option — at a desktop and at a 360 px phone with
/// large text.
void main() {
  for (final (agentId, menu) in [
    (
      AgentIds.codex,
      const AgentScreenMenu(
        prompt: [
          'Folder access',
          'Trust this folder? Codex can read, edit, and run files here, '
              'subject to your permission settings.',
        ],
        options: ['Trust and continue', 'Quit'],
        highlighted: 0,
      ),
    ),
    (
      AgentIds.antigravity,
      const AgentScreenMenu(
        prompt: [
          'Do you trust the contents of this project?',
          'Antigravity CLI requires permission to read, edit, and execute '
              'files here.',
        ],
        options: ['Yes, I trust this folder', 'No, exit'],
        highlighted: 0,
      ),
    ),
  ]) {
    for (final (size, textScale, touch) in [
      (const Size(1440, 900), 1.0, false),
      (const Size(360, 780), 1.6, true),
    ]) {
      testWidgets('$agentId trust menu at ${size.width.round()} px: a card '
          'answered by option', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final answers = RecordingPromptAnswers(menu: menu);
        final h = await ChatCardHarness.open(
          ChatCardSession.terminalCli,
          agent: agentId,
          messages: const [],
          status: ChatCardHarness.statusOf(
            ChatCardSession.terminalCli,
            AgentActivityStatus.awaitingApproval,
            agent: agentId,
            waiting: AgentWaitKind.approval,
            evidence: [...menu.prompt, ...menu.options],
          ),
          overrides: [
            sessionPromptAnswersProvider.overrideWithValue(answers),
            sessionAnswerableProvider.overrideWithValue((_) => true),
          ],
        );
        addTearDown(h.dispose);
        await tester.pumpWidget(_chat(h.container, touch: touch));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        final yes = find.byKey(const ValueKey('dock-menu-option-0'));
        final no = find.byKey(const ValueKey('dock-menu-option-1'));
        expect(yes, findsOneWidget);
        expect(no, findsOneWidget);
        expect(
          find.descendant(of: yes, matching: find.text(menu.options[0])),
          findsOneWidget,
        );
        expect(
          find.descendant(of: no, matching: find.text(menu.options[1])),
          findsOneWidget,
        );

        await tester.tap(no);
        await tester.pumpAndSettle();
        final answer = answers.answers.single as MenuAnswerRequest;
        expect(answer.option, 1);
        expect(answer.menuId, menu.id);
      });
    }
  }
}

/// The chat with the dock under it: the desktop's, or the touch dock the
/// compact workbench mounts on a phone.
Widget _chat(ProviderContainer container, {required bool touch}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SessionTranscriptView(sessionId: 's1')),
              ApprovalRequestCard(sessionId: 's1', docked: true, touch: touch),
            ],
          ),
        ),
      ),
    );
