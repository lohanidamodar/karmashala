import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

void main() {
  test('people read the line; the agent gets the whole message', () {
    final text = botNotice('No. End session a. Nothing ran.', 'Do not retry.');
    expect(text, startsWith('[Karmashala] '));
    expect(text, contains('Do not retry.'));
    expect(botNoticeLine(text), 'Approval: No. End session a. Nothing ran.');
  });

  test('what a person typed, or a delegation report, is no notice', () {
    expect(botNoticeLine('list my sessions'), isNull);
    expect(botNoticeLine('[Karmashala] "Fix" reported back.'), isNull);
    expect(botNoticeLine('Approval: yes please'), isNull);
    expect(botNoticeLine(''), isNull);
  });
}
