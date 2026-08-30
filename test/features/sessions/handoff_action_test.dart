import 'package:chitragupta/src/features/sessions/domain/handoff_action.dart';
import 'package:flutter_test/flutter_test.dart';

/// The gating rules for the handoff row.
///
/// The bias under test is dray's: only facts we positively established withhold
/// the PR action, and every "could not tell" offers it. A wasted click costs one
/// prompt in the transcript; a hidden action costs the user the feature with no
/// way to find out why.
void main() {
  group('commit and run-tests are never gated', () {
    for (final action in [HandoffAction.commit, HandoffAction.runTests]) {
      test('${action.name} is offered even on the default branch', () {
        expect(
          isHandoffActionOffered(
            action,
            const HandoffRepoState(
              branch: 'main',
              hasRemote: true,
              defaultBranch: 'main',
              commitsAhead: 0,
            ),
          ),
          isTrue,
        );
      });
    }
  });

  group('the PR action is withheld only on established facts', () {
    test('not from the default branch', () {
      expect(
        isHandoffActionOffered(
          HandoffAction.pullRequest,
          const HandoffRepoState(
            branch: 'main',
            hasRemote: true,
            defaultBranch: 'main',
          ),
        ),
        isFalse,
      );
    });

    test('not without a remote — no default branch can resolve', () {
      expect(
        isHandoffActionOffered(
          HandoffAction.pullRequest,
          const HandoffRepoState(branch: 'work', hasRemote: false),
        ),
        isFalse,
      );
    });

    test('not when the branch is provably zero commits ahead', () {
      expect(
        isHandoffActionOffered(
          HandoffAction.pullRequest,
          const HandoffRepoState(
            branch: 'work',
            hasRemote: true,
            defaultBranch: 'main',
            commitsAhead: 0,
          ),
        ),
        isFalse,
      );
    });

    test('yes on a feature branch with commits to propose', () {
      expect(
        isHandoffActionOffered(
          HandoffAction.pullRequest,
          const HandoffRepoState(
            branch: 'work',
            hasRemote: true,
            defaultBranch: 'main',
            commitsAhead: 3,
          ),
        ),
        isTrue,
      );
    });
  });

  group('"could not tell" offers the PR action anyway', () {
    test('when there is no repository state at all', () {
      expect(isHandoffActionOffered(HandoffAction.pullRequest, null), isTrue);
    });

    test('when gh could not name a default branch but a remote exists', () {
      // `gh` missing or unauthenticated is not evidence of "no remote".
      expect(
        isHandoffActionOffered(
          HandoffAction.pullRequest,
          const HandoffRepoState(branch: 'work', hasRemote: true),
        ),
        isTrue,
      );
    });

    test('when the base ref is not fetched so the count is unknown', () {
      expect(
        isHandoffActionOffered(
          HandoffAction.pullRequest,
          const HandoffRepoState(
            branch: 'work',
            hasRemote: true,
            defaultBranch: 'main',
          ),
        ),
        isTrue,
      );
    });

    test('on a detached HEAD, where the branch cannot be compared', () {
      expect(
        isHandoffActionOffered(
          HandoffAction.pullRequest,
          const HandoffRepoState(hasRemote: true, defaultBranch: 'main'),
        ),
        isTrue,
      );
    });
  });

  test('handoffActionsFor keeps row order and drops only the PR action', () {
    expect(handoffActionsFor(null), HandoffAction.values);
    expect(
      handoffActionsFor(
        const HandoffRepoState(
          branch: 'main',
          hasRemote: true,
          defaultBranch: 'main',
        ),
      ),
      [HandoffAction.commit, HandoffAction.runTests],
    );
  });

  test('every prompt is one short sentence', () {
    for (final action in HandoffAction.values) {
      expect(action.prompt.trim(), action.prompt);
      expect(action.prompt, endsWith('.'));
      // A prompt long enough to spell out *how* becomes a spec competing with
      // the repository's own instructions.
      expect(action.prompt.split(' ').length, lessThanOrEqualTo(10));
      expect(action.label, isNotEmpty);
    }
  });
}
