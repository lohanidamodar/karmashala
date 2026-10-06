import 'package:karmashala_mcp/instructions.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:test/test.dart';

/// An agent that starts sessions is told, wherever it first reads about
/// Karmashala, to wait for their reports rather than poll for them.
void main() {
  test('the server instructions say to end the turn and wait, not poll', () {
    expect(kKarmashalaMcpInstructions, contains('end your turn'));
    expect(
      kKarmashalaMcpInstructions,
      contains('do not poll transcripts or files'),
    );
    expect(kKarmashalaMcpInstructions, contains('report_to_parent'));
  });

  test('the sessions guide teaches reporting back both ways', () {
    final sessions = kMcpGuides
        .firstWhere((g) => g.topic == 'sessions')
        .render();
    expect(sessions, contains('do not poll transcripts or files'));
    expect(sessions, contains('every turn'));
    expect(sessions, contains('report_to_parent'));
    expect(sessions, contains('`delegations`'));
    expect(sessions, contains('`delegation_set_report`'));
    expect(sessions, contains('"none"'));
    expect(sessions, contains('never waiting on it'));
    expect(sessions, contains('nothing resumes one'));
  });
}
