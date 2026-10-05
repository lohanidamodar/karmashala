import 'package:agent_cli/read.dart';
import 'package:karmashala_host/src/sessions/session_transcripts.dart';
import 'package:test/test.dart';

/// A re-read row is told again only when it says something new: a background
/// run that finished is new, though nothing else on its row moved.
void main() {
  TranscriptMessage launch(BackgroundRunState state) => TranscriptMessage(
    role: 'tool',
    text: 'Agent(Strip idle detection)',
    background: BackgroundRun(
      id: 'a1',
      kind: BackgroundRunKind.agent,
      state: state,
      description: 'Strip idle detection',
    ),
  );

  test('a run that finished is a changed row', () {
    expect(
      sameTranscriptMessage(
        launch(BackgroundRunState.running),
        launch(BackgroundRunState.completed),
      ),
      isFalse,
    );
    expect(
      sameTranscriptMessage(
        launch(BackgroundRunState.running),
        launch(BackgroundRunState.running),
      ),
      isTrue,
    );
  });
}
