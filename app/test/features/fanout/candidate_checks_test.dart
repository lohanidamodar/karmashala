import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/fanout/application/comparison_providers.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';

import '../../support/fixtures.dart';

void main() {
  ComparisonCandidate candidate(
    String id, {
    String? sessionId,
    bool worktree = true,
    bool removed = false,
  }) => ComparisonCandidate(
    id: id,
    comparisonId: 'c1',
    position: 0,
    installationId: 'a1',
    agentId: 'claudeCode',
    launch: CandidateLaunchState.started,
    sessionId: sessionId,
    worktree: worktree
        ? EnvironmentPath(environmentId: 'local', path: '/wt/$id')
        : null,
    worktreeRemoved: removed,
  );

  test('every candidate with a worktree and a session is checked, at once, '
      'and only those', () async {
    final comparison = Comparison(
      id: 'c1',
      prompt: 'fix it',
      repositoryId: 'r1',
      createdAt: testTime,
      candidates: [
        candidate('a', sessionId: 's-a'),
        candidate('b', sessionId: 's-b'),
        candidate('gone', sessionId: 's-gone', removed: true),
        candidate('never', worktree: false),
      ],
    );
    final started = <String>[];
    final release = <Future<void>>[];

    final checked = await runCandidateChecks((sessionId) async {
      started.add(sessionId);
      // Both have started before either finishes: side by side, not queued.
      release.add(Future<void>.delayed(Duration.zero));
      await release.last;
      expect(started, hasLength(2));
      return null;
    }, comparison);

    expect(started, unorderedEquals(['s-a', 's-b']));
    // No repository checks configured: nothing was checked.
    expect(checked, 0);
  });
}
