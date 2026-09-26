import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// A checkout deleted by another client takes its worktree setup, setup
/// verdicts and review threads out of this app's copies at once, not at the
/// next reconnect.
void main() {
  test(
    'a project deleted elsewhere empties its checkouts\' git side rows',
    () async {
      final server = FakeDataServer();
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      server.worktreeRows
        ..save('r1', const WorktreeSetup(command: ['make']))
        ..record(
          WorktreeSetupReport(
            repositoryId: 'r1',
            worktreePath: r'C:\w\one',
            environmentId: 'windows',
            ranAt: DateTime.utc(2026, 9, 27),
            copies: const [],
          ),
        )
        ..putThread(
          ReviewThread(
            id: 't1',
            repositoryId: 'r1',
            anchor: const ReviewAnchor(
              path: 'a.dart',
              blobSha: 'sha',
              startLine: 1,
              endLine: 1,
            ),
            status: ReviewThreadStatus.open,
            createdAt: DateTime.utc(2026, 9, 27),
            updatedAt: DateTime.utc(2026, 9, 27),
            comments: const [],
          ),
        );
      final here = await server.connect();
      final elsewhere = await server.connect();
      expect(here.worktreeSetups['r1'], isNotNull);
      expect(here.worktreeRuns.values, hasLength(1));
      expect(here.reviewThreads['t1'], isNotNull);

      await elsewhere.send(const ProjectDelete('p1'));

      expect(here.worktreeSetups.values, isEmpty);
      expect(here.worktreeRuns.values, isEmpty);
      expect(here.reviewThreads.values, isEmpty);
    },
  );
}
