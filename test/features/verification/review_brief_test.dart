import 'package:karmashala/src/features/sessions/domain/handoff_packet.dart';
import 'package:karmashala/src/features/verification/domain/review_brief.dart';
import 'package:flutter_test/flutter_test.dart';

ReviewBrief brief({
  String? claim = 'The retry loop now backs off exponentially.',
  List<HandoffChange>? changes = const [
    HandoffChange(path: 'lib/retry.dart', state: 'modified'),
  ],
  String? diff = 'diff --git a/lib/retry.dart b/lib/retry.dart\n+  delay *= 2;',
  int diffOmittedCharacters = 0,
  String? branch = 'work/retry',
  String? permissionSummary,
}) => ReviewBrief(
  authorAgentName: 'Claude Code',
  reviewerAgentName: 'Codex',
  subjectTitle: 'Fix the retry loop',
  subjectSessionId: 's-work-1',
  claim: claim,
  workingDirectory: r'C:\repo',
  branch: branch,
  baseBranch: 'main',
  commitsAhead: 2,
  changes: changes,
  diff: diff,
  diffOmittedCharacters: diffOmittedCharacters,
  permissionSummary: permissionSummary,
);

void main() {
  group('the reviewer is told whose work it is looking at', () {
    test('both agents are named, and the reviewer is not the author', () {
      final text = brief().render();
      expect(text, contains('Claude Code'));
      expect(text, contains('Codex'));
      expect(text, contains('did not write'));
    });

    test('the subject session id is quoted in the form the verdict needs', () {
      final text = brief().render();
      expect(text, contains('sessionId: "s-work-1"'));
    });
  });

  group('the claim being checked', () {
    test('is stated when there is one', () {
      expect(
        brief().render(),
        contains('The retry loop now backs off exponentially.'),
      );
    });

    test('reads as not recorded rather than being left out', () {
      final text = brief(claim: null).render();
      expect(text, contains('What you are checking'));
      expect(text.toLowerCase(), contains('not recorded'));
    });
  });

  group('what changed', () {
    test('a clean tree and an unreadable one are different sentences', () {
      final clean = brief(changes: const []).render();
      expect(clean, contains('the working tree is clean'));
      expect(clean, isNot(contains('git did not answer')));
      final unknown = brief(changes: null).render();
      expect(unknown, contains('git did not answer'));
      expect(unknown, isNot(contains('the working tree is clean')));
    });

    test('the diff is quoted, and a trimmed one says how much is missing', () {
      expect(brief().render(), contains('delay *= 2;'));
      final trimmed = brief(diffOmittedCharacters: 4096).render();
      expect(trimmed, contains('4096'));
      expect(trimmed, contains('git diff'));
    });

    test('a diff git would not produce is admitted, not shown as empty', () {
      final text = brief(diff: null).render();
      expect(text, contains('Run `git diff` yourself'));
      expect(text, isNot(contains('```diff')));
    });

    test('a branch git could not name does not become a fake one', () {
      expect(brief(branch: null).render(), contains('unknown'));
    });
  });

  group('the verdict contract', () {
    test('names the three tool calls the reviewer must make', () {
      final text = brief().render();
      expect(text, contains('verification_start'));
      expect(text, contains('verification_note'));
      expect(text, contains('verification_finish'));
      expect(text, contains('change: true'));
    });

    test('finding nothing is a recorded pass, never silence', () {
      final text = brief().render();
      expect(text, contains('pass'));
      expect(text.toLowerCase(), contains('silence'));
    });

    test('the reviewer is told not to fix what it finds', () {
      final text = brief().render().toLowerCase();
      expect(text, contains('do not'));
      expect(text, contains('fix'));
    });
  });

  test('the permission cap is explained when there is one to explain', () {
    final text = brief(
      permissionSummary: 'A review may read and run, never write.',
    ).render();
    expect(text, contains('A review may read and run, never write.'));
  });

  group('the diff budget', () {
    test('a short diff is kept whole and nothing is reported missing', () {
      final trimmed = trimReviewDiff('short', const ReviewDiffBudget());
      expect(trimmed.text, 'short');
      expect(trimmed.omitted, 0);
    });

    test('a long diff keeps its head and counts what it dropped', () {
      final long = List.filled(400, 'a line of diff').join('\n');
      final trimmed = trimReviewDiff(
        long,
        const ReviewDiffBudget(maxCharacters: 200),
      );
      expect(trimmed.text.length, lessThanOrEqualTo(200));
      expect(trimmed.omitted, long.length - trimmed.text.length);
      expect(long, startsWith(trimmed.text));
    });
  });
}
