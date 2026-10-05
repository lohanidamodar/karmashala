import 'package:agent_cli/read.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// What a window's digest keeps of the rows before it: the ones still open,
/// a background command among them though nothing about its call is pending.
void main() {
  TranscriptMessage command(BackgroundRunState state) => TranscriptMessage(
    role: 'tool',
    text: 'Bash(Run the app tests)',
    background: BackgroundRun(
      id: 'brr24bsfs',
      kind: BackgroundRunKind.command,
      state: state,
    ),
  );

  test('a background command still running is carried; one that ended is '
      'not', () {
    final digest = TranscriptDigest.of([
      command(BackgroundRunState.running),
      command(BackgroundRunState.failed),
      const TranscriptMessage(role: 'user', text: 'hi'),
    ], 3);
    expect(digest.pending.map((u) => u.index), [0]);
  });
}
