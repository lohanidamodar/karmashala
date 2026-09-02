import 'package:karmashala/src/features/sessions/domain/handoff_packet.dart';
import 'package:karmashala/src/features/verification/domain/review_brief.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where a reviewer's findings are told to go.
///
/// `ReviewSessionService` launches a reviewer against a diff under a named
/// verdict contract, and that contract used to end at three calls — all of
/// which record *the review*, and none of which record *a finding* anywhere a
/// human can triage it. The findings evaporated into the reviewer's transcript.
/// These tests hold the brief to naming the thread as the place a finding
/// lands, and to keeping it distinct from the reasoning note beside it.
ReviewBrief brief() => const ReviewBrief(
  authorAgentName: 'Claude Code',
  reviewerAgentName: 'Codex',
  subjectTitle: 'Fix the retry loop',
  subjectSessionId: 's-work-1',
  claim: 'The retry loop now backs off exponentially.',
  workingDirectory: r'C:\repo',
  branch: 'work/retry',
  baseBranch: 'main',
  commitsAhead: 2,
  changes: [HandoffChange(path: 'lib/retry.dart', state: 'modified')],
  diff: 'diff --git a/lib/retry.dart b/lib/retry.dart\n+  delay *= 2;',
);

void main() {
  test('the contract names the tool a finding is filed with', () {
    expect(brief().render(), contains('review_thread_add'));
  });

  test('a finding and a note are told apart, not merged', () {
    final text = brief().render();
    // The note is the reasoning — including for the parts that were fine — and
    // the thread is the thing somebody acts on. A brief that described only
    // one of them would get the other for free and neither well.
    expect(text, contains('this is where a finding goes'));
    expect(text, contains('reasoning'));
    expect(text, contains('verification_note'));
  });

  test('the reviewer is told its threads are claims, not instructions', () {
    final text = brief().render();
    expect(text, contains('open'));
    expect(text, contains('should fix'));
    // The same objection `decision_tools.dart` raises about an agent recording
    // an approval: an agent that could mark its own finding must-fix would be
    // writing the author's task list and having it read as the user's.
    expect(text, contains('only a human moves it'));
  });

  test('the anchor rule reaches the reviewer, not just the code', () {
    final text = brief().render();
    // A reviewer that gave line numbers from a file it read three turns ago
    // would produce anchors that are detached the moment they are written.
    expect(text, contains('as it is on disk right now'));
    expect(text, contains('detached'));
    expect(text, contains('excerpt'));
  });

  test('the three original calls are still all named', () {
    final text = brief().render();
    for (final call in const [
      'verification_start',
      'verification_note',
      'verification_finish',
    ]) {
      expect(text, contains(call), reason: call);
    }
  });
}
