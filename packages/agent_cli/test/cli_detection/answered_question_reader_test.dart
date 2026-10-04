import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/stream.dart';
import 'package:test/test.dart';

/// A question the agent asked, read back with what the person picked: every
/// question of the call, and its answer once the result says it.
void main() {
  const input = {
    'questions': [
      {
        'question': 'Which colour?',
        'options': [
          {'label': 'Red'},
          {'label': 'Blue'},
        ],
      },
      {
        'question': 'Which fruits?',
        'multiSelect': true,
        'options': [
          {'label': 'Apple'},
          {'label': 'Pear'},
        ],
      },
    ],
  };

  test('a question call carries every question, unanswered until answered', () {
    final call = toolActivityFor('AskUserQuestion', input);
    expect(call.questions.map((q) => q.question), [
      'Which colour?',
      'Which fruits?',
    ]);
    expect(call.questions.every((q) => q.answer == null), isTrue);

    final answered = call.withResult(
      output: 'answered',
      answers: const {'Which colour?': 'Blue', 'Which fruits?': 'Apple, Pear'},
    );
    expect(answered.questions.map((q) => q.answer), ['Blue', 'Apple, Pear']);
    expect(
      ToolActivity.fromJson(answered.toJson()).questions.last.answer,
      'Apple, Pear',
    );
  });

  test('answers already in the input are read with the questions', () {
    final call = toolActivityFor('AskUserQuestion', {
      ...input,
      'answers': {'Which colour?': 'Red'},
    });
    expect(call.questions.map((q) => q.answer), ['Red', null]);
  });

  test("Claude's transcript answers the call from its toolUseResult", () async {
    final dir = Directory.systemTemp.createTempSync('answered_question');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/t.jsonl');
    await file.writeAsString(
      [
        jsonEncode({
          'type': 'assistant',
          'timestamp': '2026-10-04T10:00:00.000Z',
          'message': {
            'content': [
              {
                'type': 'tool_use',
                'id': 'q1',
                'name': 'AskUserQuestion',
                'input': input,
              },
            ],
          },
        }),
        jsonEncode({
          'type': 'user',
          'timestamp': '2026-10-04T10:00:05.000Z',
          'message': {
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'q1',
                'content': 'User has answered your questions.',
              },
            ],
          },
          'toolUseResult': {
            'questions': input['questions'],
            'answers': {'Which colour?': 'Blue', 'Which fruits?': 'Pear'},
          },
        }),
      ].join('\n'),
    );

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);
    final tool = messages.single.tool!;
    expect(tool.questions.map((q) => q.answer), ['Blue', 'Pear']);
  });
}
