import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// A question an agent asks — read out of its transcript, and answered by keys
/// measured against the real CLI (`packages/host/test/agents/
/// claude_question_keys_live_test.dart`, 2026-09-19, Claude Code 2.1.274).
void main() {
  const down = '\x1b[B';
  const enter = '\r';

  final claude = AgentRegistry.builtIn.byId('claudeCode')!;
  final support = claude.questions!;

  AgentQuestionSet set(List<Map<String, Object?>> questions) =>
      AgentQuestionSet.fromToolInput('toolu_1', {'questions': questions})!;

  Map<String, Object?> q(
    String question,
    List<String> options, {
    bool multi = false,
  }) => {
    'question': question,
    'header': question.split(' ').last,
    'multiSelect': multi,
    'options': [
      for (final o in options) {'label': o, 'description': 'about $o'},
    ],
  };

  group('reading a question', () {
    test('the tool input becomes questions, options and their words', () {
      final read = set([
        q('Pick a fruit', ['Apple', 'Banana']),
        q('Pick colours', ['Red', 'Blue'], multi: true),
      ]);
      expect(read.toolUseId, 'toolu_1');
      expect(read.questions, hasLength(2));
      expect(read.questions.first.question, 'Pick a fruit');
      expect(read.questions.first.header, 'fruit');
      expect(read.questions.first.options.map((o) => o.label), [
        'Apple',
        'Banana',
      ]);
      expect(read.questions.first.options.first.description, 'about Apple');
      expect(read.questions.last.multiSelect, isTrue);
    });

    test('a shape this build cannot read is no question at all', () {
      for (final input in <Object?>[
        null,
        'text',
        <String, Object?>{},
        {'questions': 'nope'},
        {'questions': <Object?>[]},
        {
          'questions': [
            {'question': 'no options'},
          ],
        },
      ]) {
        expect(AgentQuestionSet.fromToolInput('t', input), isNull, reason: '$input');
      }
    });
  });

  group('finding the open question in a transcript', () {
    String record(Map<String, Object?> r) => jsonEncode(r);
    String ask(String id) => record({
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': id,
            'name': 'AskUserQuestion',
            'input': {
              'questions': [
                q('Pick a fruit', ['Apple', 'Banana']),
              ],
            },
          },
        ],
      },
    });
    String answered(String id) => record({
      'type': 'user',
      'message': {
        'content': [
          {'type': 'tool_result', 'tool_use_id': id, 'content': 'answered'},
        ],
      },
    });

    test('an asked question nobody answered is open', () {
      final tail = [
        record({'type': 'user', 'message': {'content': 'hi'}}),
        ask('toolu_9'),
        record({'type': 'system', 'subtype': 'hook'}),
      ].join('\n');
      expect(openQuestionIn(tail, support)?.toolUseId, 'toolu_9');
    });

    test('an answered one is not, and neither is an older one', () {
      expect(
        openQuestionIn([ask('a'), answered('a')].join('\n'), support),
        isNull,
      );
      expect(
        openQuestionIn(
          [ask('a'), answered('a'), ask('b')].join('\n'),
          support,
        )?.toolUseId,
        'b',
      );
    });

    test('a half-written last line is skipped, not fatal', () {
      final tail = '${ask('x')}\n{"type":"assist';
      expect(openQuestionIn(tail, support)?.toolUseId, 'x');
    });
  });

  group("Claude Code's keys, as measured", () {
    final fruit = set([
      q('Pick a fruit', ['Apple', 'Banana', 'Cherry']),
    ]);
    final colours = set([
      q('Pick colours', ['Red', 'Green', 'Blue'], multi: true),
    ]);
    final pair = set([
      q('Pick a size', ['Small', 'Large']),
      q('Pick a speed', ['Slow', 'Fast']),
    ]);

    test('one option of one question: down to it, Enter — and nothing more', () {
      expect(support.keysFor(fruit, [const AgentQuestionAnswer.option(1)]), [
        down,
        enter,
      ].join());
      expect(support.keysFor(fruit, [const AgentQuestionAnswer.option(0)]), enter);
    });

    test('free text: down past the options to "Type something", type, Enter', () {
      expect(support.keysFor(fruit, [const AgentQuestionAnswer.text('Durian')]), [
        down,
        down,
        down,
        'Durian',
        enter,
      ].join());
    });

    test('several boxes: Enter on each, down to Next, then Submit', () {
      expect(
        support.keysFor(colours, [
          const AgentQuestionAnswer.options([2, 0]),
        ]),
        [enter, down, down, enter, down, down, enter, enter].join(),
      );
    });

    test('two questions: each answered from its own top, then Submit', () {
      expect(
        support.keysFor(pair, [
          const AgentQuestionAnswer.option(1),
          const AgentQuestionAnswer.option(1),
        ]),
        [down, enter, down, enter, enter].join(),
      );
    });

    test('declining is Esc', () => expect(support.declineKeys, '\x1b'));

    test('an answer that does not fit the question is refused, not typed', () {
      for (final bad in <List<AgentQuestionAnswer>>[
        [],
        [const AgentQuestionAnswer.option(3)],
        [const AgentQuestionAnswer.option(-1)],
        [const AgentQuestionAnswer.options([0, 1])],
        [const AgentQuestionAnswer.text('')],
        [const AgentQuestionAnswer.text('two\nlines')],
        [const AgentQuestionAnswer.text('esc\x1bape')],
      ]) {
        expect(
          () => support.keysFor(fruit, bad),
          throwsArgumentError,
          reason: '$bad',
        );
      }
      expect(
        () => support.keysFor(colours, [const AgentQuestionAnswer.options([])]),
        throwsArgumentError,
      );
      expect(
        () => support.keysFor(colours, [const AgentQuestionAnswer.text('Teal')]),
        throwsArgumentError,
        reason: 'free text on a multi-select question was never measured',
      );
    });
  });

  test('only Claude Code asks questions this app can answer', () {
    for (final agent in AgentRegistry.builtIn.descriptors) {
      expect(
        agent.questions != null,
        agent.id == 'claudeCode',
        reason: agent.id,
      );
    }
    expect(support.toolName, 'AskUserQuestion');
  });
}
