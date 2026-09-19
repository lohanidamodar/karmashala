import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

void main() {
  test('arrows whole, text whole, Enter and Esc alone', () {
    expect(keystrokesOf('\r\x1b[B\x1b[BDurian\r\x1b'), [
      '\r',
      '\x1b[B',
      '\x1b[B',
      'Durian',
      '\r',
      '\x1b',
    ]);
  });

  test('a real answer splits back into what built it', () {
    const set = AgentQuestionSet(
      toolUseId: 't',
      questions: [
        AgentQuestion(
          question: 'Pick colours',
          multiSelect: true,
          options: [
            AgentQuestionOption(label: 'Red'),
            AgentQuestionOption(label: 'Green'),
            AgentQuestionOption(label: 'Blue'),
          ],
        ),
        AgentQuestion(
          question: 'Pick a fruit',
          options: [
            AgentQuestionOption(label: 'Apple'),
            AgentQuestionOption(label: 'Banana'),
          ],
        ),
      ],
    );
    final keys = claudeQuestionKeys(set, const [
      AgentQuestionAnswer.options([0, 2]),
      AgentQuestionAnswer.text('Durian'),
    ]);
    expect(keystrokesOf(keys).join(), keys);
    expect(keystrokesOf(keys), contains('Durian'));
  });
}
