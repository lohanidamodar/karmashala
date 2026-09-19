@Tags(['live-agent'])
library;

import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_question_typist.dart';
import 'package:karmashala/src/features/sessions/application/session_menu_answerer.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';

import 'live_agent_screen.dart';

/// The production [SessionQuestionTypist] answering a real Claude
/// Code `AskUserQuestion` — the path the phone and the chat view take. Found
/// on the Oppo: the same keys written as one burst lost every key after the
/// first tab change and left the question half-answered.
///
///   KARMASHALA_CLAUDE=C:\Users\me\.local\bin\claude.exe \
///     flutter test --tags=live-agent test/features/agents/live_question_answer_test.dart
///
/// Spends one small model turn per case.
void main() {
  final claude = Platform.environment['KARMASHALA_CLAUDE'];
  final support = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;

  Future<String> answer({
    required String mode,
    required String asking,
    required AgentQuestionSet shape,
    required List<AgentQuestionAnswer> answers,
    required String expectShown,
  }) async {
    final folder = Directory.systemTemp.createTempSync('ks-question-').path;
    final screen = LiveAgentScreen.start(
      argv: [claude!, '--model', 'haiku', '--permission-mode', mode],
      workingDirectory: folder,
      environment: const {'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE': '1'},
    );
    addTearDown(screen.close);
    // A fresh folder asks for trust first; answered the production way.
    final menus = SessionMenuAnswerer(
      readScreen: (_) =>
          terminalTailLines(screen.terminal, lines: kMenuScreenRows),
      supportFor: (_) => support.menus,
      isAsking: (_) => true,
      press: (_, keys) {
        screen.send(keys);
        return true;
      },
    );
    await screen.untilShows('trust');
    // Cold, the CLI draws the trust menu before it takes keys; nobody answers
    // it inside that moment but a test.
    await Future<void>.delayed(const Duration(seconds: 2));
    final trust = menus.read('s')!;
    await menus.choose(
      's',
      menuId: trust.id,
      option: trust.options.indexOf('Yes, I trust this folder'),
    );
    await screen.until(
      (s) => s.contains('shift+tab') || s.contains('for shortcuts'),
      what: 'the composer',
    );
    // The composer takes a moment after trust before it submits on Enter.
    await Future<void>.delayed(const Duration(seconds: 2));
    await screen.write(asking);
    await Future<void>.delayed(const Duration(seconds: 1));
    await screen.write('\r');
    await screen.untilShows(
      'Enter to select',
      within: const Duration(seconds: 90),
    );
    await Future<void>.delayed(const Duration(seconds: 1));

    await SessionQuestionTypist(
      readScreen: (_) =>
          terminalTailLines(screen.terminal, lines: kMenuScreenRows),
      press: (_, keys) {
        screen.send(keys);
        return true;
      },
    ).answer('s', shape, answers);

    await screen.untilShows(expectShown, within: const Duration(seconds: 60));
    return screen.text;
  }

  const colours = AgentQuestion(
    question: 'Pick colours',
    multiSelect: true,
    options: [
      AgentQuestionOption(label: 'Red'),
      AgentQuestionOption(label: 'Green'),
      AgentQuestionOption(label: 'Blue'),
    ],
  );
  const fruit = AgentQuestion(
    question: 'Pick a fruit',
    options: [
      AgentQuestionOption(label: 'Apple'),
      AgentQuestionOption(label: 'Banana'),
      AgentQuestionOption(label: 'Cherry'),
    ],
  );
  const asking =
      'Throwaway UI test. Call no tool except AskUserQuestion, exactly once, '
      'with two questions: 1) Pick colours (header Colours, multiSelect true) '
      'options Red, Green, Blue; 2) Pick a fruit (header Fruit, single '
      'choice) options Apple, Banana, Cherry. After it returns reply only '
      'with the answers.';

  group(
    'Claude Code AskUserQuestion, each step seen',
    skip: claude == null ? 'set KARMASHALA_CLAUDE' : false,
    () {
      for (final mode in ['plan', 'default']) {
        test('several boxes, then own words, in $mode mode', () async {
          final shown = await answer(
            mode: mode,
            asking: asking,
            shape: const AgentQuestionSet(
              toolUseId: 't',
              questions: [colours, fruit],
            ),
            answers: const [
              AgentQuestionAnswer.options([0, 2]),
              AgentQuestionAnswer.text('Durian'),
            ],
            expectShown: 'Durian',
          );
          expect(shown, contains('Red, Blue'));
        }, timeout: const Timeout(Duration(minutes: 4)));
      }

      test('one option on each tab', () async {
        final shown = await answer(
          mode: 'plan',
          asking: asking,
          shape: const AgentQuestionSet(
            toolUseId: 't',
            questions: [colours, fruit],
          ),
          answers: const [
            AgentQuestionAnswer.options([1]),
            AgentQuestionAnswer.option(2),
          ],
          expectShown: 'Cherry',
        );
        expect(shown, contains('Green'));
      }, timeout: const Timeout(Duration(minutes: 4)));
    },
  );
}
